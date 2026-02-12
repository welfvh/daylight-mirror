// mirror_native.c — Daylight Mirror native renderer.
//
// Receives LZ4+delta compressed greyscale frames over TCP,
// decompresses, applies delta, and writes directly to ANativeWindow.
// Entire hot path is C — no JNI calls, no Java GC, no GPU.
//
// Protocol: [0xDA 0x7E] [flags:1B] [seq:4B LE] [length:4B LE] [LZ4 payload]
//   flags bit 0: 1=keyframe, 0=delta (XOR with previous)
// ACK:      [0xDA 0x7A] [seq:4B LE] — sent back after rendering each frame

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <arm_neon.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <android/hardware_buffer.h>
#include "lz4.h"

#ifndef AHARDWAREBUFFER_FORMAT_R8_UNORM
#define AHARDWAREBUFFER_FORMAT_R8_UNORM 0x38
#endif

#define TAG "DaylightMirror"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// Default resolution (updated dynamically via CMD_RESOLUTION from server)
#define DEFAULT_FRAME_W 1024
#define DEFAULT_FRAME_H 768

#define MAGIC_FRAME_0 0xDA
#define MAGIC_FRAME_1 0x7E
#define MAGIC_CMD_1   0x7F
#define MAGIC_ACK_1   0x7A
#define FLAG_KEYFRAME 0x01
#define FRAME_HEADER_SIZE 11
#define CMD_BRIGHTNESS 0x01
#define CMD_RESOLUTION 0x04

// Global state
static ANativeWindow *g_window = NULL;
static pthread_t g_decode_thread;
static pthread_t g_render_thread;
static volatile int g_running = 0;
static JavaVM *g_jvm = NULL;
static jobject g_activity = NULL;
static char g_host[64] = "127.0.0.1";
static int g_port = 8888;
static int g_sock = -1;

// Dynamic frame dimensions (set by CMD_RESOLUTION before first frame)
static uint32_t g_frame_w = DEFAULT_FRAME_W;
static uint32_t g_frame_h = DEFAULT_FRAME_H;
static uint32_t g_pixel_count = DEFAULT_FRAME_W * DEFAULT_FRAME_H;
static uint32_t g_max_compressed = DEFAULT_FRAME_W * DEFAULT_FRAME_H + 256;

// Frame buffers (allocated once, reused — reallocated on resolution change)
static uint8_t *g_current_frame = NULL;   // Decompressed greyscale pixels
static uint8_t *g_compressed_buf = NULL;  // Incoming compressed data

static pthread_mutex_t g_frame_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_frame_cond = PTHREAD_COND_INITIALIZER;
static uint8_t *g_render_frames[2] = {NULL, NULL};
static int g_ready_index = 0;
static int g_has_ready_frame = 0;
static uint32_t g_ready_seq = 0;
static int g_overwritten_frames = 0;
static double g_render_neon_sum = 0.0;
static double g_render_vsync_sum = 0.0;
static int g_render_stat_frames = 0;

static EGLDisplay g_egl_display = EGL_NO_DISPLAY;
static EGLSurface g_egl_surface = EGL_NO_SURFACE;
static EGLContext g_egl_context = EGL_NO_CONTEXT;
static GLuint g_gl_program = 0;
static GLuint g_gl_texture = 0;
static GLuint g_gl_vbo = 0;
static GLint g_gl_attr_position = -1;
static GLint g_gl_attr_texcoord = -1;
static GLint g_gl_uniform_texture = -1;
static uint32_t g_gl_tex_w = 0;
static uint32_t g_gl_tex_h = 0;
static int g_gl_ready = 0;

static const char *k_vertex_shader_src =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_texcoord;\n"
    "void main() {\n"
    "    gl_Position = a_position;\n"
    "    v_texcoord = a_texcoord;\n"
    "}\n";

static const char *k_fragment_shader_src =
    "precision mediump float;\n"
    "varying vec2 v_texcoord;\n"
    "uniform sampler2D u_texture;\n"
    "void main() {\n"
    "    float grey = texture2D(u_texture, v_texcoord).r;\n"
    "    gl_FragColor = vec4(grey, grey, grey, 1.0);\n"
    "}\n";

static void gl_teardown(void);

static GLuint gl_compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    if (!shader) {
        LOGE("glCreateShader failed: %u", (unsigned)type);
        return 0;
    }

    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);

    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        char info_log[512];
        GLsizei log_len = 0;
        glGetShaderInfoLog(shader, sizeof(info_log), &log_len, info_log);
        LOGE("Shader compile failed: %s", info_log);
        glDeleteShader(shader);
        return 0;
    }

    return shader;
}

static int gl_create_program(void) {
    GLuint vertex_shader = gl_compile_shader(GL_VERTEX_SHADER, k_vertex_shader_src);
    GLuint fragment_shader = gl_compile_shader(GL_FRAGMENT_SHADER, k_fragment_shader_src);
    if (!vertex_shader || !fragment_shader) {
        if (vertex_shader) glDeleteShader(vertex_shader);
        if (fragment_shader) glDeleteShader(fragment_shader);
        return 0;
    }

    g_gl_program = glCreateProgram();
    if (!g_gl_program) {
        LOGE("glCreateProgram failed");
        glDeleteShader(vertex_shader);
        glDeleteShader(fragment_shader);
        return 0;
    }

    glAttachShader(g_gl_program, vertex_shader);
    glAttachShader(g_gl_program, fragment_shader);
    glLinkProgram(g_gl_program);

    GLint linked = GL_FALSE;
    glGetProgramiv(g_gl_program, GL_LINK_STATUS, &linked);
    glDeleteShader(vertex_shader);
    glDeleteShader(fragment_shader);

    if (linked != GL_TRUE) {
        char info_log[512];
        GLsizei log_len = 0;
        glGetProgramInfoLog(g_gl_program, sizeof(info_log), &log_len, info_log);
        LOGE("Program link failed: %s", info_log);
        glDeleteProgram(g_gl_program);
        g_gl_program = 0;
        return 0;
    }

    g_gl_attr_position = glGetAttribLocation(g_gl_program, "a_position");
    g_gl_attr_texcoord = glGetAttribLocation(g_gl_program, "a_texcoord");
    g_gl_uniform_texture = glGetUniformLocation(g_gl_program, "u_texture");
    if (g_gl_attr_position < 0 || g_gl_attr_texcoord < 0 || g_gl_uniform_texture < 0) {
        LOGE("GL attribute/uniform lookup failed");
        return 0;
    }

    return 1;
}

static int gl_create_texture(uint32_t width, uint32_t height) {
    if (g_gl_texture) {
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
    }

    glGenTextures(1, &g_gl_texture);
    if (!g_gl_texture) {
        LOGE("glGenTextures failed");
        return 0;
    }

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g_gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, (GLsizei)width, (GLsizei)height,
                 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, NULL);

    if (glGetError() != GL_NO_ERROR) {
        LOGE("glTexImage2D failed for %ux%u", width, height);
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
        return 0;
    }

    g_gl_tex_w = width;
    g_gl_tex_h = height;
    return 1;
}

static int gl_init(ANativeWindow *window) {
    if (!window) return 0;
    if (g_gl_ready) return 1;

    const EGLint config_attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    const EGLint context_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    static const GLfloat quad_vertices[] = {
        -1.0f, -1.0f, 0.0f, 1.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
         1.0f,  1.0f, 1.0f, 0.0f,
    };

    g_egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_egl_display == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay failed");
        goto fail;
    }

    if (!eglInitialize(g_egl_display, NULL, NULL)) {
        LOGE("eglInitialize failed: 0x%x", eglGetError());
        goto fail;
    }

    EGLConfig config;
    EGLint num_configs = 0;
    if (!eglChooseConfig(g_egl_display, config_attribs, &config, 1, &num_configs) || num_configs < 1) {
        LOGE("eglChooseConfig failed: 0x%x", eglGetError());
        goto fail;
    }

    g_egl_surface = eglCreateWindowSurface(g_egl_display, config, window, NULL);
    if (g_egl_surface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface failed: 0x%x", eglGetError());
        goto fail;
    }

    g_egl_context = eglCreateContext(g_egl_display, config, EGL_NO_CONTEXT, context_attribs);
    if (g_egl_context == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext failed: 0x%x", eglGetError());
        goto fail;
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
        LOGE("eglMakeCurrent failed: 0x%x", eglGetError());
        goto fail;
    }

    eglSwapInterval(g_egl_display, 0);

    if (!gl_create_program()) goto fail;

    glUseProgram(g_gl_program);
    glUniform1i(g_gl_uniform_texture, 0);

    glGenBuffers(1, &g_gl_vbo);
    if (!g_gl_vbo) {
        LOGE("glGenBuffers failed");
        goto fail;
    }
    glBindBuffer(GL_ARRAY_BUFFER, g_gl_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    if (!gl_create_texture(g_frame_w, g_frame_h)) goto fail;

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    g_gl_ready = 1;
    return 1;

fail:
    gl_teardown();
    return 0;
}

static int gl_ensure_texture_size(uint32_t width, uint32_t height) {
    if (!g_gl_ready) return 0;
    if (g_gl_texture && g_gl_tex_w == width && g_gl_tex_h == height) return 1;
    return gl_create_texture(width, height);
}

static void gl_teardown(void) {
    if (g_egl_display != EGL_NO_DISPLAY && g_egl_surface != EGL_NO_SURFACE && g_egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context);
        if (g_gl_texture) {
            glDeleteTextures(1, &g_gl_texture);
            g_gl_texture = 0;
        }
        if (g_gl_vbo) {
            glDeleteBuffers(1, &g_gl_vbo);
            g_gl_vbo = 0;
        }
        if (g_gl_program) {
            glDeleteProgram(g_gl_program);
            g_gl_program = 0;
        }
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    } else {
        g_gl_texture = 0;
        g_gl_vbo = 0;
        g_gl_program = 0;
    }

    if (g_egl_display != EGL_NO_DISPLAY) {
        if (g_egl_context != EGL_NO_CONTEXT) {
            eglDestroyContext(g_egl_display, g_egl_context);
        }
        if (g_egl_surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_egl_display, g_egl_surface);
        }
        eglTerminate(g_egl_display);
    }

    g_egl_display = EGL_NO_DISPLAY;
    g_egl_surface = EGL_NO_SURFACE;
    g_egl_context = EGL_NO_CONTEXT;
    g_gl_attr_position = -1;
    g_gl_attr_texcoord = -1;
    g_gl_uniform_texture = -1;
    g_gl_tex_w = 0;
    g_gl_tex_h = 0;
    g_gl_ready = 0;
}

// Read exactly n bytes from socket (handles partial reads)
static int read_exact(int sock, void *buf, int n) {
    int total = 0;
    while (total < n) {
        int r = recv(sock, (uint8_t *)buf + total, n - total, 0);
        if (r <= 0) return -1;
        total += r;
    }
    return total;
}

static void apply_delta_neon(uint8_t *frame, const uint8_t *delta, int count) {
    int i = 0;
    for (; i + 64 <= count; i += 64) {
        __builtin_prefetch(frame + i + 64, 1, 1);
        __builtin_prefetch(delta + i + 64, 0, 1);
        uint8x16_t f0 = vld1q_u8(frame + i);
        uint8x16_t f1 = vld1q_u8(frame + i + 16);
        uint8x16_t f2 = vld1q_u8(frame + i + 32);
        uint8x16_t f3 = vld1q_u8(frame + i + 48);
        uint8x16_t d0 = vld1q_u8(delta + i);
        uint8x16_t d1 = vld1q_u8(delta + i + 16);
        uint8x16_t d2 = vld1q_u8(delta + i + 32);
        uint8x16_t d3 = vld1q_u8(delta + i + 48);
        vst1q_u8(frame + i, veorq_u8(f0, d0));
        vst1q_u8(frame + i + 16, veorq_u8(f1, d1));
        vst1q_u8(frame + i + 32, veorq_u8(f2, d2));
        vst1q_u8(frame + i + 48, veorq_u8(f3, d3));
    }

    for (; i + 16 <= count; i += 16) {
        uint8x16_t f = vld1q_u8(frame + i);
        uint8x16_t d = vld1q_u8(delta + i);
        vst1q_u8(frame + i, veorq_u8(f, d));
    }
    // Remaining bytes
    for (; i < count; i++) {
        frame[i] ^= delta[i];
    }
}

// Write greyscale directly to ANativeWindow in R8_UNORM format (1 byte/pixel).
// Falls back to RGBX expansion if R8 is not supported.
static int g_r8_supported = 0;  // R8_UNORM not compositable by SurfaceFlinger on DC-1

static void blit_grey_to_surface(ANativeWindow *window, const uint8_t *grey) {
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
        LOGE("ANativeWindow_lock failed");
        return;
    }

    uint8_t *dst = (uint8_t *)buffer.bits;
    int fw = (int)g_frame_w;
    int fh = (int)g_frame_h;

    if (g_r8_supported) {
        if (buffer.stride == fw && fw <= buffer.width && fh <= buffer.height) {
            memcpy(dst, grey, (size_t)fw * fh);
        } else {
            int dst_stride = buffer.stride;
            for (int y = 0; y < fh && y < buffer.height; y++) {
                int w = fw < buffer.width ? fw : buffer.width;
                memcpy(dst + y * dst_stride, grey + y * fw, w);
            }
        }
    } else {
        // Fallback: RGBX_8888 (4 bytes per pixel) with NEON expansion
        int dst_stride = buffer.stride * 4;
        for (int y = 0; y < fh && y < buffer.height; y++) {
            uint8_t *row = dst + y * dst_stride;
            const uint8_t *src = grey + y * fw;
            int x = 0;
            for (; x + 16 <= fw && x + 16 <= buffer.width; x += 16) {
                uint8x16_t g = vld1q_u8(src + x);
                uint8x16_t ff = vdupq_n_u8(0xFF);
                uint8x16x4_t rgbx;
                rgbx.val[0] = g;
                rgbx.val[1] = g;
                rgbx.val[2] = g;
                rgbx.val[3] = ff;
                vst4q_u8(row + x * 4, rgbx);
            }
            for (; x < fw && x < buffer.width; x++) {
                uint8_t v = src[x];
                row[x * 4 + 0] = v;
                row[x * 4 + 1] = v;
                row[x * 4 + 2] = v;
                row[x * 4 + 3] = 0xFF;
            }
        }
    }

    ANativeWindow_unlockAndPost(window);
}

static void send_ack(int sock, uint32_t seq) {
    uint8_t ack[6];
    ack[0] = MAGIC_FRAME_0;
    ack[1] = MAGIC_ACK_1;
    ack[2] = (uint8_t)(seq & 0xFF);
    ack[3] = (uint8_t)((seq >> 8) & 0xFF);
    ack[4] = (uint8_t)((seq >> 16) & 0xFF);
    ack[5] = (uint8_t)((seq >> 24) & 0xFF);
    send(sock, ack, 6, MSG_NOSIGNAL);
}

static double ms_diff(struct timespec a, struct timespec b) {
    return ((b.tv_sec - a.tv_sec) * 1000.0) + ((b.tv_nsec - a.tv_nsec) / 1e6);
}

static void notify_connection_state(int connected) {
    if (!g_jvm || !g_activity) return;
    JNIEnv *env;
    int attached = 0;
    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
        attached = 1;
    }
    jclass cls = (*env)->GetObjectClass(env, g_activity);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onConnectionState", "(Z)V");
    if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jboolean)(connected ? 1 : 0));
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
}

static void publish_frame(const uint8_t *frame, uint32_t seq) {
    if (!frame) return;
    pthread_mutex_lock(&g_frame_mutex);

    const int write_index = (g_ready_index == 0) ? 1 : 0;
    if (g_render_frames[write_index]) {
        memcpy(g_render_frames[write_index], frame, g_pixel_count);
        if (g_has_ready_frame) g_overwritten_frames += 1;
        g_ready_index = write_index;
        g_ready_seq = seq;
        g_has_ready_frame = 1;
        pthread_cond_signal(&g_frame_cond);
    }
    pthread_mutex_unlock(&g_frame_mutex);
}

static int reallocate_buffers(uint32_t new_w, uint32_t new_h, uint8_t **decompress_buf) {
    uint32_t new_pixels = new_w * new_h;
    uint32_t new_max_compressed = new_pixels + 256;

    uint8_t *new_current = (uint8_t *)calloc(new_pixels, 1);
    uint8_t *new_compressed = (uint8_t *)malloc(new_max_compressed);
    uint8_t *new_decompress = (uint8_t *)malloc(new_pixels);
    uint8_t *new_render0 = (uint8_t *)malloc(new_pixels);
    uint8_t *new_render1 = (uint8_t *)malloc(new_pixels);

    if (!new_current || !new_compressed || !new_decompress || !new_render0 || !new_render1) {
        free(new_current);
        free(new_compressed);
        free(new_decompress);
        free(new_render0);
        free(new_render1);
        return 0;
    }

    pthread_mutex_lock(&g_frame_mutex);
    free(g_current_frame);
    free(g_compressed_buf);
    free(*decompress_buf);
    free(g_render_frames[0]);
    free(g_render_frames[1]);

    g_current_frame = new_current;
    g_compressed_buf = new_compressed;
    *decompress_buf = new_decompress;
    g_render_frames[0] = new_render0;
    g_render_frames[1] = new_render1;
    memset(g_render_frames[0], 0xFF, new_pixels);
    memset(g_render_frames[1], 0xFF, new_pixels);
    g_ready_index = 0;
    g_has_ready_frame = 0;

    g_frame_w = new_w;
    g_frame_h = new_h;
    g_pixel_count = new_pixels;
    g_max_compressed = new_max_compressed;
    pthread_mutex_unlock(&g_frame_mutex);
    return 1;
}

static void *render_thread(void *arg) {
    (void)arg;
    uint8_t *render_local = NULL;
    uint32_t render_capacity = 0;
    uint32_t render_w = 0;
    uint32_t render_h = 0;
    int gl_disabled = 0;

    while (g_running) {
        pthread_mutex_lock(&g_frame_mutex);
        while (g_running && !g_has_ready_frame) {
            pthread_cond_wait(&g_frame_cond, &g_frame_mutex);
        }
        if (!g_running) {
            pthread_mutex_unlock(&g_frame_mutex);
            break;
        }

        const int frame_index = g_ready_index;
        uint32_t local_pixels = g_pixel_count;
        render_w = g_frame_w;
        render_h = g_frame_h;

        if (local_pixels > render_capacity) {
            uint8_t *resized = (uint8_t *)realloc(render_local, local_pixels);
            if (!resized) {
                g_has_ready_frame = 0;
                pthread_mutex_unlock(&g_frame_mutex);
                continue;
            }
            render_local = resized;
            render_capacity = local_pixels;
        }

        memcpy(render_local, g_render_frames[frame_index], local_pixels);
        g_has_ready_frame = 0;
        pthread_mutex_unlock(&g_frame_mutex);

        struct timespec t4a, t4b, t5;
        if (g_window && render_local) {
            int did_present = 0;

            if (!gl_disabled) {
                if (!g_gl_ready && !gl_init(g_window)) {
                    LOGE("GL init failed, falling back to CPU blit");
                    gl_disabled = 1;
                }

                if (g_gl_ready && !gl_ensure_texture_size(render_w, render_h)) {
                    LOGE("GL texture resize failed for %ux%u", render_w, render_h);
                    gl_teardown();
                    gl_disabled = 1;
                }

                if (g_gl_ready) {
                    EGLint surface_w = 0;
                    EGLint surface_h = 0;
                    eglQuerySurface(g_egl_display, g_egl_surface, EGL_WIDTH, &surface_w);
                    eglQuerySurface(g_egl_display, g_egl_surface, EGL_HEIGHT, &surface_h);
                    if (surface_w > 0 && surface_h > 0) {
                        glViewport(0, 0, surface_w, surface_h);
                    }

                    glUseProgram(g_gl_program);
                    glActiveTexture(GL_TEXTURE0);
                    glBindTexture(GL_TEXTURE_2D, g_gl_texture);
                    glBindBuffer(GL_ARRAY_BUFFER, g_gl_vbo);
                    glEnableVertexAttribArray((GLuint)g_gl_attr_position);
                    glEnableVertexAttribArray((GLuint)g_gl_attr_texcoord);
                    glVertexAttribPointer((GLuint)g_gl_attr_position, 2, GL_FLOAT, GL_FALSE,
                                          4 * sizeof(GLfloat), (const void *)0);
                    glVertexAttribPointer((GLuint)g_gl_attr_texcoord, 2, GL_FLOAT, GL_FALSE,
                                          4 * sizeof(GLfloat), (const void *)(2 * sizeof(GLfloat)));

                    clock_gettime(CLOCK_MONOTONIC, &t4a);
                    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                                    (GLsizei)render_w, (GLsizei)render_h,
                                    GL_LUMINANCE, GL_UNSIGNED_BYTE, render_local);
                    glDrawArrays(GL_TRIANGLES, 0, 6);
                    clock_gettime(CLOCK_MONOTONIC, &t4b);

                    if (!eglSwapBuffers(g_egl_display, g_egl_surface)) {
                        LOGE("eglSwapBuffers failed: 0x%x", eglGetError());
                        gl_teardown();
                        gl_disabled = 1;
                    } else {
                        did_present = 1;
                    }
                    clock_gettime(CLOCK_MONOTONIC, &t5);
                }
            }

            if (!did_present) {
                ANativeWindow_Buffer nbuf;
                if (ANativeWindow_lock(g_window, &nbuf, NULL) == 0) {
                    clock_gettime(CLOCK_MONOTONIC, &t4a);
                    uint8_t *dst = (uint8_t *)nbuf.bits;
                    int dst_stride = nbuf.stride * 4;
                    int fw = (int)render_w;
                    int fh = (int)render_h;
                    for (int y = 0; y < fh && y < nbuf.height; y++) {
                        uint8_t *row = dst + y * dst_stride;
                        const uint8_t *row_src = render_local + y * fw;
                        int x = 0;
                        for (; x + 16 <= fw && x + 16 <= nbuf.width; x += 16) {
                            uint8x16_t g = vld1q_u8(row_src + x);
                            uint8x16_t ff = vdupq_n_u8(0xFF);
                            uint8x16x4_t rgbx;
                            rgbx.val[0] = g;
                            rgbx.val[1] = g;
                            rgbx.val[2] = g;
                            rgbx.val[3] = ff;
                            vst4q_u8(row + x * 4, rgbx);
                        }
                        for (; x < fw && x < nbuf.width; x++) {
                            uint8_t v = row_src[x];
                            row[x * 4 + 0] = v;
                            row[x * 4 + 1] = v;
                            row[x * 4 + 2] = v;
                            row[x * 4 + 3] = 0xFF;
                        }
                    }
                    clock_gettime(CLOCK_MONOTONIC, &t4b);
                    ANativeWindow_unlockAndPost(g_window);
                    clock_gettime(CLOCK_MONOTONIC, &t5);
                    did_present = 1;
                }
            }

            if (did_present) {
                pthread_mutex_lock(&g_frame_mutex);
                g_render_neon_sum += ms_diff(t4a, t4b);
                g_render_vsync_sum += ms_diff(t4b, t5);
                g_render_stat_frames += 1;
                pthread_mutex_unlock(&g_frame_mutex);
            }
        }
    }

    gl_teardown();
    free(render_local);
    return NULL;
}

static void *decode_thread(void *arg) {
    (void)arg;
    LOGI("Decode thread started, connecting to %s:%d", g_host, g_port);

    g_current_frame = (uint8_t *)calloc(g_pixel_count, 1);
    g_compressed_buf = (uint8_t *)malloc(g_max_compressed);
    uint8_t *decompress_buf = (uint8_t *)malloc(g_pixel_count);
    g_render_frames[0] = (uint8_t *)malloc(g_pixel_count);
    g_render_frames[1] = (uint8_t *)malloc(g_pixel_count);

    if (!g_current_frame || !g_compressed_buf || !decompress_buf || !g_render_frames[0] || !g_render_frames[1]) {
        LOGE("Failed to allocate buffers");
        goto cleanup;
    }
    memset(g_render_frames[0], 0xFF, g_pixel_count);
    memset(g_render_frames[1], 0xFF, g_pixel_count);

    while (g_running) {
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            LOGE("socket() failed: %s", strerror(errno));
            sleep(1);
            continue;
        }

        int flag = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(g_port);
        inet_pton(AF_INET, g_host, &addr.sin_addr);

        LOGI("Connecting to %s:%d ...", g_host, g_port);
        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            LOGE("connect() failed: %s (is ADB reverse tunnel set up?)", strerror(errno));
            close(sock);
            sleep(1);
            continue;
        }

        g_sock = sock;
        LOGI("Connected to server %s:%d", g_host, g_port);
        notify_connection_state(1);

        int frame_count = 0;
        int stat_frames = 0;
        int dropped_frames = 0;
        int skipped_deltas = 0;
        uint32_t last_seq = 0;
        int has_last_seq = 0;
        double recv_sum = 0, decomp_sum = 0, delta_sum = 0;
        struct timespec stat_start;
        clock_gettime(CLOCK_MONOTONIC, &stat_start);

        while (g_running) {
            struct timespec t0, t1, t2, t3;
            clock_gettime(CLOCK_MONOTONIC, &t0);

            uint8_t magic[2];
            if (read_exact(sock, magic, 2) < 0) {
                LOGE("Connection lost");
                break;
            }
            if (magic[0] != MAGIC_FRAME_0) {
                LOGE("Bad magic: 0x%02x 0x%02x", magic[0], magic[1]);
                break;
            }

            if (magic[1] == MAGIC_CMD_1) {
                uint8_t cmd;
                if (read_exact(sock, &cmd, 1) < 0) break;

                if (cmd == CMD_RESOLUTION) {
                    uint8_t res_data[4];
                    if (read_exact(sock, res_data, 4) < 0) break;
                    uint32_t new_w = res_data[0] | (res_data[1] << 8);
                    uint32_t new_h = res_data[2] | (res_data[3] << 8);
                    if (new_w > 0 && new_h > 0 && new_w <= 4096 && new_h <= 4096) {
                        if (reallocate_buffers(new_w, new_h, &decompress_buf)) {
                            if (g_window) {
                                ANativeWindow_setBuffersGeometry(g_window, new_w, new_h,
                                    AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);
                            }
                            LOGI("Resolution → %ux%u (%u pixels)", new_w, new_h, g_pixel_count);
                        } else {
                            LOGE("Resolution change allocation failed");
                        }
                    }
                    continue;
                }

                uint8_t value;
                if (read_exact(sock, &value, 1) < 0) break;
                if (g_jvm && g_activity) {
                    JNIEnv *env;
                    int attached = 0;
                    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
                        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
                        attached = 1;
                    }
                    jclass cls = (*env)->GetObjectClass(env, g_activity);
                    if (cmd == CMD_BRIGHTNESS) {
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setBrightness", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                    } else if (cmd == 0x02) {
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setWarmth", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                    }
                    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
                }
                continue;
            }

            if (magic[1] != MAGIC_FRAME_1) {
                LOGE("Unknown packet type: 0x%02x", magic[1]);
                break;
            }

            uint8_t frame_hdr[9];
            if (read_exact(sock, frame_hdr, 9) < 0) {
                LOGE("Connection lost reading frame header");
                break;
            }

            uint8_t flags = frame_hdr[0];
            uint32_t seq = frame_hdr[1] | (frame_hdr[2] << 8) | (frame_hdr[3] << 16) | (frame_hdr[4] << 24);
            uint32_t payload_len = frame_hdr[5] | (frame_hdr[6] << 8) | (frame_hdr[7] << 16) | (frame_hdr[8] << 24);

            if (has_last_seq && seq != last_seq + 1) {
                int gap = (int)(seq - last_seq - 1);
                if (gap > 0 && gap < 1000) dropped_frames += gap;
            }
            last_seq = seq;
            has_last_seq = 1;

            if (payload_len > g_max_compressed) {
                LOGE("Payload too large: %u", payload_len);
                break;
            }

            if (read_exact(sock, g_compressed_buf, payload_len) < 0) {
                LOGE("Failed to read payload");
                break;
            }
            clock_gettime(CLOCK_MONOTONIC, &t1);

            int decompressed_size = LZ4_decompress_safe(
                (const char *)g_compressed_buf,
                (char *)decompress_buf,
                payload_len,
                g_pixel_count
            );
            clock_gettime(CLOCK_MONOTONIC, &t2);

            if (decompressed_size != (int)g_pixel_count) {
                LOGE("LZ4 decompress failed: got %d, expected %u", decompressed_size, g_pixel_count);
                if (flags & FLAG_KEYFRAME) break;
                continue;
            }

            if (flags & FLAG_KEYFRAME) {
                memcpy(g_current_frame, decompress_buf, g_pixel_count);
            } else if (payload_len < 256) {
                skipped_deltas += 1;
            } else {
                apply_delta_neon(g_current_frame, decompress_buf, g_pixel_count);
            }
            clock_gettime(CLOCK_MONOTONIC, &t3);

            send_ack(sock, seq);
            publish_frame(g_current_frame, seq);

            recv_sum += ms_diff(t0, t1);
            decomp_sum += ms_diff(t1, t2);
            delta_sum += ms_diff(t2, t3);
            frame_count += 1;
            stat_frames += 1;

            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (now.tv_sec - stat_start.tv_sec) +
                             (now.tv_nsec - stat_start.tv_nsec) / 1e9;
            if (elapsed >= 5.0 && stat_frames > 0) {
                double fps = stat_frames / elapsed;
                pthread_mutex_lock(&g_frame_mutex);
                double neon_avg = g_render_stat_frames > 0 ? (g_render_neon_sum / g_render_stat_frames) : 0.0;
                double vsync_avg = g_render_stat_frames > 0 ? (g_render_vsync_sum / g_render_stat_frames) : 0.0;
                int overwritten = g_overwritten_frames;
                g_render_neon_sum = 0.0;
                g_render_vsync_sum = 0.0;
                g_render_stat_frames = 0;
                g_overwritten_frames = 0;
                pthread_mutex_unlock(&g_frame_mutex);

                LOGI("FPS: %.1f | recv: %.1fms | lz4: %.1fms | delta: %.1fms | neon: %.1fms | vsync: %.1fms | %uKB %s | drops: %d | skip: %d | overwritten: %d | total: %d",
                     fps,
                     recv_sum / stat_frames,
                     decomp_sum / stat_frames,
                     delta_sum / stat_frames,
                     neon_avg,
                     vsync_avg,
                     payload_len / 1024,
                     (flags & FLAG_KEYFRAME) ? "KF" : "delta",
                     dropped_frames,
                     skipped_deltas,
                     overwritten,
                     frame_count);

                stat_frames = 0;
                recv_sum = 0;
                decomp_sum = 0;
                delta_sum = 0;
                skipped_deltas = 0;
                stat_start = now;
            }
        }

        if (g_sock >= 0) {
            close(g_sock);
            g_sock = -1;
        }
        LOGI("Disconnected, reconnecting in 1s...");

        if (g_current_frame) {
            memset(g_current_frame, 0xFF, g_pixel_count);
            publish_frame(g_current_frame, g_ready_seq + 1);
        }

        notify_connection_state(0);
        sleep(1);
    }

cleanup:
    if (g_sock >= 0) {
        close(g_sock);
        g_sock = -1;
    }
    free(g_current_frame); g_current_frame = NULL;
    free(g_compressed_buf); g_compressed_buf = NULL;
    free(decompress_buf);
    free(g_render_frames[0]); g_render_frames[0] = NULL;
    free(g_render_frames[1]); g_render_frames[1] = NULL;
    pthread_mutex_lock(&g_frame_mutex);
    g_has_ready_frame = 0;
    pthread_mutex_unlock(&g_frame_mutex);
    pthread_cond_signal(&g_frame_cond);
    LOGI("Decode thread exited");
    return NULL;
}

// JNI: called from Kotlin when Surface is ready
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStart(
    JNIEnv *env, jobject thiz, jobject surface, jstring host, jint port)
{
    if (g_running) return;

    (*env)->GetJavaVM(env, &g_jvm);
    g_activity = (*env)->NewGlobalRef(env, thiz);

    g_window = ANativeWindow_fromSurface(env, surface);
    ANativeWindow_setBuffersGeometry(g_window, g_frame_w, g_frame_h,
        AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);

    const char *host_str = (*env)->GetStringUTFChars(env, host, NULL);
    strncpy(g_host, host_str, sizeof(g_host) - 1);
    (*env)->ReleaseStringUTFChars(env, host, host_str);
    g_port = port;

    g_running = 1;
    pthread_create(&g_render_thread, NULL, render_thread, NULL);
    pthread_create(&g_decode_thread, NULL, decode_thread, NULL);
}

// JNI: called from Kotlin when Surface is destroyed
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStop(
    JNIEnv *env, jobject thiz)
{
    g_running = 0;
    pthread_cond_broadcast(&g_frame_cond);
    if (g_sock >= 0) {
        shutdown(g_sock, SHUT_RDWR);
        close(g_sock);
        g_sock = -1;
    }
    pthread_join(g_decode_thread, NULL);
    pthread_join(g_render_thread, NULL);
    if (g_window) {
        ANativeWindow_release(g_window);
        g_window = NULL;
    }
    if (g_activity) {
        (*env)->DeleteGlobalRef(env, g_activity);
        g_activity = NULL;
    }
}

// mirror_native.c — Daylight Mirror native renderer.
//
// Receives LZ4+delta compressed greyscale frames over TCP,
// decompresses, applies delta, and writes directly to ANativeWindow.
// Entire hot path is C — no JNI calls, no Java GC, no GPU.
//
// Protocol: [0xDA 0x7E] [flags:1B] [length:4B LE] [LZ4 payload]
//   flags bit 0: 1=keyframe, 0=delta (XOR with previous)

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

#include "lz4.h"

#define TAG "DaylightMirror"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// Default resolution (updated dynamically via CMD_RESOLUTION from server)
#define DEFAULT_FRAME_W 1024
#define DEFAULT_FRAME_H 768

// Protocol constants
#define MAGIC_FRAME_0 0xDA
#define MAGIC_FRAME_1 0x7E   // Frame packet: [DA 7E] [flags] [len:4] [payload]
#define MAGIC_CMD_1   0x7F   // Command packet: [DA 7F] [cmd] [payload...]
#define FLAG_KEYFRAME 0x01
#define HEADER_SIZE 7
#define CMD_BRIGHTNESS 0x01
#define CMD_RESOLUTION 0x04

// Global state
static ANativeWindow *g_window = NULL;
static pthread_t g_thread;
static volatile int g_running = 0;
static JavaVM *g_jvm = NULL;
static jobject g_activity = NULL;
static char g_host[64] = "127.0.0.1";
static int g_port = 8888;

// Dynamic frame dimensions (set by CMD_RESOLUTION before first frame)
static uint32_t g_frame_w = DEFAULT_FRAME_W;
static uint32_t g_frame_h = DEFAULT_FRAME_H;
static uint32_t g_pixel_count = DEFAULT_FRAME_W * DEFAULT_FRAME_H;
static uint32_t g_max_compressed = DEFAULT_FRAME_W * DEFAULT_FRAME_H + 256;

// Frame buffers (allocated once, reused — reallocated on resolution change)
static uint8_t *g_current_frame = NULL;   // Decompressed greyscale pixels
static uint8_t *g_compressed_buf = NULL;  // Incoming compressed data

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

// Apply XOR delta in-place using NEON SIMD (processes 16 bytes at a time)
static void apply_delta_neon(uint8_t *frame, const uint8_t *delta, int count) {
    int i = 0;
    // NEON: 16 bytes per iteration
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

// Expand greyscale to RGBX_8888 and write to ANativeWindow buffer.
// Uses NEON to broadcast each grey byte to [G, G, G, 0xFF].
static void blit_grey_to_surface(ANativeWindow *window, const uint8_t *grey) {
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
        LOGE("ANativeWindow_lock failed");
        return;
    }

    // Buffer format is RGBX_8888 (4 bytes per pixel)
    uint8_t *dst = (uint8_t *)buffer.bits;
    int dst_stride = buffer.stride * 4;  // stride is in pixels, we need bytes

    int fw = (int)g_frame_w;
    int fh = (int)g_frame_h;
    for (int y = 0; y < fh && y < buffer.height; y++) {
        uint8_t *row = dst + y * dst_stride;
        const uint8_t *src = grey + y * fw;
        int x = 0;

        // NEON: process 16 greyscale pixels → 16 RGBX pixels (64 bytes output)
        for (; x + 16 <= fw && x + 16 <= buffer.width; x += 16) {
            uint8x16_t g = vld1q_u8(src + x);
            uint8x16_t ff = vdupq_n_u8(0xFF);

            // Interleave: [R,G,B,X] = [grey,grey,grey,0xFF] for each pixel
            // Use zip to interleave pairs, then zip again for quads
            uint8x16x4_t rgbx;
            rgbx.val[0] = g;    // R
            rgbx.val[1] = g;    // G
            rgbx.val[2] = g;    // B
            rgbx.val[3] = ff;   // X (alpha)
            vst4q_u8(row + x * 4, rgbx);
        }

        // Remaining pixels
        for (; x < fw && x < buffer.width; x++) {
            uint8_t v = src[x];
            row[x * 4 + 0] = v;     // R
            row[x * 4 + 1] = v;     // G
            row[x * 4 + 2] = v;     // B
            row[x * 4 + 3] = 0xFF;  // A
        }
    }

    ANativeWindow_unlockAndPost(window);
}

// Main receive + render loop (runs on dedicated thread)
static void *mirror_thread(void *arg) {
    (void)arg;
    LOGI("Mirror thread started, connecting to %s:%d", g_host, g_port);

    // Allocate buffers at current resolution
    g_current_frame = (uint8_t *)calloc(g_pixel_count, 1);
    g_compressed_buf = (uint8_t *)malloc(g_max_compressed);
    uint8_t *decompress_buf = (uint8_t *)malloc(g_pixel_count);

    if (!g_current_frame || !g_compressed_buf || !decompress_buf) {
        LOGE("Failed to allocate buffers");
        goto cleanup;
    }

    while (g_running) {
        // Connect to server
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            LOGE("socket() failed: %s", strerror(errno));
            sleep(1);
            continue;
        }

        // TCP_NODELAY
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

        LOGI("Connected to server %s:%d", g_host, g_port);

        // Notify Kotlin: connected
        if (g_jvm && g_activity) {
            JNIEnv *env;
            int attached = 0;
            if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
                (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
                attached = 1;
            }
            jclass cls = (*env)->GetObjectClass(env, g_activity);
            jmethodID mid = (*env)->GetMethodID(env, cls, "onConnectionState", "(Z)V");
            if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jboolean)1);
            if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
        }

        int frame_count = 0;
        int stat_frames = 0;
        double recv_sum = 0, decomp_sum = 0, delta_sum = 0, blit_sum = 0;
        struct timespec stat_start;
        clock_gettime(CLOCK_MONOTONIC, &stat_start);

        // Frame receive loop
        while (g_running) {
            struct timespec t0, t1, t2, t3, t4;
            clock_gettime(CLOCK_MONOTONIC, &t0);

            // Read first 2 bytes to determine packet type
            uint8_t magic[2];
            if (read_exact(sock, magic, 2) < 0) {
                LOGE("Connection lost");
                break;
            }

            if (magic[0] != MAGIC_FRAME_0) {
                LOGE("Bad magic: 0x%02x 0x%02x", magic[0], magic[1]);
                break;
            }

            // Command packet: [DA 7F] [cmd] [payload...]
            if (magic[1] == MAGIC_CMD_1) {
                uint8_t cmd;
                if (read_exact(sock, &cmd, 1) < 0) break;

                if (cmd == CMD_RESOLUTION) {
                    // Resolution: [w:2 LE] [h:2 LE]
                    uint8_t res_data[4];
                    if (read_exact(sock, res_data, 4) < 0) break;
                    uint32_t new_w = res_data[0] | (res_data[1] << 8);
                    uint32_t new_h = res_data[2] | (res_data[3] << 8);
                    if (new_w > 0 && new_h > 0 && new_w <= 4096 && new_h <= 4096) {
                        g_frame_w = new_w;
                        g_frame_h = new_h;
                        g_pixel_count = new_w * new_h;
                        g_max_compressed = g_pixel_count + 256;
                        // Reallocate buffers
                        free(g_current_frame);
                        free(g_compressed_buf);
                        free(decompress_buf);
                        g_current_frame = (uint8_t *)calloc(g_pixel_count, 1);
                        g_compressed_buf = (uint8_t *)malloc(g_max_compressed);
                        decompress_buf = (uint8_t *)malloc(g_pixel_count);
                        // Update window geometry
                        if (g_window) {
                            ANativeWindow_setBuffersGeometry(g_window, new_w, new_h,
                                AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);
                        }
                        LOGI("Resolution → %ux%u (%u pixels)", new_w, new_h, g_pixel_count);
                    }
                    continue;
                }

                // Other commands: [value:1]
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
                        LOGI("Brightness → %d/255", value);
                    } else if (cmd == 0x02) {  // CMD_WARMTH
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setWarmth", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                        LOGI("Warmth → %d/255", value);
                    }
                    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
                }
                continue;
            }

            // Frame packet: [DA 7E] [flags:1] [length:4]
            if (magic[1] != MAGIC_FRAME_1) {
                LOGE("Unknown packet type: 0x%02x", magic[1]);
                break;
            }

            // Read remaining frame header: [flags:1][length:4]
            uint8_t frame_hdr[5];
            if (read_exact(sock, frame_hdr, 5) < 0) {
                LOGE("Connection lost reading frame header");
                break;
            }

            uint8_t flags = frame_hdr[0];
            uint32_t payload_len = frame_hdr[1] | (frame_hdr[2] << 8) | (frame_hdr[3] << 16) | (frame_hdr[4] << 24);

            if (payload_len > g_max_compressed) {
                LOGE("Payload too large: %u", payload_len);
                break;
            }

            // Read compressed payload
            if (read_exact(sock, g_compressed_buf, payload_len) < 0) {
                LOGE("Failed to read payload");
                break;
            }
            clock_gettime(CLOCK_MONOTONIC, &t1);

            // LZ4 decompress
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

            // Apply frame data
            if (flags & FLAG_KEYFRAME) {
                memcpy(g_current_frame, decompress_buf, g_pixel_count);
            } else {
                apply_delta_neon(g_current_frame, decompress_buf, g_pixel_count);
            }
            clock_gettime(CLOCK_MONOTONIC, &t3);

            // Render to surface
            if (g_window) {
                blit_grey_to_surface(g_window, g_current_frame);
                if (frame_count == 0) {
                    LOGI("First frame rendered: %ux%u %s (%u bytes compressed)",
                         g_frame_w, g_frame_h,
                         (flags & FLAG_KEYFRAME) ? "keyframe" : "delta",
                         payload_len);
                }
            } else {
                if (frame_count == 0) {
                    LOGE("Frame received but g_window is NULL — surface not ready");
                }
            }
            clock_gettime(CLOCK_MONOTONIC, &t4);

            // Accumulate per-stage timing (in ms)
            #define MS(a,b) (((b).tv_sec-(a).tv_sec)*1000.0 + ((b).tv_nsec-(a).tv_nsec)/1e6)
            recv_sum   += MS(t0, t1);
            decomp_sum += MS(t1, t2);
            delta_sum  += MS(t2, t3);
            blit_sum   += MS(t3, t4);

            frame_count++;
            stat_frames++;

            // Log stats every 5 seconds
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (now.tv_sec - stat_start.tv_sec) +
                             (now.tv_nsec - stat_start.tv_nsec) / 1e9;
            if (elapsed >= 5.0 && stat_frames > 0) {
                double fps = stat_frames / elapsed;
                LOGI("FPS: %.1f | recv: %.1fms | lz4: %.1fms | delta: %.1fms | blit: %.1fms | %uKB %s | total: %d",
                     fps,
                     recv_sum / stat_frames,
                     decomp_sum / stat_frames,
                     delta_sum / stat_frames,
                     blit_sum / stat_frames,
                     payload_len / 1024,
                     (flags & FLAG_KEYFRAME) ? "KF" : "delta",
                     frame_count);
                stat_frames = 0;
                recv_sum = decomp_sum = delta_sum = blit_sum = 0;
                stat_start = now;
            }
        }

        close(sock);
        LOGI("Disconnected, reconnecting in 1s...");

        // Clear screen to white on disconnect (e-ink friendly)
        if (g_window && g_current_frame) {
            memset(g_current_frame, 0xFF, g_pixel_count);
            blit_grey_to_surface(g_window, g_current_frame);
        }

        // Notify Kotlin: disconnected
        if (g_jvm && g_activity) {
            JNIEnv *env;
            int attached = 0;
            if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
                (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
                attached = 1;
            }
            jclass cls = (*env)->GetObjectClass(env, g_activity);
            jmethodID mid = (*env)->GetMethodID(env, cls, "onConnectionState", "(Z)V");
            if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jboolean)0);
            if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
        }

        sleep(1);
    }

cleanup:
    free(g_current_frame); g_current_frame = NULL;
    free(g_compressed_buf); g_compressed_buf = NULL;
    free(decompress_buf);
    LOGI("Mirror thread exited");
    return NULL;
}

// JNI: called from Kotlin when Surface is ready
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStart(
    JNIEnv *env, jobject thiz, jobject surface, jstring host, jint port)
{
    if (g_running) return;

    // Store JVM and activity for brightness callbacks from mirror thread
    (*env)->GetJavaVM(env, &g_jvm);
    g_activity = (*env)->NewGlobalRef(env, thiz);

    g_window = ANativeWindow_fromSurface(env, surface);
    ANativeWindow_setBuffersGeometry(g_window, g_frame_w, g_frame_h, AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);

    const char *host_str = (*env)->GetStringUTFChars(env, host, NULL);
    strncpy(g_host, host_str, sizeof(g_host) - 1);
    (*env)->ReleaseStringUTFChars(env, host, host_str);
    g_port = port;

    g_running = 1;
    pthread_create(&g_thread, NULL, mirror_thread, NULL);
}

// JNI: called from Kotlin when Surface is destroyed
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStop(
    JNIEnv *env, jobject thiz)
{
    g_running = 0;
    pthread_join(g_thread, NULL);
    if (g_window) {
        ANativeWindow_release(g_window);
        g_window = NULL;
    }
    if (g_activity) {
        (*env)->DeleteGlobalRef(env, g_activity);
        g_activity = NULL;
    }
}

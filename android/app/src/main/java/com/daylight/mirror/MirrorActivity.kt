// MirrorActivity — minimal Activity that creates a SurfaceView and hands it to native code.
// All heavy lifting (socket, LZ4, delta, render) happens in C via JNI.
// Shows a status overlay when disconnected/reconnecting. Screen clears to white on disconnect.
package com.daylight.mirror

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue

class MirrorActivity : Activity() {

    companion object {
        init { System.loadLibrary("mirror") }

        // Touch input protocol constants — must match InputServer.swift
        const val INPUT_PORT = 8892
        const val INPUT_TOUCH_DOWN: Byte = 0x01
        const val INPUT_TOUCH_MOVE: Byte = 0x02
        const val INPUT_TOUCH_UP: Byte = 0x03
        const val INPUT_SCROLL: Byte = 0x04
        val MAGIC_INPUT = byteArrayOf(0xDA.toByte(), 0x70.toByte())
    }

    private external fun nativeStart(surface: Surface, host: String, port: Int)
    private external fun nativeStop()
    private external fun nativeSetSurfaceSize(width: Int, height: Int)

    private lateinit var statusTitle: TextView
    private lateinit var statusHint: TextView
    private lateinit var statusContainer: LinearLayout
    private var pulseAnimator: ObjectAnimator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isConnected = false
    private var pendingDisconnect: Runnable? = null
    private var touchSender: TouchSender? = null

    // Previous touch position for computing scroll deltas
    private var prevScrollX = 0f
    private var prevScrollY = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Full immersive mode — hide ALL system UI to get the entire physical panel.
        // Uses modern WindowInsetsController API (API 30+). Without LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS,
        // Android reserves pixels for system bars even when hidden, causing resolution mismatch.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes.layoutInDisplayCutoutMode =
            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        window.setDecorFitsSystemWindows(false)

        val frame = FrameLayout(this)

        val surfaceView = SurfaceView(this)
        frame.addView(surfaceView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        // Status overlay — shown when waiting for connection
        statusTitle = TextView(this).apply {
            text = "Waiting for Mac..."
            textSize = 18f
            setTextColor(Color.DKGRAY)
            gravity = Gravity.CENTER_HORIZONTAL
        }
        statusHint = TextView(this).apply {
            text = "1. Connect USB cable\n" +
                "2. Open Daylight Mirror on Mac\n" +
                "3. Start via menu bar or Ctrl+F8"
            textSize = 14f
            setTextColor(Color.GRAY)
            gravity = Gravity.CENTER_HORIZONTAL
            setLineSpacing(4f, 1f)
            setPadding(0, 24, 0, 0)
        }
        statusContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.WHITE)
            addView(statusTitle)
            addView(statusHint)
        }
        frame.addView(statusContainer, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        setContentView(frame)

        // WindowInsetsController must be called after setContentView (decorView exists now)
        window.insetsController?.let { controller ->
            controller.hide(android.view.WindowInsets.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        // Start pulsing the title immediately (waiting for first connection)
        pulseAnimator = ObjectAnimator.ofFloat(statusTitle, "alpha", 1f, 0.3f).apply {
            duration = 2000
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            start()
        }

        // Touch input — capture taps, drags, and two-finger scrolls, send to Mac via InputServer
        surfaceView.setOnTouchListener { view, event ->
            val normX = event.x / view.width
            val normY = event.y / view.height

            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    prevScrollX = event.x
                    prevScrollY = event.y
                    sendTouchPacket(INPUT_TOUCH_DOWN, normX, normY, 0f, 0f, 0)
                }
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount >= 2) {
                        // Two-finger scroll: compute delta from previous position
                        val dx = (event.x - prevScrollX) / view.width
                        val dy = (event.y - prevScrollY) / view.height
                        prevScrollX = event.x
                        prevScrollY = event.y
                        sendTouchPacket(INPUT_SCROLL, normX, normY, dx, dy, 0)
                    } else {
                        sendTouchPacket(INPUT_TOUCH_MOVE, normX, normY, 0f, 0f, 0)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    sendTouchPacket(INPUT_TOUCH_UP, normX, normY, 0f, 0f, 0)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    // Second finger down — start scroll mode, reset delta tracking
                    prevScrollX = event.x
                    prevScrollY = event.y
                }
            }
            true
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                holder.surface.setFrameRate(60.0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                nativeStart(holder.surface, "127.0.0.1", 8888)
                // Start touch input sender — connects to Mac's InputServer via ADB tunnel
                touchSender = TouchSender("127.0.0.1", INPUT_PORT).also { it.start() }
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                // Pass actual surface dimensions to native — this is the real
                // window size after any (or failed) orientation change.
                // Used to detect when the device claims landscape but the
                // surface is still physically portrait (e.g. Boox Palma).
                android.util.Log.i("DaylightMirror", "surfaceChanged: ${width}x${height}")
                nativeSetSurfaceSize(width, height)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                touchSender?.stop()
                touchSender = null
                nativeStop()
            }
        })
    }

    /// Called from native code when connection state changes.
    /// State machine with asymmetric debounce:
    ///   connected → disconnected: wait 2s before showing overlay (native reconnect loop is 1s)
    ///   disconnected → connected: hide overlay immediately
    ///   reconnecting: show minimal "Reconnecting..." (not the full "Waiting" screen)
    @Suppress("unused")
    fun onConnectionState(connected: Boolean) {
        runOnUiThread {
            if (connected) {
                // Cancel any pending disconnect — connection recovered
                pendingDisconnect?.let { handler.removeCallbacks(it) }
                pendingDisconnect = null
                if (!isConnected) {
                    isConnected = true
                    pulseAnimator?.cancel()
                    pulseAnimator = null
                    statusTitle.alpha = 1f
                    statusContainer.visibility = View.GONE
                }
            } else {
                if (isConnected && pendingDisconnect == null) {
                    // Wait 2s before showing overlay — native code reconnects every 1s,
                    // so transient disconnects are absorbed without any visual flicker.
                    pendingDisconnect = Runnable {
                        isConnected = false
                        pendingDisconnect = null
                        // Show minimal reconnecting state (no step-by-step hints yet)
                        statusTitle.text = "Reconnecting..."
                        statusHint.visibility = View.GONE
                        statusContainer.visibility = View.VISIBLE
                        if (pulseAnimator == null) {
                            pulseAnimator = ObjectAnimator.ofFloat(statusTitle, "alpha", 1f, 0.3f).apply {
                                duration = 2000
                                repeatMode = ValueAnimator.REVERSE
                                repeatCount = ValueAnimator.INFINITE
                                interpolator = AccelerateDecelerateInterpolator()
                                start()
                            }
                        }
                        // After 8 more seconds of disconnect, escalate to full waiting screen
                        handler.postDelayed({
                            if (!isConnected) {
                                statusTitle.text = "Waiting for Mac..."
                                statusHint.text = "1. Check USB cable\n" +
                                    "2. Open Daylight Mirror on Mac\n" +
                                    "3. Start via menu bar or Ctrl+F8"
                                statusHint.visibility = View.VISIBLE
                            }
                        }, 8000)
                    }
                    handler.postDelayed(pendingDisconnect!!, 2000)
                }
            }
        }
    }

    /// Called from native code when resolution changes and orientation needs updating.
    /// Portrait = h > w, landscape = w >= h.
    @Suppress("unused")
    fun setOrientation(portrait: Boolean) {
        runOnUiThread {
            requestedOrientation = if (portrait) {
                android.util.Log.i("DaylightMirror", "Switching to portrait orientation")
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                android.util.Log.i("DaylightMirror", "Switching to landscape orientation")
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            }
        }
    }

    /// Called from native code when a brightness command arrives.
    @Suppress("unused")
    fun setBrightness(value: Int) {
        val clamped = value.coerceIn(0, 255)
        runOnUiThread {
            val lp = window.attributes
            lp.screenBrightness = clamped / 255f
            window.attributes = lp
        }
    }

    /// Called from native code when a warmth command arrives.
    @Suppress("unused")
    fun setWarmth(value: Int) {
        val amberRate = (value.coerceIn(0, 255) * 1023) / 255
        runOnUiThread {
            try {
                Settings.System.putInt(contentResolver, "screen_brightness_amber_rate", amberRate)
            } catch (e: Exception) {
                android.util.Log.e("DaylightMirror", "Cannot set amber_rate: ${e.message}")
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            // Re-hide system bars when focus returns (e.g. after a swipe gesture)
            window.insetsController?.let { controller ->
                controller.hide(android.view.WindowInsets.Type.systemBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    override fun onDestroy() {
        touchSender?.stop()
        touchSender = null
        super.onDestroy()
    }

    /// Build and enqueue a 23-byte touch input packet for sending to the Mac.
    private fun sendTouchPacket(type: Byte, x: Float, y: Float, dx: Float, dy: Float, pointerId: Int) {
        val buf = ByteBuffer.allocate(23).order(ByteOrder.LITTLE_ENDIAN)
        buf.put(MAGIC_INPUT)
        buf.put(type)
        buf.putFloat(x)
        buf.putFloat(y)
        buf.putFloat(dx)
        buf.putFloat(dy)
        buf.putInt(pointerId)
        touchSender?.send(buf.array())
    }

    /// Background thread that maintains a TCP connection to the Mac's InputServer
    /// and drains a blocking queue of touch packets. Reconnects automatically on failure.
    inner class TouchSender(private val host: String, private val port: Int) {
        private val queue = LinkedBlockingQueue<ByteArray>()
        @Volatile private var running = false
        private var thread: Thread? = null

        fun start() {
            running = true
            thread = Thread({
                while (running) {
                    var socket: Socket? = null
                    var output: OutputStream? = null
                    try {
                        socket = Socket(host, port)
                        socket.tcpNoDelay = true
                        output = socket.getOutputStream()
                        android.util.Log.i("DaylightMirror", "TouchSender connected to $host:$port")

                        while (running) {
                            val packet = queue.take()
                            output.write(packet)
                            output.flush()
                        }
                    } catch (e: InterruptedException) {
                        // stop() was called
                        break
                    } catch (e: Exception) {
                        android.util.Log.w("DaylightMirror", "TouchSender error: ${e.message}")
                        // Clear stale packets before reconnecting
                        queue.clear()
                    } finally {
                        try { output?.close() } catch (_: Exception) {}
                        try { socket?.close() } catch (_: Exception) {}
                    }
                    // Wait before reconnect attempt
                    if (running) {
                        try { Thread.sleep(1000) } catch (_: InterruptedException) { break }
                    }
                }
            }, "TouchSender").also { it.isDaemon = true }
            thread?.start()
        }

        fun send(packet: ByteArray) {
            if (running) queue.offer(packet)
        }

        fun stop() {
            running = false
            thread?.interrupt()
            thread = null
            queue.clear()
        }
    }
}

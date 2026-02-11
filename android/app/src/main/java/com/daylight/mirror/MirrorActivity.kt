// MirrorActivity — minimal Activity that creates a SurfaceView and hands it to native code.
// All heavy lifting (socket, LZ4, delta, render) happens in C via JNI.
// Shows a status overlay when disconnected/reconnecting. Screen clears to white on disconnect.
package com.daylight.mirror

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.BufferedOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class MirrorActivity : Activity() {

    companion object {
        init { System.loadLibrary("mirror") }

        private const val INPUT_PORT = 8892
        private const val INPUT_DOWN: Byte = 0x01
        private const val INPUT_MOVE: Byte = 0x02
        private const val INPUT_UP: Byte = 0x03
        private const val INPUT_SCROLL: Byte = 0x04
    }

    private external fun nativeStart(surface: Surface, host: String, port: Int)
    private external fun nativeStop()

    private lateinit var statusTitle: TextView
    private lateinit var statusHint: TextView
    private lateinit var statusContainer: LinearLayout
    private var pulseAnimator: ObjectAnimator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isConnected = false
    private var pendingDisconnect: Runnable? = null
    private lateinit var touchSender: TouchSender
    private var activePointerId: Int = -1
    private var inScrollMode = false
    private var lastScrollX = 0f
    private var lastScrollY = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Full immersive mode — hide status bar, nav bar, keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        )

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

        touchSender = TouchSender("127.0.0.1", INPUT_PORT)
        touchSender.start()

        surfaceView.setOnTouchListener { v, event ->
            val width = v.width.toFloat().coerceAtLeast(1f)
            val height = v.height.toFloat().coerceAtLeast(1f)

            when (event.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    activePointerId = event.getPointerId(0)
                    inScrollMode = false
                    sendTouchPacket(INPUT_DOWN, event.x / width, event.y / height, pointerId = activePointerId)
                }

                android.view.MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount >= 2) {
                        val x = (event.getX(0) + event.getX(1)) / 2f
                        val y = (event.getY(0) + event.getY(1)) / 2f
                        if (!inScrollMode) {
                            inScrollMode = true
                            // End drag before switching into scroll mode.
                            if (activePointerId != -1) {
                                val idx = event.findPointerIndex(activePointerId)
                                if (idx >= 0) {
                                    sendTouchPacket(
                                        INPUT_UP,
                                        event.getX(idx) / width,
                                        event.getY(idx) / height,
                                        pointerId = activePointerId
                                    )
                                }
                                activePointerId = -1
                            }
                            lastScrollX = x
                            lastScrollY = y
                        } else {
                            val dx = (x - lastScrollX) / width
                            val dy = (y - lastScrollY) / height
                            sendTouchPacket(INPUT_SCROLL, x / width, y / height, dx = dx, dy = dy)
                            lastScrollX = x
                            lastScrollY = y
                        }
                    } else if (!inScrollMode && activePointerId != -1) {
                        val idx = event.findPointerIndex(activePointerId)
                        if (idx >= 0) {
                            sendTouchPacket(
                                INPUT_MOVE,
                                event.getX(idx) / width,
                                event.getY(idx) / height,
                                pointerId = activePointerId
                            )
                        }
                    }
                }

                android.view.MotionEvent.ACTION_UP,
                android.view.MotionEvent.ACTION_CANCEL -> {
                    if (!inScrollMode && activePointerId != -1) {
                        sendTouchPacket(INPUT_UP, event.x / width, event.y / height, pointerId = activePointerId)
                    }
                    activePointerId = -1
                    inScrollMode = false
                }
            }
            true
        }

        setContentView(frame)

        // Start pulsing the title immediately (waiting for first connection)
        pulseAnimator = ObjectAnimator.ofFloat(statusTitle, "alpha", 1f, 0.3f).apply {
            duration = 2000
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            start()
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                nativeStart(holder.surface, "127.0.0.1", 8888)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
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
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            )
        }
    }

    override fun onDestroy() {
        touchSender.stop()
        super.onDestroy()
    }

    private fun sendTouchPacket(type: Byte, xNorm: Float, yNorm: Float, dx: Float = 0f, dy: Float = 0f, pointerId: Int = 0) {
        val packet = ByteBuffer.allocate(23).order(ByteOrder.LITTLE_ENDIAN)
            .put(0xDA.toByte())
            .put(0x70.toByte())
            .put(type)
            .putFloat(xNorm.coerceIn(0f, 1f))
            .putFloat(yNorm.coerceIn(0f, 1f))
            .putFloat(dx)
            .putFloat(dy)
            .putInt(pointerId)
            .array()
        touchSender.send(packet)
    }

    private class TouchSender(private val host: String, private val port: Int) {
        private val queue = LinkedBlockingQueue<ByteArray>()
        @Volatile private var running = true
        private var socket: Socket? = null
        private var out: BufferedOutputStream? = null
        private val worker = Thread({ runLoop() }, "DaylightTouchSender")

        fun start() {
            worker.start()
        }

        fun stop() {
            running = false
            worker.interrupt()
            closeSocket()
        }

        fun send(packet: ByteArray) {
            if (running) queue.offer(packet)
        }

        private fun runLoop() {
            while (running) {
                try {
                    ensureConnected()
                    val packet = queue.poll(1, TimeUnit.SECONDS) ?: continue
                    out?.write(packet)
                    out?.flush()
                } catch (_: Exception) {
                    closeSocket()
                    try {
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        // Stop path.
                    }
                }
            }
            closeSocket()
        }

        private fun ensureConnected() {
            if (socket?.isConnected == true && socket?.isClosed == false && out != null) return
            closeSocket()
            socket = Socket(host, port).apply { tcpNoDelay = true }
            out = BufferedOutputStream(socket!!.getOutputStream())
        }

        private fun closeSocket() {
            try { out?.close() } catch (_: Exception) {}
            try { socket?.close() } catch (_: Exception) {}
            out = null
            socket = null
        }
    }
}

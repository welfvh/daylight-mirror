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

class MirrorActivity : Activity() {

    companion object {
        init { System.loadLibrary("mirror") }
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
                holder.surface.setFrameRate(60.0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
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
}

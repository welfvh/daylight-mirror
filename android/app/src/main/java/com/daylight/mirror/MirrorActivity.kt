// MirrorActivity — minimal Activity that creates a SurfaceView and hands it to native code.
// All heavy lifting (socket, LZ4, delta, render) happens in C via JNI.
// Also handles brightness commands from the Mac server (Ctrl+F1/F2).
package com.daylight.mirror

import android.app.Activity
import android.os.Bundle
import android.provider.Settings
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager

class MirrorActivity : Activity() {

    companion object {
        init { System.loadLibrary("mirror") }
    }

    private external fun nativeStart(surface: Surface, host: String, port: Int)
    private external fun nativeStop()

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

        val surfaceView = SurfaceView(this)
        setContentView(surfaceView)

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                // Connect to Mac's TCP server via adb reverse tunnel
                nativeStart(holder.surface, "127.0.0.1", 8888)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                nativeStop()
            }
        })
    }

    /// Called from native code when a brightness command arrives.
    /// Uses WindowManager for instant response — no WRITE_SETTINGS permission needed.
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
    /// Sets the Daylight's custom amber backlight rate (0-1023).
    /// Uses Runtime.exec("su") since this is a Daylight-specific protected setting.
    @Suppress("unused")
    fun setWarmth(value: Int) {
        val amberRate = (value.coerceIn(0, 255) * 1023) / 255
        // Settings.System.putInt doesn't work for amber_rate (protected setting).
        // Use shell command instead — works without root on Daylight's custom Android.
        Thread {
            try {
                val process = Runtime.getRuntime().exec(arrayOf(
                    "sh", "-c", "settings put system screen_brightness_amber_rate $amberRate"
                ))
                process.waitFor()
            } catch (e: Exception) {
                android.util.Log.e("DaylightMirror", "Cannot set amber_rate: ${e.message}")
            }
        }.start()
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

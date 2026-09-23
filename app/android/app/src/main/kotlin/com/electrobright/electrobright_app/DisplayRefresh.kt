package com.electrobright.electrobright_app

import android.app.Activity
import android.os.Build
import android.view.Display

/**
 * Flutter never declares a frame rate to Android, so on many devices the app
 * would stay at 60 Hz. Ask for the highest refresh rate available at the
 * current resolution.
 */
object DisplayRefresh {
    fun preferHighestRefreshRate(activity: Activity) {
        val display = displayOf(activity) ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        val params = activity.window.attributes
        if (params.preferredDisplayModeId != best.modeId) {
            params.preferredDisplayModeId = best.modeId
            activity.window.attributes = params
        }
    }

    fun rates(activity: Activity): Pair<Double, Double> {
        val display = displayOf(activity) ?: return 60.0 to 60.0
        val max = display.supportedModes.maxOfOrNull { it.refreshRate } ?: display.refreshRate
        return display.refreshRate.toDouble() to max.toDouble()
    }

    private fun displayOf(activity: Activity): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) activity.display
        else @Suppress("DEPRECATION") activity.windowManager.defaultDisplay
}

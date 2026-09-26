package com.electrobright.electrobright_app

import android.app.Activity
import android.os.Build
import android.view.Display

/**
 * Flutter never declares a frame rate to Android, so on many devices the app
 * would stay at 60 Hz. While something moves or a finger is down the app asks
 * for the highest refresh rate available at the current resolution; the rest
 * of the time it leaves the rate to the system, which can lower it.
 */
object DisplayRefresh {
    fun setHigh(activity: Activity, high: Boolean) {
        val modeId = if (high) highestModeId(activity) ?: return else 0
        val params = activity.window.attributes
        if (params.preferredDisplayModeId != modeId) {
            params.preferredDisplayModeId = modeId
            activity.window.attributes = params
        }
    }

    private fun highestModeId(activity: Activity): Int? {
        val display = displayOf(activity) ?: return null
        val current = display.mode
        return display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate }?.modeId
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

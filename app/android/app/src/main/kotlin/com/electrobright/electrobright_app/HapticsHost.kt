package com.electrobright.electrobright_app

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.VibrationEffect.Composition
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.HapticFeedbackConstants

/**
 * Renders the app's semantic haptic events. Prefers View.performHapticFeedback
 * (respects the user's touch-feedback setting, no permission); signature
 * moments use VibrationEffect compositions when every primitive is supported.
 * Rate limiting and the user's intensity setting live in Dart.
 */
class HapticsHost(private val activity: Activity) : HapticsHostApi {
    private val vibrator: Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (activity.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    override fun prepare(event: HapticEvent) {
        // Android has no warm-up API.
    }

    override fun play(event: HapticEvent, intensity: Double) {
        val scale = intensity.coerceIn(0.0, 1.0).toFloat()
        if (scale <= 0f) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && composition(event, scale)) return
        activity.window?.decorView?.performHapticFeedback(constantFor(event))
    }

    private fun constantFor(event: HapticEvent): Int {
        val api = Build.VERSION.SDK_INT
        return when (event) {
            HapticEvent.SELECTION ->
                if (api >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            HapticEvent.DETENT, HapticEvent.HUE_DETENT ->
                if (api >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            HapticEvent.HUE_DETENT_STRONG ->
                if (api >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            HapticEvent.EDGE ->
                if (api >= 34) HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE
                else HapticFeedbackConstants.CONTEXT_CLICK
            HapticEvent.POWER_ON ->
                when {
                    api >= 34 -> HapticFeedbackConstants.TOGGLE_ON
                    api >= 30 -> HapticFeedbackConstants.CONFIRM
                    else -> HapticFeedbackConstants.VIRTUAL_KEY
                }
            HapticEvent.POWER_OFF ->
                if (api >= 34) HapticFeedbackConstants.TOGGLE_OFF else HapticFeedbackConstants.CONTEXT_CLICK
            HapticEvent.SUCCESS, HapticEvent.PRESET_LOADED, HapticEvent.CONNECTED ->
                if (api >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
            HapticEvent.WARNING, HapticEvent.ERROR ->
                if (api >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
            HapticEvent.LONG_PRESS -> HapticFeedbackConstants.LONG_PRESS
        }
    }

    /** Returns true when a composition was played. */
    private fun composition(event: HapticEvent, s: Float): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val v = vibrator ?: return false
        if (!v.hasVibrator() || !touchFeedbackEnabled()) return false
        val steps: List<Triple<Int, Float, Int>> = when (event) {
            HapticEvent.HUE_DETENT -> listOf(Triple(Composition.PRIMITIVE_TICK, 0.4f * s, 0))
            HapticEvent.HUE_DETENT_STRONG -> listOf(Triple(Composition.PRIMITIVE_TICK, 0.8f * s, 0))
            HapticEvent.POWER_ON -> listOf(Triple(Composition.PRIMITIVE_QUICK_RISE, 0.6f * s, 0), Triple(Composition.PRIMITIVE_CLICK, 0.7f * s, 0))
            HapticEvent.POWER_OFF -> listOf(Triple(Composition.PRIMITIVE_QUICK_FALL, 0.6f * s, 0), Triple(Composition.PRIMITIVE_TICK, 0.5f * s, 0))
            HapticEvent.PRESET_LOADED -> listOf(Triple(Composition.PRIMITIVE_CLICK, 0.8f * s, 0), Triple(Composition.PRIMITIVE_CLICK, 0.8f * s, 60))
            HapticEvent.CONNECTED -> listOf(Triple(Composition.PRIMITIVE_QUICK_RISE, 0.4f * s, 0), Triple(Composition.PRIMITIVE_TICK, 0.6f * s, 20))
            else -> return false
        }
        val primitives = steps.map { it.first }.distinct().toIntArray()
        if (!v.areAllPrimitivesSupported(*primitives)) return false
        val composition = VibrationEffect.startComposition()
        steps.forEach { (primitive, scale, delay) -> composition.addPrimitive(primitive, scale.coerceIn(0f, 1f), delay) }
        val effect = composition.compose()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
        } else {
            v.vibrate(effect)
        }
        return true
    }

    private fun touchFeedbackEnabled(): Boolean =
        Settings.System.getInt(activity.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) != 0
}

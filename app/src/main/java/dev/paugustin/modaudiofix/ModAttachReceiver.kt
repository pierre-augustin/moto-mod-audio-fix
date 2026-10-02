package dev.paugustin.modaudiofix

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.util.Log

private const val TAG = "ModAudioFix"

// Legacy constants from system/media/audio/include/system/audio_policy.h
// (AOSP legacy policy manager, the one used by this HAL 2.0 device).
private const val AUDIO_POLICY_FORCE_FOR_DOCK = 3
private const val AUDIO_POLICY_FORCE_NONE = 0
private const val AUDIO_POLICY_FORCE_ANALOG_DOCK = 8

/**
 * Replaces the proprietary Motorola OEM service missing on LineageOS: when an
 * audio mod (JBL SoundBoost and similar) is attached, stock firmware set
 * force_use(FOR_DOCK, ANALOG_DOCK) so that AudioPolicyManager routes media
 * playback to the mod (AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET) instead of the
 * phone speaker. LineageOS leaves it at DIGITAL_DOCK (9). See README.md.
 */
class ModAttachReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "com.motorola.mod.action.MOD_ENUMERATION_DONE" -> {
                // MOD_ATTACH is only sent as an explicit intent to
                // com.motorola.modservice, so third-party receivers never get
                // it. MOD_ENUMERATION_DONE is broadcast implicitly (receivers
                // need com.motorola.mod.permission.MOD_ACCESS_INFO) and
                // already carries vendor/product.
                val product = intent.getStringExtra("product") ?: "unknown"
                val vendor = intent.getStringExtra("vendor") ?: "unknown"
                Log.i(TAG, "MOD_ENUMERATION_DONE received (vendor=$vendor, product=$product)")

                // Deliberately broad: any mod with an audio output needs the
                // same routing. Narrow down to known products if a non-audio
                // mod ever causes trouble.
                if (looksLikeAudioMod(product)) {
                    applyForceUse(context, AUDIO_POLICY_FORCE_ANALOG_DOCK)
                }
            }

            "com.motorola.mod.action.MOD_DETACH" -> {
                Log.i(TAG, "MOD_DETACH received, resetting forced dock routing")
                applyForceUse(context, AUDIO_POLICY_FORCE_NONE)
            }
        }
    }

    private fun looksLikeAudioMod(product: String): Boolean {
        val p = product.lowercase()
        return p.contains("soundboost") || p.contains("jbl") || p.contains("speaker")
    }

    /**
     * setForceUse is a hidden API (@UnsupportedAppUsage) whose location moved
     * across Android versions. Try AudioManager first, then AudioSystem (the
     * one that works on LineageOS 22.2). Both failures are logged explicitly.
     */
    private fun applyForceUse(context: Context, config: Int) {
        if (tryAudioManager(context, config)) return
        if (tryAudioSystem(config)) return
        Log.e(TAG, "setForceUse not found in AudioManager nor AudioSystem on this build")
    }

    private fun tryAudioManager(context: Context, config: Int): Boolean {
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val method = AudioManager::class.java.getMethod(
                "setForceUse",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType
            )
            method.invoke(am, AUDIO_POLICY_FORCE_FOR_DOCK, config)
            Log.i(TAG, "setForceUse(FOR_DOCK, $config) OK via AudioManager")
            true
        } catch (e: Exception) {
            Log.w(TAG, "AudioManager.setForceUse failed: ${e.message}")
            false
        }
    }

    private fun tryAudioSystem(config: Int): Boolean {
        return try {
            // android.media.AudioSystem is not in the public SDK, so it cannot
            // even be referenced at compile time: hence Class.forName.
            val audioSystemClass = Class.forName("android.media.AudioSystem")
            val method = audioSystemClass.getMethod(
                "setForceUse",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType
            )
            method.invoke(null, AUDIO_POLICY_FORCE_FOR_DOCK, config)
            Log.i(TAG, "setForceUse(FOR_DOCK, $config) OK via AudioSystem")
            true
        } catch (e: Exception) {
            Log.w(TAG, "AudioSystem.setForceUse failed: ${e.message}")
            false
        }
    }
}

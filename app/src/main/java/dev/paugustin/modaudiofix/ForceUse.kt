package dev.paugustin.modaudiofix

import android.util.Log

private const val TAG = "ModAudioFix"

/**
 * Hidden AudioSystem force-use API, called through reflection (android.media.AudioSystem
 * is not in the public SDK). Legacy constants from
 * system/media/audio/include/system/audio_policy.h.
 */
object ForceUse {
    const val FOR_DOCK = 3
    const val FORCE_NONE = 0
    const val FORCE_ANALOG_DOCK = 8

    private val audioSystem by lazy { Class.forName("android.media.AudioSystem") }
    private val intType = Int::class.javaPrimitiveType

    fun set(config: Int, reason: String): Boolean {
        return try {
            audioSystem.getMethod("setForceUse", intType, intType)
                .invoke(null, FOR_DOCK, config)
            Log.i(TAG, "setForceUse(FOR_DOCK, $config) OK ($reason)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "AudioSystem.setForceUse failed: ${e.message}")
            false
        }
    }

    fun get(): Int? {
        return try {
            audioSystem.getMethod("getForceUse", intType).invoke(null, FOR_DOCK) as Int
        } catch (e: Exception) {
            Log.e(TAG, "AudioSystem.getForceUse failed: ${e.message}")
            null
        }
    }
}

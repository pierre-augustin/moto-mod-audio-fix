package dev.paugustin.modaudiofix

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

private const val TAG = "ModAudioFix"

/**
 * Replaces the proprietary Motorola OEM service missing on LineageOS: when an
 * audio mod (JBL SoundBoost and similar) is attached, stock firmware set
 * force_use(FOR_DOCK, ANALOG_DOCK) so that AudioPolicyManager routes media
 * playback to the mod (AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET) instead of the
 * phone speaker. LineageOS leaves it at DIGITAL_DOCK (9). See README.md.
 *
 * This receiver applies the value as soon as the mod is enumerated; DockWatcher
 * then keeps it while the mod stays connected.
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
                    ForceUse.set(ForceUse.FORCE_ANALOG_DOCK, "audio mod attached")
                }
            }

            "com.motorola.mod.action.MOD_DETACH" -> {
                Log.i(TAG, "MOD_DETACH received")
                ForceUse.set(ForceUse.FORCE_NONE, "mod detached")
            }
        }
    }

    private fun looksLikeAudioMod(product: String): Boolean {
        val p = product.lowercase()
        return p.contains("soundboost") || p.contains("jbl") || p.contains("speaker")
    }
}

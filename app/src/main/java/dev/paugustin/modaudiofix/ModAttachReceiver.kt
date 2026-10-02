package dev.paugustin.modaudiofix

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.AudioSystem
import android.util.Log

private const val TAG = "ModAudioFix"

// Constantes historiques de system/media/audio/include/system/audio_policy.h
// (AOSP legacy policy manager — c'est la version employée sur ce HAL 2.0).
private const val AUDIO_POLICY_FORCE_FOR_DOCK = 3
private const val AUDIO_POLICY_FORCE_NONE = 0
private const val AUDIO_POLICY_FORCE_ANALOG_DOCK = 8

/**
 * Remplace le service OEM Motorola absent sur LineageOS : à l'attachement
 * d'un mod audio (JBL SoundBoost et équivalents), le firmware d'origine
 * appelait vraisemblablement setForceUse(FOR_DOCK, ANALOG_DOCK) pour que
 * AudioPolicyManager accepte de router la lecture média vers le mod plutôt
 * que vers le haut-parleur du téléphone. Voir README.md pour le diagnostic
 * complet qui a mené à ce correctif.
 */
class ModAttachReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "com.motorola.mod.action.MOD_ATTACH" -> {
                val product = intent.getStringExtra("product") ?: "inconnu"
                val vendor = intent.getStringExtra("vendor") ?: "inconnu"
                Log.i(TAG, "MOD_ATTACH reçu (vendor=$vendor, produit=$product)")

                // Ciblage volontairement large : n'importe quel mod avec une
                // sortie audio bénéficie du même routage. À restreindre à une
                // liste de produits connus si un mod non-audio pose problème.
                if (looksLikeAudioMod(product)) {
                    applyForceUse(context, AUDIO_POLICY_FORCE_ANALOG_DOCK)
                }
            }

            "com.motorola.mod.action.MOD_DETACH" -> {
                Log.i(TAG, "MOD_DETACH reçu — réinitialisation du routage forcé")
                applyForceUse(context, AUDIO_POLICY_FORCE_NONE)
            }
        }
    }

    private fun looksLikeAudioMod(product: String): Boolean {
        val p = product.lowercase()
        return p.contains("soundboost") || p.contains("jbl") || p.contains("speaker")
    }

    /**
     * setForceUse est une API cachée (@UnsupportedAppUsage) dont
     * l'emplacement exact a bougé selon les versions d'Android. On tente
     * AudioManager d'abord (emplacement le plus courant historiquement),
     * puis AudioSystem en repli. Les deux échecs sont logués explicitement
     * pour pouvoir diagnostiquer sans deviner à l'aveugle.
     */
    private fun applyForceUse(context: Context, config: Int) {
        if (tryAudioManager(context, config)) return
        if (tryAudioSystem(config)) return
        Log.e(
            TAG,
            "setForceUse introuvable via AudioManager et AudioSystem sur " +
                "cette build — voir README.md, section 'Fragilité à connaître'."
        )
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
            Log.w(TAG, "Échec via AudioManager: ${e.message}")
            false
        }
    }

    private fun tryAudioSystem(config: Int): Boolean {
        return try {
            val method = AudioSystem::class.java.getMethod(
                "setForceUse",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType
            )
            method.invoke(null, AUDIO_POLICY_FORCE_FOR_DOCK, config)
            Log.i(TAG, "setForceUse(FOR_DOCK, $config) OK via AudioSystem")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Échec via AudioSystem: ${e.message}")
            false
        }
    }
}

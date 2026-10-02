# Mod Audio Fix — Moto Z3 Play (beckham) / LineageOS 22.2

Remplace un service Motorola propriétaire manquant sur LineageOS, qui empêche
le routage audio vers les mods son (JBL SoundBoost et équivalents) malgré une
détection matérielle parfaitement fonctionnelle.

## Contexte / diagnostic

Sur ce téléphone (Moto Z3 Play, codename `beckham`, LineageOS 22.2 nightly),
le mod JBL SoundBoost est **détecté, connecté et correctement profilé** côté
Android — mais le son continue de sortir par le haut-parleur du téléphone.

Diagnostic établi par inspection live (`adb logcat` + `dumpsys media.audio_policy`)
pendant une session de branchement/débranchement réel du mod :

1. ✅ Le kernel détecte le mod (`gb_audio` greybus, vendor=HARMAN International,
   produit=JBL SoundBoost)
2. ✅ Le HAL audio signale le device (`mods_codec_report_devices`)
3. ✅ Android crée et connecte le device (`AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET`,
   visible dans "Available output devices")
4. ❌ **Le moteur de sélection d'appareil (code hérité `AudioPolicyManager`,
   pas de fichier de config externe sur ce téléphone) n'élit jamais ce device
   pour la lecture média**, car sa logique exige explicitement
   `force_use[FOR_DOCK] == FORCE_ANALOG_DOCK (8)` avant de le considérer — or
   ce paramètre vaut `FORCE_DIGITAL_DOCK (9)` et n'est jamais mis à jour par
   quoi que ce soit sur ce build.

Sur le firmware Motorola d'origine, un service OEM propriétaire (visible dans
les logs sous `ModOEMSubsystemManager`, absent sur LineageOS) devait
probablement appeler `AudioManager.setForceUse(FOR_DOCK, FORCE_ANALOG_DOCK)`
à l'attachement d'un mod audio. C'est exactement ce que fait cette appli.

Un correctif complémentaire a aussi été appliqué directement sur l'appareil
(ajout de "Dock Headset" à `<attachedDevices>` dans
`/vendor/etc/audio_policy_configuration.xml`, pour que le device hérite d'un
profil audio correct) — **déjà appliqué sur ce téléphone** le 2026-10-02.
Fichiers de référence dans `device-files/` :
- `audio_policy_configuration.xml.orig` — version d'origine (sauvegardée aussi
  sur le téléphone dans `/sdcard/audio_policy_configuration.xml.backup`)
- `audio_policy_configuration.xml.patched` — version actuellement en place
  (un seul ajout : `<item>Dock Headset</item>` dans `<attachedDevices>`)

⚠️ **Fragilité à connaître** : `setForceUse` est une API Android cachée
(`@UnsupportedAppUsage`), pas garantie stable d'une version à l'autre. Le code
ci-dessous tente deux emplacements possibles (`AudioManager` puis
`AudioSystem`) par réflexion et logue clairement lequel fonctionne. Si aucun
des deux ne fonctionne sur cette build exacte d'Android 15, il faudra
inspecter `/system/framework/framework.jar` pour localiser la méthode réelle.

## Build

Nécessite Android Studio (ou le SDK + Gradle en ligne de commande). Aucune
dépendance externe — un seul `BroadcastReceiver`.

```bash
# Depuis ce dossier, avec le SDK Android installé :
./gradlew assembleDebug
# APK généré : app/build/outputs/apk/debug/app-debug.apk
```

Si vous n'avez pas encore de `gradlew` local, ouvrez simplement ce dossier
comme projet dans Android Studio — il le régénérera automatiquement.

## Installation (app privilégiée obligatoire)

`MODIFY_AUDIO_ROUTING` est une permission `signature|privileged` : un simple
`adb install` **ne suffit pas**, même signée. L'appli doit être installée
comme application système privilégiée :

```bash
adb root
adb remount

# 1. Copier l'APK en app système privilégiée
adb shell mkdir -p /vendor/priv-app/ModAudioFix
adb push app/build/outputs/apk/debug/app-debug.apk /vendor/priv-app/ModAudioFix/ModAudioFix.apk

# 2. Autoriser la permission signature|privileged pour ce package
adb push device-files/privapp-permissions-modaudiofix.xml /vendor/etc/permissions/

# 3. Redémarrer pour que le système scanne les nouvelles apps système
adb reboot
```

Une fois le téléphone redémarré, rebranchez le mod JBL — le son devrait
basculer dessus automatiquement.

> Si vous me redonnez la main avec le téléphone branché en USB (adb root déjà
> activé), je peux faire les 3 étapes d'installation moi-même une fois l'APK
> compilé — pas besoin de les taper à la main.

## Vérifier que ça marche

```bash
adb logcat | grep ModAudioFix
```

Devrait afficher, au branchement du mod :
```
ModAudioFix: MOD_ATTACH reçu (produit=JBL SoundBoost)
ModAudioFix: setForceUse(FOR_DOCK, FORCE_ANALOG_DOCK) OK via AudioManager
```

## Désinstaller

```bash
adb root && adb remount
adb shell rm -rf /vendor/priv-app/ModAudioFix
adb shell rm /vendor/etc/permissions/privapp-permissions-modaudiofix.xml
adb reboot
```

Pour revenir en arrière sur le fichier audio_policy_configuration.xml modifié,
la version originale est sauvegardée sur le téléphone dans
`/sdcard/audio_policy_configuration.xml.backup`.

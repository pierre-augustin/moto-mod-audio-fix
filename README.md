# Mod Audio Fix — Moto Z3 Play (beckham) / LineageOS 22.2

Makes audio Moto Mods (JBL SoundBoost and similar) actually play sound on
LineageOS 22.2, where the mod is detected but stays silent.

**Validated on 2026-10-02** on a Moto Z3 Play `beckham`, LineageOS 22.2
userdebug, with a JBL SoundBoost: audio plays on the mod after a cold reboot
with no manual step, including pause/resume.

## Diagnosis

The whole low-level stack works: greybus detects the mod (`gb_audio`,
vendor=HARMAN International, product=JBL SoundBoost), the `mods_codec` kernel
driver reports an output (`mods_codec_out_devices=1`, 48 kHz / 16 bit), and
Android creates the `AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET` device
("Dock Headset"). Motorola's stock audio stack did three things that the
LineageOS environment does not:

| # | Missing piece | Symptom | Fix |
|---|---|---|---|
| 1 | `setForceUse(FOR_DOCK, ANALOG_DOCK)` when the mod is attached (Motorola OEM service not present) | Audio keeps playing on the phone speaker | `ModAudioFix` app (this repo) |
| 2 | Mixer paths for the mod device: LineageOS' CAF audio HAL maps `ANLG_DOCK_HEADSET` to the **`usb-headset`** snd device (Motorola's HAL mapped it to `mod-speaker`), and `mixer_paths.xml` has no such path | "Dock speaker" is selected in the volume panel but nothing plays; logcat: `unable to find path 'usb-headset'`, `pcm_prepare returned -1` | `device-files/mixer_paths-mod-usb-headset.patch` |
| 3 | Opening the hostless **`00-65 MADERA-MODS`** PCM (codec AIF2 → mod I2S) during playback. Opening it is what triggers `gb_i2s_mgmt_set_cfg` and `gb_i2s_mgmt_activate_port` on the mod | Stream opens without errors but stays silent (the mod's I2S port is never activated) | `modlinkd` daemon (`native/`) |

Useful details:
- `MOD_ATTACH` is sent as an **explicit** intent to `com.motorola.modservice`
  only, so the app listens to `MOD_ENUMERATION_DONE`, which requires the
  `com.motorola.mod.permission.MOD_ACCESS_INFO` permission.
- The mod is enumerated during boot, **before the first unlock**
  (`RUNNING_LOCKED`): the app must be `directBootAware`, otherwise the
  broadcast is dropped without any log.
- The `Mods Enable Output Devices` ALSA control becomes non-zero when the HAL
  applies `mod-speaker` and goes back to 0 when the stream enters standby.
  `modlinkd` uses it as its trigger, which also covers compress offload.
- The link only runs in **mono**. Stereo is rejected by AIF2, which is most
  likely by design given how small the mod's speaker enclosure is.
- Dead end: adding "Dock Headset" to `<attachedDevices>` in
  `audio_policy_configuration.xml`. It only creates a duplicate device with no
  hardware path behind it (reverted on the phone).

## ⚠️ Warnings

- **Never write data to PCM 65** (`tinyplay ... -d 65`): it is a hostless link
  with no buffer, the kernel oopses in `__arch_copy_from_user` and the phone
  reboots. It must only be opened and started.
- The link only accepts **S16_LE / 1 channel / 48 kHz / 1024×4 periods**.
- `setForceUse` is a hidden API (called through reflection on `AudioSystem`).
- `modlinkd` runs in the `su` SELinux domain (`seclabel u:r:su:s0`), which only
  exists on **userdebug** builds. See "Upstream integration" for a proper fix.
- A LineageOS update overwrites `/system` and `/vendor`: everything must be
  reinstalled after each update.

## Build

```bash
export JAVA_HOME=~/android-toolchain/jdk-17.0.20.1+1
export ANDROID_HOME=~/android-toolchain/android-sdk
gradle assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
./native/build.sh             # → native/modlinkd, native/modlink (NDK r27c)
```

## Install

Prerequisite: Developer options → Rooted debugging (ADB only).
`adb remount` prints "Remount failed" because of unrelated partitions
(`bt_firmware`, `dsp`, `fsg`), but `/` and `/vendor` are remounted read-write
anyway: do not chain the next commands with `&&`.

```bash
adb root
adb remount

# 1. Privileged app (force_use) + whitelist for MODIFY_AUDIO_ROUTING
adb shell mkdir -p /system/priv-app/ModAudioFix
adb push app/build/outputs/apk/debug/app-debug.apk /system/priv-app/ModAudioFix/ModAudioFix.apk
adb push device-files/privapp-permissions-modaudiofix.xml /system/etc/permissions/

# 2. usb-headset → mod mixer paths (keeping a backup of the original)
adb shell cp -p /vendor/etc/mixer_paths.xml /vendor/etc/mixer_paths.xml.orig
adb pull /vendor/etc/mixer_paths.xml /tmp/mixer_paths.xml
patch /tmp/mixer_paths.xml device-files/mixer_paths-mod-usb-headset.patch
adb push /tmp/mixer_paths.xml /vendor/etc/mixer_paths.xml

# 3. modlinkd daemon
adb push native/modlinkd /vendor/bin/modlinkd
adb push device-files/modlinkd.rc /vendor/etc/init/modlinkd.rc
adb shell "chmod 755 /vendor/bin/modlinkd; chmod 644 /vendor/etc/init/modlinkd.rc; \
  chcon u:object_r:vendor_file:s0 /vendor/bin/modlinkd; \
  chcon u:object_r:vendor_configs_file:s0 /vendor/etc/init/modlinkd.rc"

adb reboot
```

## Check

```bash
adb shell dumpsys media.audio_policy | grep "Force use for dock"   # → 8
adb shell getprop init.svc.modlinkd                                # → running
adb logcat | grep -E "ModAudioFix|modlinkd"
```

Expected during playback:
```
ModAudioFix: setForceUse(FOR_DOCK, 8) OK via AudioSystem
modlinkd: mod output devices=0x1 -> link opened
```
and in the kernel log (`dmesg`): `gb_i2s_mgmt_activate_port: opcode: 0x0A, ret: 0`.

`native/modlink` is the manual debugging tool that opens the link once
(`/data/local/tmp/modlink 65 1 48000`, Ctrl-C to close it).

## Uninstall

```bash
adb root
adb remount
adb shell rm -rf /system/priv-app/ModAudioFix /system/etc/permissions/privapp-permissions-modaudiofix.xml
adb shell rm /vendor/bin/modlinkd /vendor/etc/init/modlinkd.rc
adb shell cp -p /vendor/etc/mixer_paths.xml.orig /vendor/etc/mixer_paths.xml
adb reboot
```

## Upstream integration (to propose to the LineageOS beckham maintainer)

The proper version of these three fixes, on the device tree / HAL side:
1. **mixer_paths**: add the `usb-headset` paths (patch above), or better, map
   `ANLG_DOCK_HEADSET` to a `mod-speaker` snd device in the HAL.
2. **PCM 65**: open the hostless `MADERA-MODS` link in the audio HAL
   (`pcm_open` + `pcm_start`, no writes) when the route includes the mod, and
   close it on standby, instead of the daemon.
3. **Dock force_use**: set it on the framework/HAL side when the dock device
   connects, instead of the app.

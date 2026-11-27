# Mod Audio Fix — Moto Z3 Play (beckham) / LineageOS 22.2

Makes audio Moto Mods (JBL SoundBoost and similar) actually play sound on
LineageOS 22.2, where the mod is detected but stays silent, and makes the mod
battery level visible again.

**Validated on 2026-10-02** on a Moto Z3 Play `beckham`, LineageOS 22.2
userdebug, with a JBL SoundBoost: media plays on the mod **in stereo** after a
cold reboot with no manual step, across pause/resume, detach/reattach, calls
and user (profile) switches.

## Status: everything is now in LineageOS

All the pieces are merged in LineageOS 22.2. The last ones, the framework
changes of topic [`analog-dock`](https://review.lineageos.org/q/topic:analog-dock),
were merged on 2026-11-27 (see [Upstream integration](#upstream-integration)).

| Official build | What you need |
|---|---|
| First nightly built after 2026-11-27 and later | **Nothing**: media, ringtones, alarms and speakerphone calls play on the mod out of the box. Uninstall the app if you had it ([Uninstall](#uninstall)) |
| 2026-10-14 to 2026-11-27 | The ModAudioFix app (media only, see the limitations below) |
| Before 2026-10-14 | The full setup below |

The framework changes were validated on 2026-11-27 on a test build with the
whole topic, without the app: media, alarms, timers and incoming call ringtones
play on the mod only; earpiece calls stay on the phone, and speakerphone
switches to the mod (`mod-voice-speaker` calibration). This matches Motorola's
stock behavior, checked on a Z2 Play (`albus`, stock Android 8): ringtones and
alarms play only on the mod when it is attached. nash and messi get the same
overlay.

The rest of this README documents the workaround for older builds and how the
problem was found.

## Recommended setup (builds before the framework changes)

| Piece | What it does | Where |
|---|---|---|
| **Stock audio HAL** | beckham's Motorola audio HAL, run next to the CAF one like nash does. It has native mod support: routes media to `mod-speaker`, opens the mod I2S link, uses the mod calibration, and plays in stereo. **Merged in LineageOS** ([506063](https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/506063), official builds from 2026-10-14 on): `install.sh` is only needed for older builds | `stock-hal/` |
| **ModAudioFix app** | keeps `force_use(FOR_DOCK)` at `ANALOG_DOCK` while the mod is attached, so the audio policy selects the dock device at all | `app/` |
| **Health shim** | fixes the crash of the Motorola health service, so Android shows the mod battery level. **Merged in LineageOS** (2026-10-02): builds after that ship it, and `install.sh` then skips it | `health-shim/` |

On official builds from 2026-10-14 on, **only the ModAudioFix app is
needed**. Without USB debugging (for instance when a supervised Family Link
account is the active profile), install it from recovery: see
[From recovery](#from-recovery-no-usb-debugging-needed).

Known limitations of the app, both fixed by the framework changes:
- **Speakerphone during a call stays on the phone speaker.** On stock firmware
  the audio policy routes speakerphone calls to the dock and the HAL then uses
  `mod-voice-speaker`; on Android 15 the policy picks the phone speaker.
- **Ringtones, alarms and timers are silent while the mod is attached.** With
  `FORCE_ANALOG_DOCK`, the audio policy plays them on the speaker and the dock
  together (`0x802`), a combination Motorola's HAL rejects
  (`platform_get_output_snd_device: Invalid combo device(0x802)`). Detach the
  mod to hear them.

Earpiece calls, microphone, and media after a call (back on the mod) all work.

## Stock audio HAL

LineageOS dropped beckham's prebuilt audio HAL in June 2024
([395968](https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/395968):
"QPR3 enforces interface v5, but our HAL crashes with v5") and has used the CAF
HAL since, which knows nothing about mods. nash still runs its Motorola HAL on
22.2, renamed (`audio.primary.msm8998-moto.so`, `libtinyalsa-moto.so`) and
selected with `ro.hardware.audio.primary`. The same recipe works on beckham:

- `stock-hal/prepare.sh` downloads beckham's HAL and its libraries from
  TheMuppets (`proprietary_vendor_motorola_beckham`, `lineage-20` branch, the
  last one that had them), checks their SHA-256, and renames the ones that also
  exist in CAF form with **same-length names edited in place**
  (`audio.primary.sdm66m.so`, `libtinymoto.so`, `libaudiormoto.so`). That avoids
  restructuring the ELF files: LineageOS pins beckham to patchelf 0.9 because
  newer versions break some 32-bit blobs.
- `install.sh` puts them in `/vendor/lib` and adds
  `ro.hardware.audio.primary=sdm66m` to `/vendor/build.prop` (backed up as
  `.orig`).
- It runs with no crash: the QPR3 interface v5 issue seems gone, like on nash.

What the stock HAL does natively (logcat, tag `audio_mods`):
```
audio_mods: mod's supported usecases: output=0x1e, input=0x0
audio_mods: mods_get_speaker_snd_device(): Selecting device 53 instead of 2
audio_hw_primary: enable_snd_device: snd_device(53: mod-speaker)
msm8974_platform: platform_check_playback_backend_cfg: MODs BE configured as bit_width(16) sample_rate(48000) channels(2)
```
and in `dmesg`: `gb_i2s_mgmt_activate_port: opcode: 0x0A, ret: 0`.

## Why force_use is still needed

`AudioService` sets `FOR_DOCK` to `FORCE_DIGITAL_DOCK` from
`DOCK_AUDIO_MEDIA_ENABLED` at boot (`readDockAudioSettings()`), on every **user
switch**, and on audioserver restarts (`onAudioServerDied()`). The legacy
audio policy only selects `AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET` for media when
`FOR_DOCK == FORCE_ANALOG_DOCK`. With the default value, the stock HAL gets
`speaker` and plays on the phone. The app:
- listens to `com.motorola.mod.action.MOD_ENUMERATION_DONE` / `MOD_DETACH`
  (`MOD_ATTACH` is an explicit intent to `com.motorola.modservice` only); this
  needs the `com.motorola.mod.permission.MOD_ACCESS_INFO` permission;
- is `directBootAware`: the mod is enumerated before the first unlock;
- is `android:persistent` and runs a `DockWatcher` that puts `ANALOG_DOCK` back
  within ~3 s whenever it is reset while the dock device is connected.

## Mod battery level

Android never showed the mod battery level (`mod_level=-1`, ModService: "invalid
battery level. The battery is detached?").
`motorola.hardware.health@1.0-service` reads the mod battery from
`/sys/class/power_supply/gb_battery`, but also calls
`android.hardware.health@2.0::IHealth::getService()` **without a null check**,
then `IHealth::getCapacity()`. LineageOS 22.2 only ships the AIDL health HAL, so
the blob crashed on every read. `libmothealth_shim` interposes `getService()`
and returns a minimal in-process `IHealth` whose `getCapacity()` reads
`/sys/class/power_supply/battery/capacity`; it is added to the blob's
`DT_NEEDED`. Upstream since 2026-10-02
([505961](https://review.lineageos.org/c/LineageOS/android_device_motorola_msm8998-common/+/505961),
[505951](https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/505951)).

The kernel `gb_battery` driver asks the mod firmware for the percentage on every
read, so a mod left unused for months really reports 0 % until it is charged.
On a charger, the phone and the mod charge together; on a weak USB port the mod
only charges once the phone is full (Motorola charger logic, `RCV_SECOND`).

## Alternative: CAF audio HAL (`--caf`)

Before the stock HAL was tested, audio was made to work with the CAF HAL. It is
kept as an alternative (no proprietary audio blob), with two drawbacks: mono
only, and a daemon running as `su` (userdebug builds only). With the CAF HAL,
three pieces are needed:

| # | Missing piece | Symptom | Fix |
|---|---|---|---|
| 1 | `force_use(FOR_DOCK, ANALOG_DOCK)` | Audio keeps playing on the phone speaker | ModAudioFix app (same as above) |
| 2 | Mixer paths: the CAF HAL maps `ANLG_DOCK_HEADSET` to the `usb-headset` snd device, which has no path | "Dock speaker" selected but nothing plays; `unable to find path 'usb-headset'`, `pcm_prepare returned -1` | `device-files/mixer_paths-mod-usb-headset.patch` |
| 3 | Opening the hostless `00-65 MADERA-MODS` PCM (codec AIF2 → mod I2S) during playback, which triggers `gb_i2s_mgmt_set_cfg` / `gb_i2s_mgmt_activate_port` | Stream runs but stays silent | `modlinkd` daemon (`native/`), following the `Mods Enable Output Devices` control |

Notes for this approach:
- **Never write data to PCM 65** (`tinyplay ... -d 65`): it is a hostless link
  with no buffer, the kernel oopses in `__arch_copy_from_user` and the phone
  reboots. It must only be opened and started.
- The link only accepts S16_LE / 1 channel / 48 kHz / 1024×4 periods.
- `modlinkd` and the stock HAL must not run together (the stock HAL opens the
  link itself): `install.sh` removes `modlinkd` in stock mode.
- Dead end: adding "Dock Headset" to `<attachedDevices>` in
  `audio_policy_configuration.xml` only creates a duplicate device.

## Build

```bash
export JAVA_HOME=~/android-toolchain/jdk-17.0.20.1+1
export ANDROID_HOME=~/android-toolchain/android-sdk
gradle assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
./stock-hal/prepare.sh        # → stock-hal/out/ (downloads and checks the stock HAL)
./health-shim/build.sh        # → health-shim/out/ (needs patchelf and the phone on adb)
./native/build.sh             # → native/modlinkd, native/modlink (CAF approach only)
```

No Motorola binary is stored in this repo: `stock-hal/prepare.sh` and
`health-shim/build.sh` fetch them (TheMuppets, or the phone itself).

## Install

### With the script (recommended, also after every LineageOS update)

```bash
sudo apt install patchelf     # once
./install.sh --build          # build everything, install, reboot and check
./install.sh                  # same, reusing what is already built
./install.sh --caf            # CAF HAL approach instead of the stock HAL
```

The script backs up `build.prop`, `mixer_paths.xml` and the Motorola health
blob as `.orig` on the phone and always starts from those backups, so it can be
run again and switched between modes safely. It ends with a reboot and a check
of each piece:

```
==> Checking
  OK    ModAudioFix permission
  OK    stock audio HAL selected
  OK    stock audio HAL loaded
  OK    modlinkd not running
  OK    health shim loaded
  OK    force_use dock (mod attached)
```

Prerequisite: Developer options → Rooted debugging (ADB only). `adb remount`
prints "Remount failed" because of unrelated partitions (`bt_firmware`, `dsp`,
`fsg`), but `/` and `/vendor` are remounted read-write anyway. If the script
stops with "/vendor is still read-only", reboot the phone once (the first
`adb remount` after an update needs it) and run it again.

A LineageOS update overwrites `/system` and `/vendor`: run `./install.sh` again
after each update.

### From recovery (no USB debugging needed)

`recovery/build.sh` builds `recovery/out/ModAudioFix-recovery.zip`, which
installs the app into `/system` from LineageOS recovery and adds an `addon.d`
script (`/system/addon.d/31-modaudiofix.sh`), so **LineageOS updates keep the
app** the same way they keep GApps. Use it on official builds that already ship
the stock audio HAL (2026-10-14 and later).

```bash
gradle assembleDebug
./recovery/build.sh
# Phone: reboot to recovery → Apply update → Apply from ADB
adb sideload recovery/out/ModAudioFix-recovery.zip
# "Signature verification failed" is expected (unsigned zip): choose Yes
```

The installer also reports, read-only, whether the build ships the stock audio
HAL (`Stock audio HAL: present`).

Alternative without sideload: in recovery, Advanced → Enable ADB gives a root
`adb shell` even when Android's own USB debugging is blocked. Mount
`/dev/block/by-name/system_<slot>` read-write (slot from
`getprop ro.boot.slot_suffix`) and copy the three files with mode 644 (755 for
the directory and the `addon.d` script), owner root and context `system_file`.

Writing to `/system` from recovery is safe on beckham's official builds:
dm-verity is disabled there (the GApps `addon.d` relies on it too).

Validated with the zip itself on 2026-11-24 and 2026-11-27 (2026-11-18 and
2026-11-25 nightlies, sideloaded after the ROM and GApps): the app is installed
with its `addon.d` script, `Force use for dock` is 8 after boot and the mod
plays.

### By hand (stock HAL)

```bash
adb root
adb remount

# 1. Privileged app (force_use) + whitelist for MODIFY_AUDIO_ROUTING
adb shell mkdir -p /system/priv-app/ModAudioFix
adb push app/build/outputs/apk/debug/app-debug.apk /system/priv-app/ModAudioFix/ModAudioFix.apk
adb push device-files/privapp-permissions-modaudiofix.xml /system/etc/permissions/

# 2. Stock audio HAL
adb push stock-hal/out/audio.primary.sdm66m.so /vendor/lib/hw/
for f in libtinymoto.so libaudiormoto.so libmotaudioutils.so libunshorten.so libtinycompress_vendor.so; do
    adb push stock-hal/out/$f /vendor/lib/
done
adb shell "cd /vendor/lib && chmod 644 hw/audio.primary.sdm66m.so libtinymoto.so libaudiormoto.so libmotaudioutils.so libunshorten.so libtinycompress_vendor.so && \
  chcon u:object_r:vendor_file:s0 hw/audio.primary.sdm66m.so libtinymoto.so libaudiormoto.so libmotaudioutils.so libunshorten.so libtinycompress_vendor.so"
adb shell "cp -p /vendor/build.prop /vendor/build.prop.orig; echo ro.hardware.audio.primary=sdm66m >> /vendor/build.prop"

# 3. Mod battery level (only on builds before 2026-10-02)
adb shell cp -p /vendor/bin/hw/motorola.hardware.health@1.0-service /vendor/bin/hw/motorola.hardware.health@1.0-service.orig
adb push health-shim/out/libmothealth_shim.so /vendor/lib64/
adb push health-shim/out/motorola.hardware.health@1.0-service /vendor/bin/hw/
adb shell "chmod 644 /vendor/lib64/libmothealth_shim.so; chmod 755 /vendor/bin/hw/motorola.hardware.health@1.0-service; \
  chcon u:object_r:vendor_file:s0 /vendor/lib64/libmothealth_shim.so; \
  chcon u:object_r:hal_health_default_exec:s0 /vendor/bin/hw/motorola.hardware.health@1.0-service"

adb reboot
```

## Check

```bash
adb shell getprop ro.hardware.audio.primary                        # → sdm66m
adb shell dumpsys media.audio_policy | grep "Force use for dock"   # → 8
adb logcat | grep -E "ModAudioFix|audio_mods|modLevel"
```

Expected: `ModAudioFix: setForceUse(FOR_DOCK, 8) OK`, then during playback
`audio_mods: … Selecting device 53 instead of 2`, and `modLevel = <percent>`
with no `getModBatteryProperties fail!`.

## Uninstall

On official builds with the framework changes, only the app has to go. If it
was installed from recovery, also remove its `addon.d` script, or the next
update puts the app back. From recovery (Advanced → Enable ADB), with `/system`
mounted read-write as described in [From recovery](#from-recovery-no-usb-debugging-needed):

```bash
rm -rf <system>/priv-app/ModAudioFix \
       <system>/etc/permissions/privapp-permissions-modaudiofix.xml \
       <system>/addon.d/31-modaudiofix.sh
```

Full uninstall of the setup for older builds:

```bash
adb root
adb remount
adb shell rm -rf /system/priv-app/ModAudioFix /system/etc/permissions/privapp-permissions-modaudiofix.xml
adb shell cp -p /vendor/build.prop.orig /vendor/build.prop
adb shell "cd /vendor/lib && rm hw/audio.primary.sdm66m.so libtinymoto.so libaudiormoto.so libmotaudioutils.so libunshorten.so libtinycompress_vendor.so"
adb shell "[ -f /vendor/etc/mixer_paths.xml.orig ] && cp -p /vendor/etc/mixer_paths.xml.orig /vendor/etc/mixer_paths.xml"
adb shell rm -f /vendor/bin/modlinkd /vendor/etc/init/modlinkd.rc
adb shell rm -f /vendor/lib64/libmothealth_shim.so
adb shell "[ -f /vendor/bin/hw/motorola.hardware.health@1.0-service.orig ] && mv /vendor/bin/hw/motorola.hardware.health@1.0-service.orig /vendor/bin/hw/motorola.hardware.health@1.0-service"
adb reboot
```

## Shared phone (one profile per child)

`install.sh` also sets two things for a phone shared through secondary
profiles, so the children can use it after a reboot without the owner's
credential:
- `settings put global allow_user_switching_when_system_user_locked 1`: Android
  15 otherwise blocks switching users until the system user has been unlocked.
- `bmgr --user 0 activate false` (creates `/data/backup/backup-suppress`): with
  the setting above, unlocking a secondary user while the system user is still
  locked crashes system_server (`UserBackupManagerService` →
  `UserBackupPreferences` reads user 0's credential-encrypted storage) and the
  phone reboots. This turns the Android backup service off for every user, so
  Google backup no longer runs on that phone.

## Upstream integration

See [`upstream/`](upstream) for the details.

- Health shim (mod battery level): merged (2026-10-02).
- Stock audio HAL: merged
  ([506063](https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/506063),
  2026-10-08), in official builds from 2026-10-14. The CAF `mixer_paths`
  change ([505943](https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/505943))
  was abandoned.
- Framework changes that make the app unnecessary and fix speakerphone and
  ringtones: merged on 2026-11-27, topic
  [`analog-dock`](https://review.lineageos.org/q/topic:analog-dock):
  - [514849](https://review.lineageos.org/c/LineageOS/android_lineage-sdk/+/514849)
    lineage-sdk: `config_dockAudioUseAnalogDock` (default false);
  - [506921](https://review.lineageos.org/c/LineageOS/android_frameworks_base/+/506921)
    frameworks_base: with that config, `AudioService` uses `FORCE_ANALOG_DOCK`
    for dock media, as up to Android 13;
  - [506922](https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/506922)
    beckham overlay enabling it (nash and messi got the same overlay);
  - [506923](https://review.lineageos.org/c/LineageOS/android_frameworks_av/+/506923)
    frameworks_av: speakerphone calls go to the analog dock;
  - [514871](https://review.lineageos.org/c/LineageOS/android_frameworks_av/+/514871)
    frameworks_av: ringtones, alarms and other sonification sounds play on the
    analog dock alone, since the HAL rejects the speaker + dock combination.

  The patches in `upstream/` are earlier drafts; the merged versions on Gerrit
  are the reference.

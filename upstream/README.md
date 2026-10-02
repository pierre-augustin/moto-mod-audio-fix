# Upstream proposal: audio Moto Mods on LineageOS 22.2 (beckham)

To: Nolen Johnson (`njohnson` on Gerrit), jro1979 (beckham maintainer)

## Summary

Audio Moto Mods (tested with a JBL SoundBoost) have been silent on beckham
since the prebuilt Motorola audio HAL was dropped in June 2024
([revert of "beckham: Initial support for audio Moto Mods"][revert]: *"QPR3
enforces interface v5, but our HAL crashes with v5"*). Since then the tree has
used the CAF audio HAL, which knows nothing about mods.

I got audio mods working on LineageOS 22.2 **with the CAF HAL**, with no
prebuilt audio blob. It takes three small pieces, each one replacing something
the stock Motorola HAL/framework did. Validated on 2026-10-02 on a beckham
(XT1929, lineage-22.2 userdebug): sound on the mod after a cold boot with no
manual step, pause/resume, detach (media pauses through BECOMING_NOISY) and
reattach (playback moves back to the mod).

The kernel side already works as-is: greybus enumerates the mod, `mods_codec`
reports `out_devices=1` (48 kHz, 16 bit, 2 ch max), and the mod service
connects `AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET` ("Dock Headset").

## The three missing pieces

### 1. Mixer paths for `usb-headset` (patch ready)

The CAF HAL maps `AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET` to
`SND_DEVICE_OUT_USB_HEADSET` (`platform_get_output_snd_device`, AFE proxy
case). `mixer_paths.xml` has `mod`/`mod-speaker` paths but no `usb-headset`
path, so the stream never starts:

```
audio_hw_primary: start_output_stream: ... devices(0x800)
audio_hw_primary: enable_snd_device: snd_device(61: usb-headset)
audio_route: unable to find path 'usb-headset'
audio_route: unable to find path 'deep-buffer-playback usb-headset'
audio_hw_primary: pcm_open_prepare_helper: pcm_prepare returned -1
kernel: SDM660 Media1: ASoC: no backend DAIs enabled for SDM660 Media1
```

Fix: alias the `usb-headset` paths to the existing mod paths.
→ [`beckham/0001-beckham-audio-Route-audio-Moto-Mods-through-usb-headset-paths.patch`](beckham/0001-beckham-audio-Route-audio-Moto-Mods-through-usb-headset-paths.patch)
(applies with `git am` on `lineage-22.2`, validated on device.)

Side effect: a real USB headset going through the primary HAL proxy path
would also get these paths. In practice USB audio is handled by the USB HAL,
and this snd device had no path at all before, so nothing that worked before
breaks. Mapping the dock device to a dedicated `mod-speaker` snd device in the
HAL would be cleaner, but it means touching the shared qcom-caf audio HAL.

### 2. Keeping the hostless `MADERA-MODS` PCM open during playback

With piece 1 alone, the stream runs and `Mods Enable Output Devices` is set
(`gb_mods_aud_enable_devices: out_dev: 1`), but the mod stays silent. The codec
AIF2 → mod I2S link is the hostless dai link `MADERA-MODS`
(`sdm660-ext-dai-links.c`, PCM device 65, codec `mods_codec_shim_dai`).
Opening it is what makes `mods_codec` send `gb_i2s_mgmt_set_cfg` and
`gb_i2s_mgmt_activate_port` to the mod, and `cs47l90_aif2_snd_startup` switch
modbus to I2S. The stock HAL opened it; the CAF HAL never does.

Opening PCM 65 (`pcm_open` + `pcm_start`, **no writes**) while the mod path is
active makes audio play:

```
gb_i2s_mgmt_set_cfg_masks gb rate 128 gb format 2
set_configuration, opcode: 0x03 success
gb_i2s_mgmt_activate_port: opcode: 0x0A, ret: 0
```

Notes:
- Writing data to PCM 65 oopses the kernel (`__arch_copy_from_user` from
  `snd_pcm_lib_write`): it is hostless and has no buffer.
- AIF2 only accepts S16_LE / 1 channel / 48 kHz with 1024×4 periods; stereo
  fails with EINVAL. Mono is most likely by design for this small speaker.
- If the link is opened while no stream feeds AIF2, `activate_port` fails
  with -EIO: it must follow the playback, not just the mod attach.

Proposed implementation: a tiny vendor daemon that polls the
`Mods Enable Output Devices` control (non-zero while the HAL routes to the
mod, back to 0 when the stream goes to standby, which also covers compress
offload) and opens/closes PCM 65 accordingly.
→ [`beckham/modlinkd/`](beckham/modlinkd) (`Android.bp`, `modlinkd.c`,
`modlinkd.rc`) and [`beckham/sepolicy/vendor/`](beckham/sepolicy/vendor).

The daemon logic is validated on device, where it ran in the `su` domain. The
`Android.bp`, the `audioserver` user and the dedicated SELinux domain are
**drafts that have not been built in a LineageOS tree yet**. Doing this inside
the HAL (open PCM 65 in `enable_snd_device` for the mod snd device, close it on
disable) would be the cleaner alternative, if you prefer a HAL change.

### 3. `force_use(FOR_DOCK)` = `ANALOG_DOCK`

`AudioPolicyManager` (legacy engine) only selects
`AUDIO_DEVICE_OUT_ANLG_DOCK_HEADSET` for media when
`force_use[FOR_DOCK] == FORCE_ANALOG_DOCK (8)`. On this build it is
`FORCE_DIGITAL_DOCK (9)`, so media stays on the speaker even though the volume
panel offers the dock speaker. Setting it to 8 when the mod is attached (and
back to `FORCE_NONE` on detach) fixes the selection.

I currently do this with a small privileged app,
[`ModAudioFix`](../app) (in this repo). It listens to
`com.motorola.mod.action.MOD_ENUMERATION_DONE`/`MOD_DETACH` and calls
`AudioSystem.setForceUse` through reflection. Needed details: the
`com.motorola.mod.permission.MOD_ACCESS_INFO` permission (otherwise the
broadcast is filtered silently), `MODIFY_AUDIO_ROUTING` through
privapp-permissions, and `directBootAware` (the mod is enumerated before the
first unlock).

Where the 9 comes from: `AudioService` itself. With
`Settings.Global.DOCK_AUDIO_MEDIA_ENABLED=1` (the default), it sets
`FOR_DOCK = FORCE_DIGITAL_DOCK` in `readDockAudioSettings()` at boot and again
in `onAudioServerDied()`. `FORCE_ANALOG_DOCK` is only set on an
`ACTION_DOCK_EVENT` with `EXTRA_DOCK_STATE_LE_DESK`, and nothing emits a dock
event here: there is no `dock` switch in `/sys/class/switch`. Consequence for
the app approach: after an audioserver restart, the value goes back to 9 until
the mod is reattached.

Cleaner alternatives I can see, and I'd welcome your view:
- expose a `dock` switch (state 3 = LE_DESK) from the kernel while an audio mod
  is attached, so that `DockObserver` + `AudioService` set `FORCE_ANALOG_DOCK`
  on their own, including after an audioserver restart;
- or keep a small privileged app, extended to also reapply the value when
  audioserver restarts.

## Mod battery level (separate change, ready)

Also broken on lineage-22.2: Android never gets the mod battery level
(`BatteryService: getModBatteryProperties fail!`, `mod_level=-1`).
`motorola.hardware.health@1.0-service` crashes with a null pointer
dereference in `MotHealth::getModBatteryProperties()` whenever a battery mod
is attached:

```
F DEBUG   : Cmdline: /vendor/bin/hw/motorola.hardware.health@1.0-service
F DEBUG   : Cause: null pointer dereference
F DEBUG   :   #00 pc 0000000000002b98  /vendor/bin/hw/motorola.hardware.health@1.0-service
              (motorola::hardware::health::V1_0::implementation::MotHealth::getModBatteryProperties(...)+1184)
```

Disassembly shows the blob calls
`android.hardware.health@2.0::IHealth::getService()` without a null check and
then vtable slot `0x98` of `BpHwHealth`, i.e. `getCapacity()`, to read the
main battery level. Everything about the mod itself comes from
`/sys/class/power_supply/gb_battery`. Only the AIDL health HAL is registered
now, so `getService()` returns nullptr.

Fix: `libmothealth_shim`, which interposes `IHealth::getService()` and returns
an in-process `IHealth` whose `getCapacity()` reads
`/sys/class/power_supply/battery/capacity` (all other methods return
`NOT_SUPPORTED`), added to the blob with
`blob_fixup().add_needed('libmothealth_shim.so')`, next to the existing
`libbase_shim.so`.
→ [`beckham/0002-beckham-Shim-HIDL-health-2.0-for-Motorola-health-service.patch`](beckham/0002-beckham-Shim-HIDL-health-2.0-for-Motorola-health-service.patch)

Validated on device with the same source built out of tree (NDK, platform
headers, linked against the device libraries) and the blob patched with
`patchelf --add-needed`: no more crashes, no more
`getModBatteryProperties fail!`, and ModService reports `modLevel = 49` right
after boot. The in-tree `Android.bp` itself has not been built in a full tree
yet.

## What I'm proposing

1. Merge patch 1 (`mixer_paths.xml`): small, self-contained, validated.
2. Agree on where piece 2 should live (vendor daemon as drafted, or the HAL),
   and I will turn it into a proper Gerrit change.
3. Same for piece 3 (bundled privileged app vs framework/dock-state fix).
4. Review the health shim change (patch 0002), which is independent from the
   audio pieces.

The same approach probably applies to nash/messi, which share
`msm8998-common` and the mod paths, but I could only test on beckham.

Full diagnosis, logs and install steps for testers:
<https://github.com/pierre-augustin/moto-mod-audio-fix>

[revert]: https://review.lineageos.org/c/LineageOS/android_device_motorola_beckham/+/395968

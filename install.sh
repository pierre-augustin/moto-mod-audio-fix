#!/bin/sh
# Install (or reinstall after a LineageOS update) every fix from this repo on a
# Moto Z3 Play (beckham) running LineageOS 22.2 userdebug:
#   1. ModAudioFix app (force_use dock = ANALOG_DOCK, kept across user switches)
#   2. Audio HAL for the mod, either:
#      - stock (default): beckham's Motorola audio HAL, set up like nash
#        (native mod support, stereo); see stock-hal/prepare.sh
#      - caf (--caf): CAF HAL + usb-headset mixer paths + modlinkd daemon
#   3. health shim + patched Motorola health blob (mod battery level), skipped
#      when the LineageOS build already ships it (merged upstream)
#
# Safe to run again: build.prop, mixer_paths.xml and the health blob are always
# rebuilt from the .orig backups kept on the phone.
#
# Usage: ./install.sh [--build] [--caf] [--no-reboot]
#   --build      rebuild the APK, modlinkd and the health shim first
#   --caf        use the CAF HAL approach instead of the stock HAL
#   --no-reboot  do not reboot / verify at the end
#
# Needs: adb, patchelf (for the health blob), curl and python3 (stock HAL),
# Developer options -> "Rooted debugging" enabled, phone connected over USB.
set -e
cd "$(dirname "$0")"

BUILD=0
REBOOT=1
AUDIO=stock
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --no-reboot) REBOOT=0 ;;
        --caf) AUDIO=caf ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

APK=app/build/outputs/apk/debug/app-debug.apk
MODLINKD=native/modlinkd
SHIM=health-shim/out/libmothealth_shim.so
BLOB=/vendor/bin/hw/motorola.hardware.health@1.0-service
MIXER=/vendor/etc/mixer_paths.xml
PROP=/vendor/build.prop
STOCK_PROP=ro.hardware.audio.primary=sdm66m
STOCK_LIBS="libtinymoto.so libaudiormoto.so libmotaudioutils.so libunshorten.so libtinycompress_vendor.so"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sh_adb() { adb shell "$@" | tr -d '\r'; }

wait_boot() {
    adb wait-for-device
    until [ "$(sh_adb getprop sys.boot_completed)" = 1 ]; do sleep 3; done
}

step "Checking the phone"
command -v patchelf >/dev/null || die "patchelf not found (needed to patch the health blob)"
adb get-state >/dev/null 2>&1 || die "no phone found by adb"
adb root >/dev/null
sleep 3
adb wait-for-device
[ "$(sh_adb id -u)" = 0 ] || die "adb is not root: enable Developer options -> Rooted debugging"
echo "$(sh_adb getprop ro.lineage.version)"

if [ "$BUILD" = 1 ]; then
    step "Building"
    gradle assembleDebug   # needs JAVA_HOME and ANDROID_HOME, see README
    ./native/build.sh
fi
adb remount >/dev/null 2>&1 || true
# LineageOS builds after 2026-10-02 add libmothealth_shim to the blob themselves.
HEALTH=1
if [ "$(sh_adb "[ -f $BLOB.orig ] || grep -c libmothealth_shim.so $BLOB")" -gt 0 ] 2>/dev/null; then
    HEALTH=0
    echo "Health shim already shipped by this LineageOS build: skipping it"
fi
if [ "$HEALTH" = 1 ]; then
    step "Building the health shim and patching the Motorola blob"
    # Back up the pristine blob first: build.sh patches a copy of the .orig.
    sh_adb "[ -f $BLOB.orig ] || cp -p $BLOB $BLOB.orig"
    rm -rf health-shim/devlibs   # libraries may change with each LineageOS update
    ./health-shim/build.sh
fi
if [ "$AUDIO" = stock ]; then
    step "Preparing the stock audio HAL"
    ./stock-hal/prepare.sh
fi

for f in "$APK"; do [ -f "$f" ] || die "missing $f (run with --build, see README)"; done
[ "$AUDIO" = caf ] && { [ -f "$MODLINKD" ] || die "missing $MODLINKD (run with --build)"; }
[ "$HEALTH" = 1 ] && for f in "$SHIM" health-shim/out/motorola.hardware.health@1.0-service; do
    [ -f "$f" ] || die "missing $f"
done

step "Remounting /system and /vendor read-write"
# "Remount failed" is expected (bt_firmware, dsp, fsg): only / and /vendor matter.
adb remount >/dev/null 2>&1 || true
[ "$(sh_adb 'touch /vendor/.rw_test 2>/dev/null && rm /vendor/.rw_test && echo ok')" = ok ] ||
    die "/vendor is still read-only: reboot the phone once (first remount after an update) and run again"

step "1/3 ModAudioFix app"
sh_adb "mkdir -p /system/priv-app/ModAudioFix && chmod 755 /system/priv-app/ModAudioFix"
adb push "$APK" /system/priv-app/ModAudioFix/ModAudioFix.apk >/dev/null
adb push device-files/privapp-permissions-modaudiofix.xml /system/etc/permissions/ >/dev/null
sh_adb "chmod 644 /system/priv-app/ModAudioFix/ModAudioFix.apk /system/etc/permissions/privapp-permissions-modaudiofix.xml"

sh_adb "[ -f $MIXER.orig ] || cp -p $MIXER $MIXER.orig"
sh_adb "[ -f $PROP.orig ] || cp -p $PROP $PROP.orig"
if [ "$AUDIO" = stock ]; then
    step "2/3 Stock audio HAL"
    adb push stock-hal/out/audio.primary.sdm66m.so /vendor/lib/hw/ >/dev/null
    for f in $STOCK_LIBS; do adb push "stock-hal/out/$f" /vendor/lib/ >/dev/null; done
    sh_adb "cd /vendor/lib && chmod 644 hw/audio.primary.sdm66m.so $STOCK_LIBS && \
        chcon u:object_r:vendor_file:s0 hw/audio.primary.sdm66m.so $STOCK_LIBS"
    sh_adb "cp -p $PROP.orig $PROP && echo $STOCK_PROP >> $PROP"
    # The stock HAL opens the mod link and has its own mod paths: drop the CAF pieces.
    sh_adb "cp -p $MIXER.orig $MIXER; rm -f /vendor/bin/modlinkd /vendor/etc/init/modlinkd.rc"
else
    step "2/3 CAF audio HAL: mixer_paths.xml + modlinkd"
    sh_adb "cp -p $PROP.orig $PROP"   # back to the CAF HAL
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    adb pull "$MIXER.orig" "$tmp/mixer_paths.xml" >/dev/null
    patch -s "$tmp/mixer_paths.xml" device-files/mixer_paths-mod-usb-headset.patch
    adb push "$tmp/mixer_paths.xml" "$MIXER" >/dev/null
    sh_adb "chmod 644 $MIXER && chcon u:object_r:vendor_configs_file:s0 $MIXER"
    adb push "$MODLINKD" /vendor/bin/modlinkd >/dev/null
    adb push device-files/modlinkd.rc /vendor/etc/init/modlinkd.rc >/dev/null
    sh_adb "chmod 755 /vendor/bin/modlinkd && chmod 644 /vendor/etc/init/modlinkd.rc && \
        chcon u:object_r:vendor_file:s0 /vendor/bin/modlinkd && \
        chcon u:object_r:vendor_configs_file:s0 /vendor/etc/init/modlinkd.rc"
fi

if [ "$HEALTH" = 1 ]; then
step "3/3 Health shim"
adb push "$SHIM" /vendor/lib64/libmothealth_shim.so >/dev/null
adb push health-shim/out/motorola.hardware.health@1.0-service "$BLOB" >/dev/null
sh_adb "chmod 644 /vendor/lib64/libmothealth_shim.so && chmod 755 $BLOB && \
    chcon u:object_r:vendor_file:s0 /vendor/lib64/libmothealth_shim.so && \
    chcon u:object_r:hal_health_default_exec:s0 $BLOB"
fi

step "Multi-user: allow switching users while the owner profile is locked"
# Lets each child unlock their own profile after a reboot without the owner's
# credential (Android 15 blocks user switching until the system user unlocks).
sh_adb "settings put global allow_user_switching_when_system_user_locked 1"
# The backup service crashes system_server when a secondary user unlocks while
# the system user is still locked (UserBackupPreferences reads user 0's CE
# storage). Deactivating it for the system user creates /data/backup/backup-suppress,
# which turns the backup service off for every user.
sh_adb "bmgr --user 0 activate false" >/dev/null

if [ "$REBOOT" = 0 ]; then
    step "Done. Reboot the phone to apply."
    exit 0
fi

step "Rebooting"
adb reboot
sleep 5
wait_boot
adb root >/dev/null
sleep 3
adb wait-for-device
sleep 15   # let the mod enumerate and the services settle

step "Checking"
ok=1
check() {
    if [ "$2" = "$3" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (got '$2', expected '$3')"; ok=0; fi
}
check "backup service off (needed for the above)" \
    "$(sh_adb '[ -f /data/backup/backup-suppress ] && echo yes')" yes
check "user switching while owner locked" \
    "$(sh_adb settings get global allow_user_switching_when_system_user_locked)" 1
check "ModAudioFix permission" \
    "$(sh_adb dumpsys package dev.paugustin.modaudiofix | grep -c 'MODIFY_AUDIO_ROUTING: granted=true')" 1
if [ "$AUDIO" = stock ]; then
    check "stock audio HAL selected" "$(sh_adb getprop ro.hardware.audio.primary)" sdm66m
    check "stock audio HAL loaded" \
        "$(sh_adb 'grep -c audio.primary.sdm66m /proc/$(pidof android.hardware.audio.service)/maps' | sed 's/^[1-9][0-9]*$/yes/')" yes
    check "modlinkd not running" "$(sh_adb getprop init.svc.modlinkd | sed 's/^stopped$//')" ""
else
    check "mixer_paths usb-headset paths" "$(sh_adb "grep -c 'path name=\"usb-headset\"' $MIXER")" 1
    check "modlinkd service" "$(sh_adb getprop init.svc.modlinkd)" running
fi
check "health shim loaded" \
    "$(sh_adb 'grep -c mothealth_shim /proc/$(pidof motorola.hardware.health@1.0-service)/maps' | sed 's/^[1-9][0-9]*$/yes/')" yes
if [ "$(sh_adb cat /sys/class/power_supply/gb_battery/capacity 2>/dev/null)" ]; then
    check "force_use dock (mod attached)" \
        "$(sh_adb dumpsys media.audio_policy | sed -n 's/.*Force use for dock: //p')" 8
else
    echo "  SKIP  force_use dock: no mod attached"
fi

[ "$ok" = 1 ] && step "All fixes installed" || die "some checks failed, see README"

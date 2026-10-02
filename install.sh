#!/bin/sh
# Install (or reinstall after a LineageOS update) every fix from this repo on a
# Moto Z3 Play (beckham) running LineageOS 22.2 userdebug:
#   1. ModAudioFix app (force_use dock = ANALOG_DOCK)
#   2. mixer_paths.xml usb-headset -> mod paths
#   3. modlinkd daemon (keeps the MADERA-MODS PCM link open during playback)
#   4. health shim + patched Motorola health blob (mod battery level)
#
# Safe to run again: mixer_paths.xml and the health blob are always rebuilt
# from the .orig backups kept on the phone.
#
# Usage: ./install.sh [--build] [--no-reboot]
#   --build      rebuild the APK, modlinkd and the health shim first
#   --no-reboot  do not reboot / verify at the end
#
# Needs: adb, patchelf (for the health blob), Developer options ->
# "Rooted debugging" enabled, and the phone connected over USB.
set -e
cd "$(dirname "$0")"

BUILD=0
REBOOT=1
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --no-reboot) REBOOT=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

APK=app/build/outputs/apk/debug/app-debug.apk
MODLINKD=native/modlinkd
SHIM=health-shim/out/libmothealth_shim.so
BLOB=/vendor/bin/hw/motorola.hardware.health@1.0-service
MIXER=/vendor/etc/mixer_paths.xml

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
step "Building the health shim and patching the Motorola blob"
# Back up the pristine blob first: build.sh patches a copy of the .orig.
adb remount >/dev/null 2>&1 || true
sh_adb "[ -f $BLOB.orig ] || cp -p $BLOB $BLOB.orig"
rm -rf health-shim/devlibs   # libraries may change with each LineageOS update
./health-shim/build.sh

for f in "$APK" "$MODLINKD" "$SHIM" health-shim/out/motorola.hardware.health@1.0-service; do
    [ -f "$f" ] || die "missing $f (run with --build, see README)"
done

step "Remounting /system and /vendor read-write"
# "Remount failed" is expected (bt_firmware, dsp, fsg): only / and /vendor matter.
adb remount >/dev/null 2>&1 || true
[ "$(sh_adb 'touch /vendor/.rw_test 2>/dev/null && rm /vendor/.rw_test && echo ok')" = ok ] ||
    die "/vendor is still read-only: reboot the phone once (first remount after an update) and run again"

step "1/4 ModAudioFix app"
sh_adb "mkdir -p /system/priv-app/ModAudioFix && chmod 755 /system/priv-app/ModAudioFix"
adb push "$APK" /system/priv-app/ModAudioFix/ModAudioFix.apk >/dev/null
adb push device-files/privapp-permissions-modaudiofix.xml /system/etc/permissions/ >/dev/null
sh_adb "chmod 644 /system/priv-app/ModAudioFix/ModAudioFix.apk /system/etc/permissions/privapp-permissions-modaudiofix.xml"

step "2/4 mixer_paths.xml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sh_adb "[ -f $MIXER.orig ] || cp -p $MIXER $MIXER.orig"
adb pull "$MIXER.orig" "$tmp/mixer_paths.xml" >/dev/null
patch -s "$tmp/mixer_paths.xml" device-files/mixer_paths-mod-usb-headset.patch
adb push "$tmp/mixer_paths.xml" "$MIXER" >/dev/null
sh_adb "chmod 644 $MIXER && chcon u:object_r:vendor_configs_file:s0 $MIXER"

step "3/4 modlinkd"
adb push "$MODLINKD" /vendor/bin/modlinkd >/dev/null
adb push device-files/modlinkd.rc /vendor/etc/init/modlinkd.rc >/dev/null
sh_adb "chmod 755 /vendor/bin/modlinkd && chmod 644 /vendor/etc/init/modlinkd.rc && \
    chcon u:object_r:vendor_file:s0 /vendor/bin/modlinkd && \
    chcon u:object_r:vendor_configs_file:s0 /vendor/etc/init/modlinkd.rc"

step "4/4 Health shim"
adb push "$SHIM" /vendor/lib64/libmothealth_shim.so >/dev/null
adb push health-shim/out/motorola.hardware.health@1.0-service "$BLOB" >/dev/null
sh_adb "chmod 644 /vendor/lib64/libmothealth_shim.so && chmod 755 $BLOB && \
    chcon u:object_r:vendor_file:s0 /vendor/lib64/libmothealth_shim.so && \
    chcon u:object_r:hal_health_default_exec:s0 $BLOB"

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
check "ModAudioFix permission" \
    "$(sh_adb dumpsys package dev.paugustin.modaudiofix | grep -c 'MODIFY_AUDIO_ROUTING: granted=true')" 1
check "mixer_paths usb-headset paths" "$(sh_adb "grep -c 'path name=\"usb-headset\"' $MIXER")" 1
check "modlinkd service" "$(sh_adb getprop init.svc.modlinkd)" running
check "health shim loaded" \
    "$(sh_adb 'grep -c mothealth_shim /proc/$(pidof motorola.hardware.health@1.0-service)/maps' | sed 's/^[1-9][0-9]*$/yes/')" yes
if [ "$(sh_adb cat /sys/class/power_supply/gb_battery/capacity 2>/dev/null)" ]; then
    check "force_use dock (mod attached)" \
        "$(sh_adb dumpsys media.audio_policy | sed -n 's/.*Force use for dock: //p')" 8
else
    echo "  SKIP  force_use dock: no mod attached"
fi

[ "$ok" = 1 ] && step "All fixes installed" || die "some checks failed, see README"

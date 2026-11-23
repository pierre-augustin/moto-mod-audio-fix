#!/bin/sh
# Builds recovery/out/ModAudioFix-recovery.zip: installs the ModAudioFix app
# into /system from LineageOS recovery (adb sideload), with an addon.d script so
# LineageOS updates keep it. Needs the app built first (gradle assembleDebug).
set -e
cd "$(dirname "$0")"
APK=../app/build/outputs/apk/debug/app-debug.apk
[ -f "$APK" ] || { echo "Build the app first: gradle assembleDebug" >&2; exit 1; }

STAGE=out/stage
rm -rf out
mkdir -p "$STAGE/META-INF/com/google/android" "$STAGE/system/priv-app/ModAudioFix" \
         "$STAGE/system/etc/permissions" "$STAGE/system/addon.d"
cp update-binary "$STAGE/META-INF/com/google/android/update-binary"
echo '# dummy, see update-binary' > "$STAGE/META-INF/com/google/android/updater-script"
cp "$APK" "$STAGE/system/priv-app/ModAudioFix/ModAudioFix.apk"
cp ../device-files/privapp-permissions-modaudiofix.xml "$STAGE/system/etc/permissions/"
cp 31-modaudiofix.sh "$STAGE/system/addon.d/"

(cd "$STAGE" && zip -q -r -X ../ModAudioFix-recovery.zip META-INF system)
rm -rf "$STAGE"
sha256sum out/ModAudioFix-recovery.zip

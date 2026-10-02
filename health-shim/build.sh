#!/bin/sh
# Build libmothealth_shim.so and a patched motorola.hardware.health@1.0-service.
# Needs: the Android NDK (r27c tested), patchelf, and the phone connected with
# rooted adb (the Motorola blob and the libraries to link against are pulled
# from it; nothing proprietary is stored in this repo).
set -e
cd "$(dirname "$0")"
NDK="${ANDROID_NDK_HOME:-$HOME/android-toolchain/android-sdk/ndk/27.2.12479018}"
CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
BLOB=/vendor/bin/hw/motorola.hardware.health@1.0-service
mkdir -p out devlibs

for lib in libhidlbase-v32.so libutils-v32.so android.hardware.health@2.0.so libc++.so; do
    [ -f devlibs/$lib ] || adb pull /vendor/lib64/$lib devlibs/ >/dev/null
done
[ -f devlibs/liblog.so ] || adb pull /system/lib64/liblog.so devlibs/ >/dev/null

ROOTS=$(python3 fetch_headers.py | sed -n 's/^ROOTS=//p')
INCS=""
for r in $ROOTS; do INCS="$INCS -I inc/$r"; done

"$CXX" --target=aarch64-linux-android30 -std=c++17 -O2 -fPIC -shared \
    -fno-rtti -fno-exceptions -nostdinc++ -isystem inc_cxx $INCS \
    -D__ANDROID_VNDK__ -Wall -Werror -Wno-unused-parameter \
    -nostdlib++ -Wl,-soname,libmothealth_shim.so -Wl,--no-undefined \
    -o out/libmothealth_shim.so health_shim.cpp \
    devlibs/libhidlbase-v32.so devlibs/libutils-v32.so \
    devlibs/android.hardware.health@2.0.so devlibs/liblog.so devlibs/libc++.so

# Patch the original blob (keep using the .orig backup once it exists).
if adb shell "[ -f $BLOB.orig ]"; then src=$BLOB.orig; else src=$BLOB; fi
adb pull "$src" out/motorola.hardware.health@1.0-service >/dev/null
if ! patchelf --print-needed out/motorola.hardware.health@1.0-service | grep -qx libmothealth_shim.so; then
    patchelf --add-needed libmothealth_shim.so out/motorola.hardware.health@1.0-service
fi
echo "OK: out/libmothealth_shim.so out/motorola.hardware.health@1.0-service"

#!/bin/sh
# Build the native tools with the Android NDK (tested with r27c).
set -e
NDK="${ANDROID_NDK_HOME:-$HOME/android-toolchain/android-sdk/ndk/27.2.12479018}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang"
cd "$(dirname "$0")"
"$CC" -O2 -Wall -o modlinkd modlinkd.c -llog
"$CC" -O2 -Wall -o modlink modlink.c
echo "OK: native/modlinkd native/modlink"

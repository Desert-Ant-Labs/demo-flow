#!/bin/zsh
# Builds WebRTCEchoCancel.xcframework: WebRTC's audio processing (AEC3), as
# packaged by PulseAudio, with the abseil it needs and the C shim in Shim/,
# as one static library for Apple silicon. Needs git, python3 and ninja.
#
#   Packages/EchoCancel/build.sh
#
# Run it again after changing the shim or the version below, and commit the
# xcframework it writes.
set -euo pipefail

VERSION=v2.1
COMMIT=846fe90a289f58b7c9303a635142aa2c7caa93e5
MACOS=26.0

HERE=${0:A:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export MACOSX_DEPLOYMENT_TARGET=$MACOS

git -c advice.detachedHead=false clone -q --depth 1 --branch $VERSION https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$WORK/src"
[[ $(git -C "$WORK/src" rev-parse HEAD) == $COMMIT ]] || { echo "$VERSION is not $COMMIT"; exit 1; }
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" -q --disable-pip-version-check install meson
PATH="$WORK/venv/bin:$PATH"

# abseil from its pinned, hash-checked meson wrap, never a copy installed on this Mac.
(cd "$WORK/src" && meson setup "$WORK/build" --buildtype=release --default-library=static \
  --force-fallback-for=abseil-cpp -Db_ndebug=true >/dev/null)
ninja -C "$WORK/build" >/dev/null

ABSL=$(echo "$WORK"/src/subprojects/abseil-cpp-*(/))
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=$MACOS \
  -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_ARCH_ARM64 -DWEBRTC_HAS_NEON -DNDEBUG \
  -I"$WORK/src/webrtc" -I"$WORK/src" -I"$ABSL" -I"$HERE/Shim" \
  -c "$HERE/Shim/echo_cancel.cc" -o "$WORK/echo_cancel.o"

libtool -static -o "$WORK/libWebRTCEchoCancel.a" "$WORK/echo_cancel.o" $(find "$WORK/build" -name '*.a' ! -path '*/examples/*') 2>/dev/null
strip -S "$WORK/libWebRTCEchoCancel.a"

mkdir -p "$WORK/include"
cp "$HERE/Shim/echo_cancel.h" "$HERE/Shim/module.modulemap" "$WORK/include/"
rm -rf "$HERE/WebRTCEchoCancel.xcframework"
xcodebuild -create-xcframework -library "$WORK/libWebRTCEchoCancel.a" -headers "$WORK/include" \
  -output "$HERE/WebRTCEchoCancel.xcframework" >/dev/null
du -sh "$HERE/WebRTCEchoCancel.xcframework"

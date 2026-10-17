#!/bin/bash
# build-ios.sh - the lifted game + pcrecomp's win32hle as an iOS app.
#
# The same lifted C the Windows and Linux hosts run, cross-compiled for
# armv7/iOS 6 with theos's prebuilt clang. No macOS, no Xcode, no SDL2:
# pcrecomp/runtime/win32hle/ios/ carries the iOS replacements (OpenGL ES
# presenter, RemoteIO sound, CoreText).
#
#   ./build-ios.sh                      # armv7 + armv7s, min iOS 6.0
#   ARCHS="armv7" ./build-ios.sh        # one slice
#   GEN_OPT=-O2 ./build-ios.sh          # the host's own optimisation
#   JOBS=3 ./build-ios.sh               # parallel compile of the generated C
#   GEN_ONLY=1 ./build-ios.sh           # just src/recomp/gen/*.c
#
# The generated C is 5.8M lines and takes the best part of an hour, so the
# objects are kept: a rerun only compiles what is missing or newer.
#
# Env:
#   TOOLCHAIN   dir holding clang/as/ld/lipo   (default /home/jjr/theos/toolchain/linux/iphone/bin)
#   SDKROOT     dir holding iPhoneOS*.sdk      (default /home/jjr/theos/sdks)
#   SDK_armv7   full path of the SDK for that arch, overriding SDKROOT
#   FFMPEG      dir with the iOS FFmpeg .a     (default ../ffmpeg-ios/dist)
#   OUT         build dir                      (default .build-ios)
#   APP_NAME    app name                       (default ra2ios)
#   RA2_TARGET  gamemd (Yuri's Revenge) or game (Red Alert 2)
#   DO_PACKAGE  1 to zip Payload/*.app into an .ipa
#   LDID        ldid, for the ad-hoc signature  (default /usr/bin/ldid)
set -e
ROOT=$(cd "$(dirname "$0")" && pwd -P)
PCRECOMP=${PCRECOMP:-$(cd "$ROOT/../pcrecomp" 2>/dev/null && pwd -P)}
[ -n "$PCRECOMP" ] || PCRECOMP=$ROOT/../pcrecomp
HLE=$PCRECOMP/runtime/win32hle
RA2_TARGET=${RA2_TARGET:-gamemd}
[ "$RA2_TARGET" = game ] && GEN=$ROOT/src/recomp/gen_game || GEN=$ROOT/src/recomp/gen
GEN_OPT=${GEN_OPT:--O1}
OUT=${OUT:-$ROOT/.build-ios}
APP_NAME=${APP_NAME:-ra2ios}
JOBS=${JOBS:-3}
DO_PACKAGE=${DO_PACKAGE:-1}
GEN_ONLY=${GEN_ONLY:-0}
HOST_ONLY=${HOST_ONLY:-0}

[ -f "$GEN/recomp_dispatch.c" ] || { echo "no lift in $GEN - run ./lift_yr.sh first" >&2; exit 2; }

TOOL=${TOOLCHAIN:-/home/jjr/theos/toolchain/linux/iphone/bin}
SDKROOT=${SDKROOT:-/home/jjr/theos/sdks}
FFMPEG=${FFMPEG:-$ROOT/../ffmpeg-ios/dist}
LDID=${LDID:-/usr/bin/ldid}
CLANG=$TOOL/clang
[ -x "$CLANG" ] || { echo "no clang at $CLANG (set TOOLCHAIN)" >&2; exit 2; }

say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ sources
# win32hle: everything but the SDL2 presenters, the selftests and the
# optional Windows-windowed present layer. ios/ has the iOS replacements.
HLE_C=""
for f in "$HLE"/*.c; do
  b=$(basename "$f")
  case "$b" in
    *_selftest.c|screen.c|present.c|dsound.c|gdidc.c) continue ;;
  esac
  HLE_C="$HLE_C $f"
done
IOS_C="$HLE/ios/dsound_ios.c $HLE/ios/gdidc_ios.c $HLE/ios/hle_ios_compat.c \
      $HLE/ios/screen_ios.c $HLE/ios/hle_hid.c"
IOS_M="$HLE/ios/main.m $HLE/ios/HLEAppDelegate.m $HLE/ios/HLEViewController.m $HLE/ios/HLEGLView.m"
HOST_C="$ROOT/src/linux/blowfish.c $ROOT/src/linux/script.c $ROOT/src/linux/mods.c \
        $ROOT/src/runtime/hdvox.c $ROOT/src/runtime/queuefive.c \
        $ROOT/src/ios/ra2_entry.c $ROOT/src/ios/ra2_paths.c"
# src/linux/main.c holds the host's main(); the app delegate owns UIKit's, so
# that one file is compiled under another name.
HOST_C="$HOST_C $ROOT/src/linux/main.c"
GEN_C=$(ls "$GEN"/recomp_*.c)

say "$RA2_TARGET: $(ls "$GEN"/recomp_0*.c | wc -l) generated chunks, $GEN_OPT, -j$JOBS"
mkdir -p "$OUT/obj"

# ------------------------------------------------------------------- arches
ARCHS=${ARCHS:-"armv7 armv7s"}
ALLBIN=""
for a in $ARCHS; do
  case "$a" in
    armv7)   triple=armv7-apple-ios6.0;   min=6.0; sdkname=iPhoneOS6.0.sdk ;;
    armv7s)  triple=armv7s-apple-ios6.0;  min=6.0; sdkname=iPhoneOS6.0.sdk ;;
    arm64)   triple=arm64-apple-ios7.0;  min=7.0; sdkname=iPhoneOS10.3.sdk ;;
    *) echo "unknown arch $a" >&2; exit 2 ;;
  esac
  eval "sdk=\${SDK_$a:-\$SDKROOT/\${sdkname}}"
  [ -d "$sdk" ] || { echo "no SDK at $sdk (set SDK_$a)" >&2; exit 2; }
  say "$a -> $triple, min iOS $min, SDK $sdk"

  O=$OUT/obj/$a
  mkdir -p "$O"
  CFLAGS="-target $triple -isysroot $sdk -miphoneos-version-min=$min
          -O2 -std=gnu99 -fno-strict-aliasing -fwrapv
          -Wall -Wextra -Wno-unused-parameter -Wno-unused-function
          -Wno-deprecated-declarations -Wno-error=unguarded-availability"
  # every object gets the Darwin gaps; the shims get the lifted-code ABI too
  DEFS="-DHLE_PTHREAD_TLS -DRECOMP_RETADDR=0u -DRECOMP_FLAT_MEMORY -DHLE_WITH_FFMPEG"
  INC="-I$HLE -I$PCRECOMP/runtime/recomp32 -I$HLE/ios -I$ROOT/src/linux -I$ROOT/src/runtime
       -I$ROOT/src/ios -I$GEN -I$FFMPEG/include"
  PRE="-include $HLE/ios/hle_ios_compat.h"

  # -- the generated C: the bulk of it. Upstream compiles it at GEN_OPT with
  #    warnings off, because the lifter's output is not warning-clean.
  build_one() {  # build_one <src> <obj> <extra flags...>
    local src=$1 obj=$2; shift 2
    [ -f "$obj" ] && [ "$obj" -nt "$src" ] && [ -z "$STALE" ] && return 0
    "$CLANG" $CFLAGS $DEFS $INC $PRE "$@" -c "$src" -o "$obj"
  }
  export -f build_one 2>/dev/null || true

  need() {  # need <src> <extra flags...> - prints the object path
    local src=$1; shift
    echo "$O/$(echo "$src" | sed "s|^$ROOT/||; s|^$PCRECOMP/||; s|^$HLE/||; s|/|_|g; s|\.c$|.o|; s|\.m$|.o|")"
  }

  if [ "$GEN_ONLY" != 1 ]; then
    say "$a: win32hle + host"
    for f in $HLE_C $IOS_C; do
      o=$(need "$f"); build_one "$f" "$o" -DRECOMP_LOCAL_REGS || exit 1
    done
    for f in $HOST_C; do
      o=$(need "$f")
      extra="-DRECOMP_LOCAL_REGS"
      case "$f" in */src/linux/main.c) extra="$extra -Dmain=ra2_host_main" ;; esac
      build_one "$f" "$o" $extra || exit 1
    done
    for f in $IOS_M; do
      o=$(need "$f"); build_one "$f" "$o" -DRECOMP_LOCAL_REGS -fobjc-arc || exit 1
    done
  fi

  if [ "$HOST_ONLY" = 1 ]; then
    say "$a: host objects built (HOST_ONLY)"
    continue
  fi
  say "$a: generated C (this is the long one)"
  printf '%s\n' $GEN_C | xargs -P "$JOBS" -I{} sh -c '
    src="$1"; O="$2"; CFLAGS="$3"; DEFS="$4"; INC="$5"; PRE="$6"; GEN_OPT="$7"; STALE="$8"
    obj="$O/gen_$(basename "$src" .c).o"
    [ -f "$obj" ] && [ "$obj" -nt "$src" ] && [ -z "$STALE" ] && exit 0
    "$CLANG" $CFLAGS $DEFS -DRECOMP_LOCAL_REGS $INC $PRE -w $GEN_OPT -fno-strict-aliasing -fwrapv \
        -c "$src" -o "$obj"
  ' _ {} "$O" "$CFLAGS" "$DEFS" "$INC" "$PRE" "$GEN_OPT" "${STALE:-}"

  say "$a: link"
  OBJ=$(ls "$O"/*.o)
  "$CLANG" -target "$triple" -isysroot "$sdk" -miphoneos-version-min="$min" \
      -o "$OUT/$APP_NAME-$a" \
      $OBJ \
      "$FFMPEG"/lib/libavformat.a "$FFMPEG"/lib/libavcodec.a "$FFMPEG"/lib/libavutil.a \
      "$FFMPEG"/lib/libswresample.a "$FFMPEG"/lib/libswscale.a \
      -lz -lbz2 -liconv -lm \
      -framework Foundation -framework UIKit -framework QuartzCore -framework OpenGLES \
      -framework CoreGraphics -framework AudioToolbox -framework CoreText \
      -Wl,-dead_strip
  ALLBIN="$ALLBIN $OUT/$APP_NAME-$a"
  say "$a: $(ls -la "$OUT/$APP_NAME-$a" | awk '{print $5" bytes"}')"
done

say "lipo"
[ -n "$ALLBIN" ] || { say "nothing to lipo (HOST_ONLY)"; exit 0; }
"$TOOL/lipo" -create $ALLBIN -output "$OUT/$APP_NAME"
"$TOOL/lipo" -info "$OUT/$APP_NAME"

# ----------------------------------------------------------------- package
if [ "$DO_PACKAGE" = 1 ]; then
  APP=$OUT/$APP_NAME.app
  rm -rf "$APP" "$OUT/Payload" "$OUT/$APP_NAME.ipa"
  mkdir -p "$APP" "$OUT/Payload"
  cp "$OUT/$APP_NAME" "$APP/$APP_NAME"
  sed "s|@@EXEC@@|$APP_NAME|g" "$ROOT/src/ios/Info.plist" > "$APP/Info.plist"
  grep -q "$APP_NAME" "$APP/Info.plist" || { echo "Info.plist template wrong" >&2; exit 1; }
  [ -x "$LDID" ] && "$LDID" -S "$APP" && say "signed with ldid"
  (cd "$OUT" && zip -qr9 "$APP_NAME.ipa" Payload)
  say "$OUT/$APP_NAME.ipa  $(stat -c%s "$OUT/$APP_NAME.ipa") bytes"
fi
say "done"
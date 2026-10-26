#!/bin/sh
# Builds dist/: the HEVC decoder module and its Rust bindings.
# hevc-decoder.wasm is libavcodec (HEVC decoder only) and libavutil, compiled
# from the pinned FFmpeg release and linked as an Emscripten side module.
#
#   build.sh         build dist/: hevc-decoder.wasm,
#                    ffmpeg_decoders_bindings.rs, licence texts, BUILD.md and
#                    SHA256SUMS
#   build.sh dir     print the directory the FFmpeg source is downloaded to
#   build.sh fetch   download and verify the FFmpeg source only
#
# Requires curl, tar with xz, make, a C compiler (for FFmpeg's configure), Rust
# and libclang (for the bindings generator), and an Emscripten SDK at the
# version in scripts/EMSCRIPTEN_VERSION (EMSDK, or emcc on PATH).
#
#   FFMPEG_DECODERS_BUILD_DIR
#       directory for the FFmpeg source and the compiled objects (default:
#       $TMPDIR/ffmpeg-decoders-wasm)
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
HERE=$ROOT/scripts

# shellcheck source=flags.sh
. "$HERE/flags.sh"
BUILD=${FFMPEG_DECODERS_BUILD_DIR:-${TMPDIR:-/tmp}/ffmpeg-decoders-wasm}
BUILD=$BUILD/ffmpeg-$FFMPEG_VERSION-$(printf %.12s "$FFMPEG_SHA256")
TARBALL=ffmpeg-$FFMPEG_VERSION.tar.xz
STAGE=${1:-all}

sha256() {
  (sha256sum "$1" 2> /dev/null || shasum -a 256 "$1") | cut -d' ' -f1
}

# Downloads the FFmpeg source and verifies it against the pin in flags.sh. The
# directory name includes the pin; a verified directory is reused without
# network access.
fetch_source() {
  [ -f "$BUILD/.verified" ] && return 0
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  curl -fsSL "$FFMPEG_URL" -o "$BUILD/$TARBALL"
  actual=$(sha256 "$BUILD/$TARBALL")
  if [ "$actual" != "$FFMPEG_SHA256" ]; then
    rm -rf "$BUILD"
    echo "$FFMPEG_URL is $actual, but flags.sh expects $FFMPEG_SHA256" >&2
    exit 1
  fi
  touch "$BUILD/.verified"
}

case $STAGE in
  dir)
    echo "$BUILD"
    exit 0
    ;;
  fetch)
    fetch_source
    exit 0
    ;;
  all) ;;
  *)
    echo "usage: build.sh [dir | fetch]" >&2
    exit 2
    ;;
esac

fetch_source

if ! command -v emcc > /dev/null \
  && [ -n "${EMSDK:-}" ] && [ -f "$EMSDK/emsdk_env.sh" ]; then
  # emsdk_env.sh locates its directory from the current one when the shell is
  # not bash; source it from there.
  here=$(pwd)
  cd "$EMSDK"
  # shellcheck disable=SC1091
  . ./emsdk_env.sh > /dev/null 2>&1
  cd "$here"
fi
command -v emcc > /dev/null || {
  echo "emcc not found: set EMSDK or source your emsdk_env.sh first" >&2
  exit 1
}
WANTED_EMSCRIPTEN=$(cat "$HERE/EMSCRIPTEN_VERSION")
emcc --version | head -1 | grep -q "$WANTED_EMSCRIPTEN" \
  || echo "warning: Emscripten $WANTED_EMSCRIPTEN" \
    "(scripts/EMSCRIPTEN_VERSION) is the tested version; this is:" \
    "$(emcc --version | head -1)" >&2

# FFmpeg is extracted and configured once; later runs rebuild only what
# changed. The directory name includes a hash of the configure flags; changing
# the flags starts over.
FLAGS_SUM=$(printf '%s' "$HEVC_CONFIGURE_FLAGS" | sha256sum 2> /dev/null \
  | cut -c1-12 || true)
[ -n "$FLAGS_SUM" ] \
  || FLAGS_SUM=$(printf '%s' "$HEVC_CONFIGURE_FLAGS" | shasum -a 256 \
    | cut -c1-12)
TREE=$BUILD/hevc-tree-$FLAGS_SUM
if [ ! -f "$TREE/.configured" ]; then
  rm -rf "$TREE"
  mkdir -p "$TREE"
  tar -xJf "$BUILD/$TARBALL" -C "$TREE" --strip-components=1
  # shellcheck disable=SC2086
  (cd "$TREE" && emconfigure ./configure $HEVC_CONFIGURE_FLAGS \
    && touch .configured)
fi
# Bound the number of jobs: a bare -j starts one compiler per source file, which
# can exhaust the memory of a CI runner.
JOBS=$(nproc 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || echo 4)
(cd "$TREE" \
  && emmake make -j"$JOBS" libavutil/libavutil.a libavcodec/libavcodec.a)

# The module: libavcodec and libavutil, unmodified, as one Emscripten side
# module that exports FFmpeg's C API. It contains no other code. The program
# that loads it provides memory and libc.
# shellcheck disable=SC2086
EXPORTS=$(printf '_%s,' $FFMPEG_FUNCTIONS | sed 's/,$//')
OUT=$ROOT/dist
rm -rf "$OUT"
mkdir -p "$OUT"
emcc -O3 -msimd128 -o "$OUT/hevc-decoder.wasm" \
  "$TREE/libavcodec/libavcodec.a" "$TREE/libavutil/libavutil.a" \
  -sSIDE_MODULE=2 -sWASM_BIGINT=1 -sEXPORTED_FUNCTIONS="$EXPORTS"

# Rust declarations of the same API, generated from the FFmpeg headers the
# module was built from.
VERSION=${TARBALL#ffmpeg-}
VERSION=${VERSION%.tar.xz}
EMROOT=${EMSDK:+$EMSDK/upstream/emscripten}
EMROOT=${EMROOT:-$(dirname "$(command -v emcc)")}
SYSROOT=$EMROOT/cache/sysroot/include
cargo run --quiet --release \
  --manifest-path "$ROOT/crates/gen-bindings/Cargo.toml" \
  --target-dir "$BUILD/rust-gen-bindings" -- \
  "$TREE" "$SYSROOT" "$OUT/ffmpeg_decoders_bindings.rs" "$VERSION" \
  "$FFMPEG_FUNCTIONS"

# Files the LGPL requires beside the module: the licence texts (FFmpeg's from
# the source, Emscripten's and musl's from the SDK) and instructions for
# building a replacement.
cp "$TREE/COPYING.LGPLv2.1" "$OUT/FFmpeg-LGPL-2.1.txt"
cp "$EMROOT/LICENSE" "$OUT/Emscripten-LICENSE.txt"
cp "$EMROOT/system/lib/libc/musl/COPYRIGHT" "$OUT/musl-COPYRIGHT.txt"
FLAGS_LINE=$(printf '%s' "$HEVC_CONFIGURE_FLAGS" | tr '\n' ' ' | tr -s ' ')
sed -e "s|@FFMPEG_VERSION@|$FFMPEG_VERSION|g" \
  -e "s|@FFMPEG_URL@|$FFMPEG_URL|g" \
  -e "s|@FFMPEG_SHA256@|$FFMPEG_SHA256|g" \
  -e "s|@EMSCRIPTEN_VERSION@|$WANTED_EMSCRIPTEN|g" \
  -e "s|@CONFIGURE_FLAGS@|$FLAGS_LINE|g" \
  "$ROOT/docs/BUILD.md.in" > "$OUT/BUILD.md"
(cd "$OUT" && for f in *; do
  printf '%s  %s\n' "$(sha256 "$f")" "$f"
done > ../SHA256SUMS.tmp)
mv "$ROOT/SHA256SUMS.tmp" "$OUT/SHA256SUMS"
ls -l "$OUT"

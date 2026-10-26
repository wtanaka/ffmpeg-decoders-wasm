#!/bin/sh
# Runs a test program against dist/hevc-decoder.wasm, as any consumer would:
#
#   1. crates/check-module (Rust, wasm32-unknown-emscripten) calls FFmpeg
#      through dist/ffmpeg_decoders_bindings.rs: it finds the HEVC decoder,
#      opens it and flushes it.
#   2. emcc links the program with dist/hevc-decoder.wasm. The program is the
#      main module; the side module is named on the command line.
#   3. node runs the program, which loads hevc-decoder.wasm from its own
#      directory.
#
# Exit status 0: the module loads, exports every function the bindings declare,
# and the decoder opens. No video is decoded. Requires scripts/build.sh to have
# run.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST=$ROOT/dist
# shellcheck source=flags.sh
. "$ROOT/scripts/flags.sh"
BUILD=${FFMPEG_DECODERS_BUILD_DIR:-${TMPDIR:-/tmp}/ffmpeg-decoders-wasm}
BUILD=$BUILD/ffmpeg-$FFMPEG_VERSION-$(printf %.12s "$FFMPEG_SHA256")

if ! command -v emcc > /dev/null \
  && [ -n "${EMSDK:-}" ] && [ -f "$EMSDK/emsdk_env.sh" ]; then
  here=$(pwd)
  cd "$EMSDK"
  # shellcheck disable=SC1091
  . ./emsdk_env.sh > /dev/null 2>&1
  cd "$here"
fi

TARGET=wasm32-unknown-emscripten
FFMPEG_DECODERS_BINDINGS="$DIST/ffmpeg_decoders_bindings.rs" \
  RUSTFLAGS="-C relocation-model=pic" \
  cargo build --release --target "$TARGET" \
  --manifest-path "$ROOT/crates/check-module/Cargo.toml" \
  --target-dir "$BUILD/rust-check-module"

RUN=$BUILD/check-run
rm -rf "$RUN"
mkdir -p "$RUN"
cp "$DIST/hevc-decoder.wasm" "$RUN/"
LIB=$BUILD/rust-check-module/$TARGET/release/libcheck_module.a
# The side module is named on the command line so that emcc keeps the C library
# functions it needs; at run time it is loaded from the program's directory.
(cd "$RUN" && emcc "$LIB" hevc-decoder.wasm -o check.js \
  -sMAIN_MODULE=2 -sENVIRONMENT=node -sWASM_BIGINT=1 \
  -sALLOW_MEMORY_GROWTH=1 -sEXPORTED_FUNCTIONS=_main && node check.js)
echo "check: ok"

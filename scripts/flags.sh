# The FFmpeg source the decoder is compiled from: the upstream release tarball,
# verified against the SHA-256 below. To change the version, change the version
# and the SHA-256 together. The Emscripten version is in EMSCRIPTEN_VERSION.
FFMPEG_VERSION=7.1.1
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1

# configure flags: the HEVC decoder only, LGPL (no --enable-gpl,
# --enable-nonfree, --enable-version3 or external libraries), no demuxers, no
# filters, no scaler.
HEVC_CONFIGURE_FLAGS="--ar=emar --arch=x86_32 --cc=emcc --cxx=em++
  --dep-cc=emcc --disable-asm --disable-autodetect --disable-avdevice
  --disable-avfilter --disable-avformat --disable-debug --disable-doc
  --disable-everything --disable-inline-asm --disable-network
  --disable-programs --disable-pthreads --disable-runtime-cpudetect
  --disable-stripping --disable-swresample --disable-swscale --disable-x86asm
  --extra-cflags=-msimd128 --enable-cross-compile --enable-decoder=hevc
  --enable-pic --disable-small --nm=emnm --objcc=emcc --ranlib=emranlib
  --target-os=none"

# FFmpeg C API functions exported by the module and declared by the generated
# Rust bindings. One list serves both, so they cannot disagree. Names only;
# build.sh adds the `_` prefix the linker expects.
FFMPEG_FUNCTIONS="avcodec_find_decoder avcodec_alloc_context3
  avcodec_free_context avcodec_parameters_alloc avcodec_parameters_free
  avcodec_parameters_to_context avcodec_open2 avcodec_send_packet
  avcodec_receive_frame avcodec_flush_buffers av_packet_alloc av_packet_free
  av_packet_unref av_packet_from_data av_frame_alloc av_frame_free
  av_frame_unref av_frame_move_ref av_malloc av_mallocz av_free"

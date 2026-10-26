//! Uses hevc-decoder.wasm as a consumer does, through FFmpeg's API as declared
//! by the generated bindings: finds the HEVC decoder, opens it, flushes it and
//! expects end of stream (no frames). It decodes no video. `main` returns the
//! number of the failed step, or 0.

#![allow(
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    dead_code,
    unsafe_code
)]
#![allow(
    clippy::all,
    clippy::pedantic,
    clippy::nursery,
    unreachable_pub,
    missing_debug_implementations
)]

mod ffi {
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

use ffi::*;
use std::ptr;

/// `AVERROR_EOF`: negated `FFERRTAG('E', 'O', 'F', ' ')`. A macro, so absent
/// from the bindings.
const AVERROR_EOF: i32 = -541_478_725;

/// The number of the first failed step (1 and up), or 0.
unsafe fn check() -> i32 {
    let codec = avcodec_find_decoder(AVCodecID::AV_CODEC_ID_HEVC);
    if codec.is_null() {
        return 1;
    }
    let mut par = avcodec_parameters_alloc();
    (*par).codec_type = AVMediaType::AVMEDIA_TYPE_VIDEO;
    (*par).codec_id = AVCodecID::AV_CODEC_ID_HEVC;
    let mut ctx = avcodec_alloc_context3(codec);
    if avcodec_parameters_to_context(ctx, par) < 0 {
        return 2;
    }
    (*ctx).thread_count = 1; // the module is single-threaded
    if avcodec_open2(ctx, codec, ptr::null_mut()) != 0 {
        return 3;
    }
    let mut frame = av_frame_alloc();
    if avcodec_send_packet(ctx, ptr::null()) != 0 {
        return 4;
    }
    if avcodec_receive_frame(ctx, frame) != AVERROR_EOF {
        return 5;
    }
    av_frame_free(&raw mut frame);
    avcodec_free_context(&raw mut ctx);
    avcodec_parameters_free(&raw mut par);
    0
}

#[no_mangle]
pub extern "C" fn main() -> i32 {
    // SAFETY: every pointer passed to FFmpeg was returned by FFmpeg.
    unsafe { check() }
}

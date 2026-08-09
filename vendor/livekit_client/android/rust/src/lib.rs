// SPDX-License-Identifier: AGPL-3.0-or-later
//
// JNI bridge exposing DeepFilterNet3 noise suppression to
// io.livekit.plugin.DeepFilterNoiseProcessor (Kotlin), as an Android
// replacement for Krisp - which requires LiveKit Cloud licensing that a
// self-hosted server can't provide and silently passes audio through
// unprocessed instead. Mirrors fluxer_desktop's
// native/webrtc-sender/src/deep_filter.rs: same model, same tract inference
// engine, same 48kHz/mono/480-sample-frame contract (confirmed to match what
// Android's WebRTC capture-processing hook actually hands us).

use std::panic::{self, AssertUnwindSafe};

use df::tract::{DfParams, DfTract, RuntimeParams};
use jni::JNIEnv;
use jni::objects::{JClass, JShortArray};
use jni::sys::jlong;
use ndarray::Array2;

const SAMPLE_RATE_HZ: usize = 48_000;
const NUM_CHANNELS: usize = 1;
const FRAME_SAMPLES: usize = 480;
// Matches web's DeepFilterNoiseProcessor.ts DEFAULT_SUPPRESSION_LEVEL, for a
// consistent "Enhanced" strength across platforms. This app has no separate
// numeric noise-suppression-level control (only the none/standard/enhanced
// tier), so this is a fixed constant rather than a runtime parameter.
const DEFAULT_LEVEL_DB: f32 = 80.0;

const SAMPLE_SCALE_I16_TO_F32: f32 = 1.0 / 32_768.0;
const SAMPLE_SCALE_F32_TO_I16: f32 = 32_767.0;

struct Processor {
    model: DfTract,
    input: Array2<f32>,
    output: Array2<f32>,
}

impl Processor {
    fn new(level_db: f32) -> Result<Processor, String> {
        let params = RuntimeParams::default_with_ch(NUM_CHANNELS).with_atten_lim(level_db);
        let model = DfTract::new(DfParams::default(), &params)
            .map_err(|error| format!("deep filter model init: {error:#}"))?;
        if model.sr != SAMPLE_RATE_HZ {
            return Err(format!("deep filter model sample rate {} != {SAMPLE_RATE_HZ}", model.sr));
        }
        if model.ch != NUM_CHANNELS {
            return Err(format!("deep filter model channels {} != {NUM_CHANNELS}", model.ch));
        }
        if model.hop_size != FRAME_SAMPLES {
            return Err(format!("deep filter model hop {} != {FRAME_SAMPLES}", model.hop_size));
        }
        Ok(Processor {
            model,
            input: Array2::zeros((1, FRAME_SAMPLES)),
            output: Array2::zeros((1, FRAME_SAMPLES)),
        })
    }

    fn process_frame(&mut self, samples: &mut [i16; FRAME_SAMPLES]) -> Result<(), String> {
        for (target, sample) in self.input.iter_mut().zip(samples.iter()) {
            *target = f32::from(*sample) * SAMPLE_SCALE_I16_TO_F32;
        }
        self.model
            .process(self.input.view(), self.output.view_mut())
            .map_err(|error| format!("deep filter process: {error:#}"))?;
        for (sample, enhanced) in samples.iter_mut().zip(self.output.iter()) {
            *sample = sample_f32_to_i16(*enhanced);
        }
        Ok(())
    }
}

fn sample_f32_to_i16(sample: f32) -> i16 {
    if !sample.is_finite() {
        return 0;
    }
    let clamped = sample.clamp(-1.0, 1.0);
    (clamped * SAMPLE_SCALE_F32_TO_I16) as i16
}

/// Creates a processor instance and returns an opaque handle (the boxed
/// pointer, as a jlong). Returns 0 on failure - the Kotlin side must treat 0
/// as "unavailable" and skip processing rather than crash a live call over
/// an optional enhancement feature.
#[no_mangle]
pub extern "system" fn Java_io_livekit_plugin_DeepFilterNoiseProcessor_nativeInit(
    _env: JNIEnv,
    _class: JClass,
) -> jlong {
    panic::catch_unwind(|| match Processor::new(DEFAULT_LEVEL_DB) {
        Ok(processor) => Box::into_raw(Box::new(processor)) as jlong,
        Err(_) => 0,
    })
    .unwrap_or(0)
}

/// Processes exactly [FRAME_SAMPLES] samples in place. A panic inside the
/// model, a wrong-sized array, or a null/zero handle all leave the buffer
/// untouched (best-effort enhancement, never worth crashing a live call
/// over) rather than letting a panic unwind across the JNI boundary, which
/// is undefined behavior.
#[no_mangle]
pub extern "system" fn Java_io_livekit_plugin_DeepFilterNoiseProcessor_nativeProcess(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    samples: JShortArray,
) {
    if handle == 0 {
        return;
    }
    let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        let processor = unsafe { &mut *(handle as *mut Processor) };
        let mut buffer = [0i16; FRAME_SAMPLES];
        if env.get_short_array_region(&samples, 0, &mut buffer).is_err() {
            return;
        }
        if processor.process_frame(&mut buffer).is_err() {
            return;
        }
        let _ = env.set_short_array_region(&samples, 0, &buffer);
    }));
}

/// Frees a processor created by [nativeInit]. A no-op for handle == 0.
#[no_mangle]
pub extern "system" fn Java_io_livekit_plugin_DeepFilterNoiseProcessor_nativeDestroy(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle == 0 {
        return;
    }
    let _ = panic::catch_unwind(|| unsafe {
        drop(Box::from_raw(handle as *mut Processor));
    });
}

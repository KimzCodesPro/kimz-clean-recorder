//! Minimal C API around DeepFilterNet3 (mono, 48 kHz).
//!
//! Lifecycle: dfn_create -> dfn_process (one hop at a time) -> dfn_free.

use std::os::raw::c_float;

use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::{ArrayView2, ArrayViewMut2};

pub struct Dfn {
    model: DfTract,
}

/// Creates the denoiser with the embedded DeepFilterNet3 model.
/// Returns NULL if the model fails to load.
#[no_mangle]
pub extern "C" fn dfn_create() -> *mut Dfn {
    let rp = RuntimeParams::default_with_ch(1); // atten limit 100 dB = full suppression
    match DfTract::new(DfParams::default(), &rp) {
        Ok(model) => Box::into_raw(Box::new(Dfn { model })),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Samples per call to dfn_process (480 = 10 ms at 48 kHz).
#[no_mangle]
pub unsafe extern "C" fn dfn_frame_length(st: *const Dfn) -> usize {
    st.as_ref().map_or(0, |s| s.model.hop_size)
}

/// Algorithmic delay in samples (STFT + model lookahead).
/// Drop this many output samples at the start to keep audio in sync.
#[no_mangle]
pub unsafe extern "C" fn dfn_latency_samples(st: *const Dfn) -> usize {
    st.as_ref().map_or(0, |s| {
        let m = &s.model;
        (m.fft_size - m.hop_size) + m.lookahead * m.hop_size
    })
}

/// Max noise attenuation in dB. 100 = unlimited, 0 = pass-through (same latency).
#[no_mangle]
pub unsafe extern "C" fn dfn_set_attenuation(st: *mut Dfn, db: c_float) {
    if let Some(s) = st.as_mut() {
        s.model.set_atten_lim(db);
    }
}

/// Processes exactly dfn_frame_length() samples. Input range [-1, 1].
/// Returns the local SNR estimate in dB (or -100 on error; output is zeroed).
#[no_mangle]
pub unsafe extern "C" fn dfn_process(st: *mut Dfn, input: *const c_float, output: *mut c_float) -> c_float {
    let Some(s) = st.as_mut() else { return -100.0 };
    let n = s.model.hop_size;
    let inp = ArrayView2::from_shape_ptr((1, n), input);
    let mut out = ArrayViewMut2::from_shape_ptr((1, n), output);
    match s.model.process(inp, out.view_mut()) {
        Ok(snr) => snr,
        Err(_) => {
            out.fill(0.0);
            -100.0
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dfn_free(st: *mut Dfn) {
    if !st.is_null() {
        drop(Box::from_raw(st));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn denoises_white_noise() {
        unsafe {
            let st = dfn_create();
            assert!(!st.is_null());
            let n = dfn_frame_length(st);
            assert_eq!(n, 480);
            println!("latency = {} samples", dfn_latency_samples(st));

            // 2 s of pure noise: output energy should drop a lot.
            let mut seed = 1u32;
            let (mut e_in, mut e_out) = (0f64, 0f64);
            let mut out = vec![0f32; n];
            for frame in 0..200 {
                let inp: Vec<f32> = (0..n)
                    .map(|_| {
                        seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                        ((seed >> 8) as f32 / (1u32 << 24) as f32 - 0.5) * 0.2
                    })
                    .collect();
                dfn_process(st, inp.as_ptr(), out.as_mut_ptr());
                if frame >= 50 {
                    e_in += inp.iter().map(|x| (*x as f64).powi(2)).sum::<f64>();
                    e_out += out.iter().map(|x| (*x as f64).powi(2)).sum::<f64>();
                }
            }
            let db = 10.0 * (e_out / e_in).log10();
            println!("noise reduction = {:.1} dB", db);
            assert!(db < -10.0);
            dfn_free(st);
        }
    }
}

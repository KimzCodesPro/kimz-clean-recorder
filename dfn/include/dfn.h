#ifndef DFN_H
#define DFN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Dfn Dfn;

/// Creates the DeepFilterNet3 denoiser (model embedded). NULL on failure.
/// atten_db: max noise attenuation in dB (e.g. 40). 100 = unlimited.
Dfn *dfn_create(float atten_db);

/// Samples per dfn_process call (480 = 10 ms at 48 kHz).
size_t dfn_frame_length(const Dfn *st);

/// Algorithmic delay in samples. Drop this many output samples at the start.
size_t dfn_latency_samples(const Dfn *st);

/// Max attenuation in dB. 100 = full noise removal, 0 = pass-through.
void dfn_set_attenuation(Dfn *st, float db);

/// Processes exactly dfn_frame_length() mono 48 kHz samples. Returns local SNR (dB).
float dfn_process(Dfn *st, const float *input, float *output);

void dfn_free(Dfn *st);

#ifdef __cplusplus
}
#endif

#endif

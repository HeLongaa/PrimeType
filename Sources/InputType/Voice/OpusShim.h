#ifndef PrimeType_OpusShim_h
#define PrimeType_OpusShim_h

#include <opus/opus.h>

static inline int primetype_opus_encoder_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

static inline int primetype_opus_encoder_set_complexity(OpusEncoder *enc, opus_int32 complexity) {
    return opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
}

#endif /* PrimeType_OpusShim_h */

/* Build settings for the vendored SpeexDSP (see ../README.md): the float build with its own small FFT (smallft.c). */
#ifndef CSPEEXDSP_CONFIG_H
#define CSPEEXDSP_CONFIG_H

#define FLOATING_POINT
#define USE_SMALLFT
#define EXPORT

/* SpeexDSP's internal helpers have generic names (an FFT, a filter bank): prefixed here so they can't clash with
   another library's linked into the same binary. Only the speex_* API is meant to be called. */
#define filterbank_compute_bank cspeexdsp_filterbank_compute_bank
#define filterbank_compute_bank32 cspeexdsp_filterbank_compute_bank32
#define filterbank_compute_psd cspeexdsp_filterbank_compute_psd
#define filterbank_compute_psd16 cspeexdsp_filterbank_compute_psd16
#define filterbank_destroy cspeexdsp_filterbank_destroy
#define filterbank_new cspeexdsp_filterbank_new
#define filterbank_psy_smooth cspeexdsp_filterbank_psy_smooth
#define spx_drft_backward cspeexdsp_spx_drft_backward
#define spx_drft_clear cspeexdsp_spx_drft_clear
#define spx_drft_forward cspeexdsp_spx_drft_forward
#define spx_drft_init cspeexdsp_spx_drft_init
#define spx_fft cspeexdsp_spx_fft
#define spx_fft_destroy cspeexdsp_spx_fft_destroy
#define spx_fft_float cspeexdsp_spx_fft_float
#define spx_fft_init cspeexdsp_spx_fft_init
#define spx_ifft cspeexdsp_spx_ifft
#define spx_ifft_float cspeexdsp_spx_ifft_float

#endif

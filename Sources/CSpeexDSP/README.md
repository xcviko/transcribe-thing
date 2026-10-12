# CSpeexDSP

The echo canceller and preprocessor of [SpeexDSP](https://github.com/xiph/speexdsp), vendored. The app uses them to take
the other side's voices, played through the speakers, out of a call's mic track (`Audio/EchoCanceller.swift`).

- Version: SpeexDSP 1.2.1 plus later upstream fixes, commit `7a158783df74efe7c2d1c6ee8363c1e695c71226`
  (2025-07-05, "testresample2: define M_PI if needed").
- License: BSD, see `COPYING` (copied unchanged from upstream).
- Files copied unchanged: `libspeexdsp/{mdf,preprocess,fftwrap,filterbank,smallft}.c` and the private headers they
  include (`arch.h`, `fftwrap.h`, `filterbank.h`, `math_approx.h`, `os_support.h`, `pseudofloat.h`, `smallft.h`) into
  `src/`; `include/speex/{speex_echo,speex_preprocess,speexdsp_types}.h` into `include/speex/`.
- Ours: `src/config.h` (the float build with smallft, and a `cspeexdsp_` prefix on the internal FFT and filter bank
  functions so they can't clash with another library's), `include/module.modulemap`, this file.
- Warnings in this target are off (`-w` in Package.swift): upstream code, kept as it is.

To update: `git clone --depth 1 https://github.com/xiph/speexdsp` somewhere outside the repo, copy the same files over,
check that `nm -g` on the objects shows no new unprefixed internal symbols, and change the commit above.

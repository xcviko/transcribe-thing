#!/usr/bin/env python3
"""convert-gigaam.py: turn Sber's GigaAM CTC speech models into the Core ML bundles transcribe-thing runs.

Usage:
    python scripts/convert-gigaam.py v3 <v3_ctc.ckpt> <out_dir>
    python scripts/convert-gigaam.py hf <Hugging Face model dir> <out_dir>
    (add --float32 to either to keep the encoder in float32: only to tell float16 rounding from a conversion bug)
    python scripts/convert-gigaam.py check <out_dir/model> <source> <wav> [<wav>...]   (Core ML vs PyTorch)
    python scripts/convert-gigaam.py int8 <out_dir/model>   (a copy with the encoder's weights in int8: <model>-int8)
    python scripts/convert-gigaam.py package <out_dir/model> <zip>   (what the app installs: compiled, zipped)

Needs a venv with torch 2.7, torchaudio 2.7, coremltools 9, omegaconf, hydra-core, sentencepiece and the gigaam
package (`pip install --no-deps git+https://github.com/salute-developers/GigaAM`). Inputs:
- v3: GigaAM v3 CTC, the gigaam package's `v3_ctc.ckpt` (`gigaam.load_model("v3_ctc")` puts it in ~/.cache/gigaam).
- hf: a GigaAM CTC model as Hugging Face keeps it (config.json, pytorch_model.bin, tokenizer.model if it has one):
  GigaAM Multilingual 600M, `ai-sage/GigaAM-Multilingual` at revision `large_ctc` (pytorch_model.bin sha256
  c3fabefb50b41f08f4d7ad44e02c26c37d242882704cdcca2ebd98e45eff73d1), or GigaAM v3 e2e, `ai-sage/GigaAM-v3` at revision
  `e2e_ctc`, which writes punctuation and capitals (a SentencePiece vocabulary of 256 pieces).

Writes `<out_dir>/<name>/` with:
- Frontend.mlpackage  16 kHz mono audio [1, N] -> log-mel [1, 64, F], float32 (a power spectrum overflows float16).
- Encoder.mlpackage   log-mel [1, 64, F] + valid frames [1] -> CTC log-probs [1, T, V] + valid steps [1], float16.
- vocabulary.json     the CTC alphabet (characters, or SentencePiece pieces with "▁" for a space), blank last, plus
                      the window sizes and frame strides the app needs.

Both models take one of `WINDOW_SECONDS` lengths (enumerated shapes): the app pads a stretch of speech to the next
one and passes its real length, so the padding changes nothing. GigaAM runs attention with no mask on a single
recording, so the encoder here always masks it: padded frames are invisible to the real ones.
"""

import json
import math
import sys
from pathlib import Path

import numpy as np
import torch
from torch import nn

SAMPLE_RATE = 16000
# Stretches of speech the app pads to. GigaAM's own long-form limit is 25 s.
WINDOW_SECONDS = [5, 10, 15, 20, 25]


def load_model(kind: str, source: Path):
    import omegaconf
    from gigaam.model import GigaAMASR

    if kind == "v3":
        checkpoint = torch.load(source, map_location="cpu", weights_only=False)
        cfg, state = checkpoint["cfg"], checkpoint["state_dict"]
    else:
        raw = json.loads((source / "config.json").read_text())["cfg"]["model"]["cfg"]
        # The Hugging Face copy is the gigaam package in one file: point its targets back at the package.
        text = json.dumps(raw)
        for old, new in [
            ("modeling_gigaam.FeatureExtractor", "gigaam.preprocess.FeatureExtractor"),
            ("modeling_gigaam.ConformerEncoder", "gigaam.encoder.ConformerEncoder"),
            ("modeling_gigaam.CTCHead", "gigaam.decoder.CTCHead"),
            ("modeling_gigaam.CTCGreedyDecoding", "gigaam.decoding.CTCGreedyDecoding"),
        ]:
            text = text.replace(old, new)
        cfg = omegaconf.OmegaConf.create(json.loads(text))
        if cfg.decoding.get("model_path"):
            cfg.decoding.model_path = str(source / cfg.decoding.model_path)
        weights = torch.load(source / "pytorch_model.bin", map_location="cpu", weights_only=True)
        state = {k.removeprefix("model."): v for k, v in weights.items()}
    model = GigaAMASR(cfg)
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        raise SystemExit(f"weights don't fit: missing {missing[:5]}, unexpected {unexpected[:5]}")
    model.eval()
    for layer in model.encoder.layers:
        layer.self_attn.flash_attn = False
        layer.self_attn.torch_sdpa_attn = False
    model.encoder.pos_enc.extend_pe(model.encoder.pos_emb_max_len, torch.device("cpu"))
    return model


class Frontend(nn.Module):
    """torchaudio's MelSpectrogram (center=False, periodic Hann, power 2, HTK mel, no norm) + log, as a strided
    convolution with the windowed DFT as its kernel, which Core ML runs as it is."""

    def __init__(self, extractor):
        super().__init__()
        mel = extractor.featurizer[0]
        spec = mel.spectrogram
        n_fft, self.hop = spec.n_fft, spec.hop_length
        assert spec.win_length == n_fft and not spec.center and spec.power == 2.0 and not spec.normalized
        window = spec.window.double()
        n = torch.arange(n_fft, dtype=torch.float64)
        k = torch.arange(n_fft // 2 + 1, dtype=torch.float64)
        angle = 2 * math.pi * k[:, None] * n[None, :] / n_fft
        kernel = torch.cat([torch.cos(angle) * window, -torch.sin(angle) * window])
        self.register_buffer("kernel", kernel.float()[:, None, :])
        self.register_buffer("fb", mel.mel_scale.fb.T.contiguous().float())  # [mels, freqs]
        self.bins = n_fft // 2 + 1

    def forward(self, audio):
        x = nn.functional.conv1d(audio[:, None, :], self.kernel, stride=self.hop)
        re, im = x[:, : self.bins], x[:, self.bins :]
        power = re * re + im * im
        mel = torch.matmul(self.fb, power)
        return torch.log(mel.clamp(1e-9, 1e9))


class Encoder(nn.Module):
    """GigaAM's encoder and CTC head for one recording, with attention masked to `length` valid mel frames.

    The layers are GigaAM's own modules; only the rotary attention is restated (`attention`), batch-first and with
    its sizes as constants: the original computes them from tensor shapes, which Core ML can't convert."""

    def __init__(self, model):
        super().__init__()
        self.encoder = model.encoder
        self.head = model.head
        pe = model.encoder.pos_enc.pe  # [2 * max_len, 1, 1, d_k]: cos rows, then sin rows
        half = pe.shape[0] // 2
        self.register_buffer("cos", pe[:half, 0, 0].clone())
        self.register_buffer("sin", pe[half:, 0, 0].clone())

    def attention(self, attn, x, cos, sin, mask):
        h, d_k = attn.h, attn.d_k
        heads = x.view(1, -1, h, d_k)
        rotated = heads * cos + torch.cat([-heads[..., d_k // 2:], heads[..., : d_k // 2]], dim=-1) * sin
        rotated = rotated.view(1, -1, h * d_k)
        # As GigaAM does: the rotation applies to the layer's input, before the query and key projections.
        q = attn.linear_q(rotated).view(1, -1, h, d_k).transpose(1, 2)
        k = attn.linear_k(rotated).view(1, -1, h, d_k).transpose(1, 2)
        v = attn.linear_v(x).view(1, -1, h, d_k).transpose(1, 2)
        scores = torch.matmul(q, k.transpose(-2, -1) / math.sqrt(d_k))
        scores = scores.masked_fill(mask, -10000.0)
        weights = torch.softmax(scores, dim=-1).masked_fill(mask, 0.0)
        out = torch.matmul(weights, v).transpose(1, 2).reshape(1, -1, h * d_k)
        return attn.linear_out(out)

    def forward(self, mel, length):
        enc = self.encoder
        x, steps = enc.pre_encode(x=mel.transpose(1, 2), lengths=length)
        t = x.size(1)
        cos = self.cos[:t][None, :, None, :]
        sin = self.sin[:t][None, :, None, :]
        valid = torch.arange(0, t, device=x.device)[None, :] < steps[:, None]
        att_mask = (~(valid[:, :, None] & valid[:, None, :]))[:, None]
        pad_mask = ~valid
        for layer in enc.layers:
            residual = x + layer.feed_forward1(layer.norm_feed_forward1(x)) * layer.fc_factor
            residual = residual + self.attention(layer.self_attn, layer.norm_self_att(residual), cos, sin, att_mask)
            residual = residual + layer.conv(layer.norm_conv(residual), pad_mask=pad_mask)
            residual = residual + layer.feed_forward2(layer.norm_feed_forward2(residual)) * layer.fc_factor
            x = layer.norm_out(residual)
        return self.head(encoder_output=x.transpose(1, 2)), steps.to(torch.int32)


def mel_frames(samples: int, hop: int = 160, win: int = 320) -> int:
    return (samples - win) // hop + 1


def convert(kind: str, source: Path, out_dir: Path, float32: bool = False):
    import coremltools as ct

    model = load_model(kind, source)
    names = {"v3_ctc": "gigaam-v3-ctc", "multilingual_large_ctc": "gigaam-multilingual-600m-ctc",
             "v3_e2e_ctc": "gigaam-v3-e2e-ctc"}
    name = names.get(model.cfg.model_name, "gigaam-" + model.cfg.model_name.replace("_", "-"))
    name += "-fp32" if float32 else ""
    target = out_dir / name
    target.mkdir(parents=True, exist_ok=True)

    windows = [s * SAMPLE_RATE for s in WINDOW_SECONDS]
    frames = [mel_frames(n) for n in windows]

    frontend = Frontend(model.preprocessor).eval()
    audio = torch.randn(1, windows[-1]) * 0.1
    with torch.no_grad():
        reference = model.preprocessor.featurizer(audio)
        ours = frontend(audio)
    print(f"frontend vs torchaudio: max |diff| {float((reference - ours).abs().max()):.2e}")
    traced = torch.jit.trace(frontend, audio)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=ct.EnumeratedShapes(shapes=[[1, n] for n in windows],
                                                                       default=[1, windows[-1]]))],
        outputs=[ct.TensorType(name="mel")],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    ml.short_description = f"{name}: log-mel features of 16 kHz mono audio"
    ml.save(str(target / "Frontend.mlpackage"))

    encoder = Encoder(model).eval()
    mel = model.preprocessor.featurizer(torch.randn(1, windows[-1]) * 0.1)
    length = torch.tensor([frames[-1]], dtype=torch.int32)
    with torch.no_grad():
        # The restated encoder against GigaAM's own, on the whole window, then on 7 s padded to the window.
        ref, _ = model.encoder(mel, length.long())
        ref = model.head(ref)
        ours, _ = encoder(mel, length)
        print(f"encoder vs gigaam, full window: max |diff| {float((ref - ours).abs().max()):.2e}")
        short = mel_frames(7 * SAMPLE_RATE)
        ref, ref_steps = model.encoder(mel[:, :, :short], torch.tensor([short]))
        ref = model.head(ref)
        padded = mel.clone()
        padded[:, :, short:] = math.log(1e-9)
        ours, steps = encoder(padded, torch.tensor([short], dtype=torch.int32))
        assert int(steps[0]) == int(ref_steps[0]) == ref.shape[1]
        diff = float((ref - ours[:, : ref.shape[1]]).abs().max())
        print(f"encoder vs gigaam, 7 s padded to {WINDOW_SECONDS[-1]} s: max |diff| {diff:.2e}")
        traced = torch.jit.trace(encoder, (mel, length))
    ml = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mel", shape=ct.EnumeratedShapes(shapes=[[1, 64, f] for f in frames],
                                                                 default=[1, 64, frames[-1]])),
            ct.TensorType(name="length", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="log_probs"), ct.TensorType(name="steps", dtype=np.int32)],
        compute_precision=ct.precision.FLOAT32 if float32 else ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    ml.short_description = f"{name}: Conformer encoder and CTC head (Sber GigaAM, MIT license)"
    ml.save(str(target / "Encoder.mlpackage"))

    tokenizer = model.decoding.tokenizer
    pieces = not tokenizer.charwise
    vocabulary = ([tokenizer.model.IdToPiece(i) for i in range(len(tokenizer))] if pieces
                  else list(model.cfg.decoding.vocabulary))
    (target / "vocabulary.json").write_text(json.dumps({
        "model": name,
        "vocabulary": vocabulary,
        "pieces": pieces,
        "blank": len(vocabulary),
        "sample_rate": SAMPLE_RATE,
        "window_samples": windows,
        "hop": 160,
        "win": 320,
        "subsampling": 4,
    }, ensure_ascii=False, indent=1))
    print(f"wrote {target}")


def ctc_greedy(ids, vocabulary, blank, pieces=False):
    out, prev = [], None
    for i in ids:
        if i != prev and i != blank and not (pieces and vocabulary[i] == "<unk>"):
            out.append(vocabulary[i])
        prev = i
    text = "".join(out)
    return " ".join((text.replace("▁", " ") if pieces else text).split())


def check(bundle: Path, source: Path, wavs):
    """Transcribes each file with the PyTorch model and with the Core ML bundle, as the app does (padded to the
    next window), and prints both texts and whether they match."""
    import coremltools as ct
    import soundfile as sf

    meta = json.loads((bundle / "vocabulary.json").read_text())
    model = load_model("hf" if source.is_dir() else "v3", source)
    frontend = ct.models.MLModel(str(bundle / "Frontend.mlpackage"))
    encoder = ct.models.MLModel(str(bundle / "Encoder.mlpackage"))
    vocabulary, blank = meta["vocabulary"], meta["blank"]
    for wav in wavs:
        audio, rate = sf.read(wav, dtype="float32")
        assert rate == SAMPLE_RATE and audio.ndim == 1
        n = len(audio)
        window = next(w for w in meta["window_samples"] if w >= n)
        padded = np.zeros((1, window), dtype=np.float32)
        padded[0, :n] = audio
        mel = frontend.predict({"audio": padded})["mel"]
        out = encoder.predict({"mel": mel, "length": np.array([mel_frames(n)], dtype=np.int32)})
        steps = int(out["steps"][0])
        ours = ctc_greedy(out["log_probs"][0, :steps].argmax(-1).tolist(), vocabulary, blank, meta.get("pieces", False))
        with torch.no_grad():
            enc, enc_len = model.forward(torch.from_numpy(audio)[None], torch.tensor([n]))
            theirs = " ".join(model.decoding.decode(model.head, enc, enc_len)[0][0].split())
        print(("SAME " if ours == theirs else "DIFF ") + Path(wav).name)
        if ours != theirs:
            print("  coreml :", ours)
            print("  pytorch:", theirs)


def int8(bundle: Path):
    """Linear (symmetric, per channel) int8 weights for the encoder: half the size of float16, which the Neural
    Engine may take where the float16 model is too big for it. The frontend stays as it is."""
    import shutil

    import coremltools as ct
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

    target = bundle.with_name(bundle.name + "-int8")
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle / "Frontend.mlpackage", target / "Frontend.mlpackage", dirs_exist_ok=True)
    meta = json.loads((bundle / "vocabulary.json").read_text())
    meta["model"] += "-int8"
    (target / "vocabulary.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    model = ct.models.MLModel(str(bundle / "Encoder.mlpackage"), skip_model_load=True)
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8",
                                                                      granularity="per_channel"))
    linear_quantize_weights(model, config=config).save(str(target / "Encoder.mlpackage"))
    print(f"wrote {target}")


def package(bundle: Path, archive: Path):
    """The app's install file: `<folder>/Frontend.mlmodelc`, `Encoder.mlmodelc` and `vocabulary.json` in a zip, the
    folder named as the app keeps the model (the bundle's name without "-int8": the app has one copy of a model)."""
    import shutil
    import subprocess
    import tempfile

    folder = bundle.name.removesuffix("-int8")
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / folder
        target.mkdir()
        for part in ("Frontend", "Encoder"):
            subprocess.run(["xcrun", "coremlcompiler", "compile", str(bundle / f"{part}.mlpackage"), str(target)],
                           check=True, stdout=subprocess.DEVNULL)
        shutil.copy(bundle / "vocabulary.json", target / "vocabulary.json")
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.unlink(missing_ok=True)
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", str(target), str(archive)],
                       check=True)
    print(f"wrote {archive} ({archive.stat().st_size / 1e6:.0f} MB)")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "package":
        package(Path(sys.argv[2]), Path(sys.argv[3]).expanduser())
        raise SystemExit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "int8":
        int8(Path(sys.argv[2]))
        raise SystemExit(0)
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    if sys.argv[1] == "check":
        check(Path(sys.argv[2]), Path(sys.argv[3]).expanduser(), sys.argv[4:])
    else:
        convert(sys.argv[1], Path(sys.argv[2]).expanduser(), Path(sys.argv[3]).expanduser(), "--float32" in sys.argv)

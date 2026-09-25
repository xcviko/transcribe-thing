# Murmur

Dictation for macOS that stays out of your way. Hold **fn**, speak, let go: the text lands at your cursor in
whatever app you're using. Transcription only, no rewriting.

- **Engines:** Parakeet TDT 0.6B v3 (local, default) and Whisper Large V3 Turbo (local) run entirely on
  your Mac; Gemini 3.8 Flash and Gemini 3.1 Pro run through your own OpenRouter key.
- **Hands-free mode**, a floating pill with a live waveform, a menu bar extra, rebindable shortcuts, soft
  sound cues, history with retry, and Undo for anything you cancel.

## Requirements

- macOS 26 on Apple silicon
- Xcode 26 or newer (Swift 6.2+ toolchain; the command line tools alone are enough)
- Python 3, only to regenerate the sounds

## Build and run

```sh
make app          # release build → build/Murmur.app, signed
make run          # build, then launch through LaunchServices
make run-log      # same, with Murmur's output in this terminal
make install      # copy to /Applications/Murmur.app
make test         # unit tests
make snapshots    # render every screen to build/snapshots (ONLY=hub- APPEARANCE=dark to narrow)
```

`make app CONFIG=debug` builds a debug bundle. `make sounds` and `make icon` regenerate `Resources/Sounds/*.wav`
and the app icon from `scripts/`.

Engine checks without the UI:

```sh
.build/debug/Murmur --model-status
.build/debug/Murmur --transcribe memo.m4a --engine parakeet --download
OPENROUTER_API_KEY=sk-or-… .build/debug/Murmur --transcribe memo.m4a --engine geminiFlash
```

## Permissions

Murmur asks for **Microphone** (to hear you) and **Accessibility** (to paste and to listen for its shortcuts).
Onboarding walks through both.

Ad-hoc signed builds (the default) are tied to the exact binary: after every rebuild, System Settings still
shows Murmur as allowed under Accessibility, but macOS quietly stops honoring it. Two ways out:

- **Sign with a stable certificate (recommended).** Grants then survive rebuilds.
  1. Open Keychain Access → Certificate Assistant → Create a Certificate…
  2. Name it `Murmur Developer`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing**, Create.
  3. Build with it: `make install SIGN_IDENTITY="Murmur Developer"` (or `export SIGN_IDENTITY=…` once).
  4. Grant Accessibility one last time.
- **Reset and grant again:** `make reset-tcc`, then relaunch and allow access.

If fn opens the emoji picker or switches input sources, set System Settings → Keyboard → "Press 🌐 key to"
→ **Do Nothing**. Murmur's onboarding flags this too.

## Where things live

| What | Where |
|---|---|
| Parakeet model | `~/Library/Application Support/Murmur/Models/parakeet-tdt-0.6b-v3` |
| Whisper model | `~/Library/Application Support/Murmur/WhisperKit` |
| History | `~/Library/Application Support/Murmur/history.json` (last 2,000 dictations) |
| Audio of failed or canceled dictations | `~/Library/Application Support/Murmur/Recordings` (kept 14 days by default, for Retry and Undo) |
| Settings | `defaults read dev.murmur.app` |
| OpenRouter key | login Keychain, service `dev.murmur.app` |

Successful dictations keep only their text; the audio is discarded.

## Shortcuts

| Action | Default | Notes |
|---|---|---|
| Push to talk | hold **fn** | Let go to paste. A quick tap does nothing. |
| Hands-free | **fn Space** | Also: press Space while holding fn, double-press fn, or click the pill. |
| Finish hands-free | **fn**, **fn Space** or the Stop button | Reaching the length limit (20 min by default) finishes too. |
| Cancel | **esc** | Works while recording or transcribing; Undo brings it back. |
| Paste last transcript | **⌘ fn V** | |
| Copy last transcript | **⌘ left⌃ C** | |

Everything is rebindable under Murmur → Shortcuts. With secure typing on (password fields, some terminals),
only hold-to-talk and double-press work until it's off.

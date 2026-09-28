# transcribe-thing

Dictation for macOS that stays out of your way. Hold **fn**, speak, let go: the text lands at your cursor in
whatever app you're using. Transcription only, no rewriting.

- **Engines:** Parakeet TDT 0.6B v3 (the default) runs entirely on your Mac and detects any of 25 European
  languages on its own. Through your own OpenRouter key: the same Parakeet v3 (served by Together), Gemini 3.8
  Flash, and clean-up of Parakeet's text by GPT-6 Luna.
- **Hands-free mode**, a floating pill with a live waveform, a menu bar extra, rebindable shortcuts, soft
  sound cues, history with retry, and Undo for anything you cancel.

## Requirements

- macOS 26 on Apple silicon
- Xcode 26 or newer (Swift 6.2+ toolchain; the command line tools alone are enough)
- Python 3, only to regenerate the sounds

## Build and run

```sh
make app          # release build → build/transcribe-thing.app, signed (see Permissions)
make run          # build, then launch through LaunchServices
make run-log      # same, with transcribe-thing's output in this terminal
make install      # copy to /Applications/transcribe-thing.app
make test         # unit tests
make snapshots    # render every screen to build/snapshots (ONLY=hub- APPEARANCE=dark to narrow)
```

`make app CONFIG=debug` builds a debug bundle. `make sounds` and `make icon` regenerate `Resources/Sounds/*.wav`
and the app icon from `scripts/`.

Engine checks without the UI:

```sh
.build/debug/transcribe-thing --model-status
.build/debug/transcribe-thing --transcribe memo.m4a --engine parakeet --download
OPENROUTER_API_KEY=sk-or-… .build/debug/transcribe-thing --transcribe memo.m4a --engine geminiFlash
OPENROUTER_API_KEY=sk-or-… .build/debug/transcribe-thing --transcribe memo.m4a --engine parakeet --clean-up
```

Gemini 3.8 Flash always thinks at medium and GPT-6 Luna not at all, as in the app; `--effort` (low, medium or high)
tries Gemini at another level. `--clean-up` sends the transcript to GPT-6 Luna with the example clean-up prompt
(`--clean-up-prompt` and `--clean-up-effort` change them).

## Permissions

transcribe-thing asks for **Microphone** (to hear you) and **Accessibility** (to paste and to listen for its shortcuts).
Onboarding walks through both.

Ad-hoc signed builds (what you get without the certificate below) are tied to the exact binary: after every
rebuild, System Settings still shows transcribe-thing as allowed under Accessibility, but macOS quietly stops
honoring it. Two ways out:

- **Sign with a stable certificate (recommended).** Grants then survive rebuilds.
  1. Open Keychain Access → Certificate Assistant → Create a Certificate…
  2. Name it `transcribe-thing Developer`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing**, Create.
  3. Rebuild (`make install`) and grant Accessibility one last time.

  The Makefile signs with `transcribe-thing Developer` automatically whenever that certificate is in your
  keychain, and ad-hoc otherwise; `SIGN_IDENTITY=…` overrides it. Keychain Access marks a self-signed
  certificate as not trusted, and that's fine for signing. The first build may ask to let codesign use the key:
  choose Always Allow.
- **Reset and grant again:** `make reset-tcc`, then relaunch and allow access.

If fn opens the emoji picker or switches input sources, set System Settings → Keyboard → "Press 🌐 key to"
→ **Do Nothing**. transcribe-thing's onboarding flags this too.

## Updates

transcribe-thing checks [its GitHub releases](https://github.com/xcviko/transcribe-thing/releases) about 20 seconds
after launch and every 6 hours (drafts and prereleases are skipped). When a newer version is out, the pill mentions
it once, right after a dictation lands, and General gets a red badge until you install it. **Update Now** in
General → Software Update downloads the release zip, checks it, swaps the app in place and relaunches (after the
dictation in progress, if any). Turning off "Check for updates automatically" means no reminders and no badges;
the Software Update page still checks when you open it.

An update installs only if it is the same app (`dev.transcribe-thing.app`), exactly the promised version, and its
code signature satisfies the installed app's designated requirement, which pins the `transcribe-thing Developer`
certificate (see Permissions). That is what makes updates trustworthy without Apple's notarization, and it is also
why macOS keeps the Accessibility and Microphone grants across updates. The flip side: an ad-hoc signed copy can't
update itself (download the new zip instead), and releases must always be signed with the same certificate. Keep
it backed up: a new certificate means everyone installs the next version by hand, once.

A zip downloaded in a browser is quarantined, so the first manual install needs right-click → Open, or:

```sh
xattr -dr com.apple.quarantine /Applications/transcribe-thing.app
```

Checks without the UI (`TT_UPDATE_FEED_URL` points the app itself at another feed, `file://` included):

```sh
.build/debug/transcribe-thing --check-updates --current 0.1.0
.build/debug/transcribe-thing --install-update --feed file:///tmp/feed.json --target /tmp/copy/transcribe-thing.app \
  --requirement-from /Applications/transcribe-thing.app
```

`--install-update` replaces only `--target` and never relaunches anything.

## Releasing

```sh
make release VERSION=0.2.0
```

`scripts/release.sh` refuses a dirty tree, an existing tag or an ad-hoc signature, sets the version in
`Resources/Info.plist` (a local "Release 0.2.0" commit), builds and signs the app, zips it to
`dist/transcribe-thing-0.2.0.zip`, drafts `dist/release-notes-0.2.0.md` from the commits since the last tag and
prints the zip's SHA-256. It never pushes or publishes. Edit the notes, then run the two commands it prints:

```sh
git push origin main
gh release create v0.2.0 dist/transcribe-thing-0.2.0.zip --title "transcribe-thing 0.2.0" \
  --notes-file dist/release-notes-0.2.0.md --target main
```

The zip's name (`transcribe-thing-<version>.zip`) and the tag (`v<version>`) are what the app looks for.

## Where things live

| What | Where |
|---|---|
| Parakeet model | `~/Library/Application Support/transcribe-thing/Models/parakeet-tdt-0.6b-v3` |
| History | `~/Library/Application Support/transcribe-thing/history.json` (last 2,000 dictations) |
| Recordings | `~/Library/Application Support/transcribe-thing/Recordings`: failed or canceled dictations for 14 days by default (Retry and Undo), successful ones for 1 day (Transcribe With) |
| Release feed cache | `~/Library/Application Support/transcribe-thing/updates.json` (what the last update check saw) |
| Settings | `defaults read dev.transcribe-thing.app` |
| OpenRouter key | login Keychain, service `dev.transcribe-thing.app` |

Successful dictations keep their audio for a day by default, so History can send one to another model (Versions →
Transcribe With, say Gemini after a long dictation went to Parakeet); set General → History → Keep audio to transcribe
again to Off to keep only the text. Every transcript a recording gets stays in its Versions menu with how it was made
(model, reasoning level, tokens, cost, time), each model at most once, and switching between them needs no audio.

## Shortcuts

| Action | Default | Notes |
|---|---|---|
| Push to talk | hold **fn** | Let go to paste. A quick tap does nothing. |
| Hands-free | **fn Space** | Also: press Space while holding fn, double-press fn, or click the pill. |
| Finish hands-free | **fn**, **fn Space** or the Stop button | Reaching the length limit (20 min by default) finishes too. |
| Cancel | **esc** | Works while recording or transcribing; Undo brings it back. |
| Paste last transcript | **⌘ fn V** | Also leaves it on the clipboard, even with "Restore the clipboard after pasting" on. |

Everything is rebindable under transcribe-thing → Shortcuts. With secure typing on (password fields, some terminals),
only hold-to-talk and double-press work until it's off.

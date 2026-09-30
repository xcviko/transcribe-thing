# transcribe-thing

Dictation for macOS: hold **fn**, speak, let go, and the text appears at your cursor in any app.

## Install

Takes about two minutes. Requires macOS 26 on Apple silicon.

1. Download the latest `transcribe-thing-<version>.zip` from [Releases](https://github.com/xcviko/transcribe-thing/releases)
   and unzip it.
2. Move `transcribe-thing.app` to Applications.
3. The app isn't notarized by Apple, so the first time, right-click it and choose Open. Or run this in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/transcribe-thing.app
   ```

4. Setup walks you through the rest: Microphone and Accessibility permissions, the speech model download (about
   600 MB), an optional OpenRouter key, and a practice round.

When a new version is out, the app tells you, and Update Now in General → Software Update installs it.

## Dictate

| To | Press |
|---|---|
| Dictate | hold **fn**, speak, let go |
| Dictate without holding a key | **fn Space** to start, **fn** to finish |
| Cancel | **esc** (Undo brings it back) |
| Switch model while you talk | **fn ⇥** |
| Paste the last transcript again | **⌘ fn V** |

Change any of them except esc in Shortcuts. A small pill at the bottom of the screen shows that you're recording;
General → Show the pill chooses always, only while you dictate, or never.

Pasting leaves your clipboard as it was. To copy a transcript, use Copy Last Transcript in the menu bar or Copy in
History.

## Models

- **Parakeet v3** (the default) runs on your Mac. It's the fastest, works offline, and recognizes 25 European
  languages by itself. It can also run through OpenRouter instead, for about $0.09 per hour of audio.
- **Parakeet v3 + GPT-6 Luna** cleans up Parakeet's text before it's pasted: filler words, false starts,
  punctuation.
- **Gemini 3.8 Flash** is the most accurate. It thinks before it writes, so it's slower.

The cloud models run on your own [OpenRouter](https://openrouter.ai) key, and you pay OpenRouter per use. In Models,
choose which model every dictation starts on, which ones fn ⇥ steps through, and each one's pill color.

## Your data

History, the recordings and your OpenRouter key stay on your Mac, in `~/Library/Application Support/transcribe-thing`.
The key is in a file only you can read. Audio leaves your Mac only when a cloud model transcribes it, and a transcript
only when GPT-6 Luna cleans it up.

History keeps every dictation with its recording until you delete it, so you can transcribe it again with another
model. General → History can delete entries older than 1, 7, 30 or 90 days.

## If something doesn't work

- **fn opens the emoji picker or switches the keyboard layout:** set System Settings → Keyboard → "Press 🌐 key to"
  → Do Nothing. Setup points this out too.
- **Shortcuts don't respond in a password field or some terminals:** macOS blocks them there (secure typing). Holding
  fn still works.
- **The transcript stays on the clipboard after a paste:** macOS is set to ask before transcribe-thing reads the
  clipboard, or never to let it. Allow it in System Settings → Privacy & Security → Paste from Other Apps.

## Build from source

You need Xcode 26 or newer. Python 3 is needed only to regenerate the sounds (`make sounds`).

```sh
make install      # build, sign and copy to /Applications
make run          # build and launch
make test         # unit tests
make snapshots    # render every screen to build/snapshots (ONLY=hub- APPEARANCE=dark to narrow)
```

Create a signing certificate once, or macOS quietly stops honoring the Accessibility permission after every rebuild:
Keychain Access → Certificate Assistant → Create a Certificate…, name it `transcribe-thing Developer`, Identity Type
**Self-Signed Root**, Certificate Type **Code Signing**. The Makefile uses it whenever it's in your keychain. Without
it, run `make reset-tcc` after a rebuild and grant access again.

The binary also works without the UI, for checking the models:

```sh
.build/debug/transcribe-thing --transcribe memo.m4a --engine parakeet --download
.build/debug/transcribe-thing --transcribe memo.m4a --engine geminiFlash
.build/debug/transcribe-thing --transcribe memo.m4a --engine parakeet --clean-up
```

Cloud runs use the app's saved key, or `OPENROUTER_API_KEY` when it's set. `Sources/TranscribeThing/App/EngineCLI.swift`
lists every flag.

### Releasing

`make release VERSION=x.y.z` builds, signs and zips the app into `dist/` and drafts the release notes there. It never
pushes or publishes: it prints the `git push` and `gh release create` commands to run yourself.

Always sign releases with the same `transcribe-thing Developer` certificate, and keep it backed up. Installed copies
accept only updates signed with it, so a new certificate means everyone installs the next version by hand.

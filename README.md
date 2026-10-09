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
| Dictate without holding a key | **fn Space** to start, **fn** or **return** to finish |
| Cancel | **esc** (Undo brings it back) |
| Switch model while you talk | **fn ⇥** |
| Get the message you meant, not every word (Gemini) | **fn P** while you talk |
| Polish text you've selected (on Parakeet) | select it, hold **fn**, press **P** |
| Teach the cloud models a word or a name | select it, hold **fn**, press **D** |
| Paste the last transcript again | **⌘ fn V** |

Change any of them except esc in Shortcuts. A small pill at the bottom of the screen shows that you're recording;
General → Show the pill chooses always, only while you dictate, or never.

Pasting leaves your clipboard as it was. To copy a transcript, use Copy Last Transcript in the menu bar or Copy in
History.

fn P and fn D read the selected text through Accessibility. In apps that don't share it that way (Chrome, and
Electron apps such as VS Code or Claude), they copy it with ⌘C and put your clipboard back right after. A clipboard
manager may still keep the selected text.

## Models

- **Parakeet v3** (the default) runs on your Mac. It's the fastest, works offline, and recognizes 25 European
  languages by itself. It can also run through OpenRouter instead, for about $0.09 per hour of audio.
- **Parakeet v3 + GPT-6 Luna** cleans up Parakeet's text before it's pasted: filler words, false starts,
  punctuation.
- **Gemini 3.8 Flash** is the most accurate. It thinks before it writes, so it's slower. It can also polish: press
  fn P while you talk, and it pastes the message you meant, without the false starts, detours and repeats.

On another model, fn P polishes the text you've selected instead: Gemini 3.8 Flash writes the polished version on a
card, and Paste Here puts it in place of the selection.

The cloud models run on your own [OpenRouter](https://openrouter.ai) key, and you pay OpenRouter per use. Each cloud
dictation sends its request twice at once and pastes the first answer, stopping the other, so it can cost up to twice
as much: a model that stops to think on one request doesn't hold you up. In Models, choose which model every
dictation starts on, which one hands-free dictations switch to, which ones fn ⇥ steps through, and each one's pill
color.

## Dictionary

Words, names and terms you use, and how they're spelled. Gemini 3.8 Flash and GPT-6 Luna get them as a hint, so a
dictation spells "Wispr Flow" the way you do; Parakeet takes no hints. Add one with fn D over selected text, or in the
app's Dictionary page, where you can also sort them into groups by dragging. Groups are only for you: the models get
every word.

## Transcribe a file

Have a recording already, say a voice note or a call? Drop the file on Home, or press ⌘O there, and pick the model.
The transcript shows up in History under the file's name instead of being pasted. From there it works like any
dictation: transcribe it again with another model, clean it up or polish it.

It takes MP3, M4A, WAV, Telegram voice notes (.ogg) and the sound of a video, up to three hours. Files don't count
toward your words, speed or time saved.

## Your data

History, the recordings, your dictionary and your OpenRouter key stay on your Mac, in
`~/Library/Application Support/transcribe-thing`. The key is in a file only you can read. Audio leaves your Mac only
when a cloud model transcribes it. Text leaves it only when a model works on it: GPT-6 Luna cleaning up a transcript,
or Gemini 3.8 Flash polishing text you selected. Your dictionary's words go along with every Gemini 3.8
Flash dictation and every clean-up.

The same folder keeps a log of what the app did in the last 7 days, without your dictations, your selected text or
your key. It stays there until you send it: General → Troubleshooting → Export Logs… saves it as a file.

History keeps every dictation with its recording, and a copy of the sound of every file you transcribe, until you
delete it, so you can transcribe it again with another model or polish it. General → History can delete entries older than 1, 7, 30 or 90 days.

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

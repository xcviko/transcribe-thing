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
   600 MB) and a practice round. The cloud models and their key are in Models, whenever you want them.

When a new version is out, the app tells you, and Update Now in General → Software Update installs it.

## Dictate

| To | Do |
|---|---|
| Dictate | hold **fn**, speak, let go |
| Dictate without holding a key | **fn Space** to start, **fn** to finish |
| Cancel | **esc** (Undo brings it back) |
| Switch model while you talk | **fn ⇥** |
| Get the message you meant, not every word (Gemini) | **fn P**, or click the **wand** on the pill |
| Polish text you've selected (on Parakeet) | select it, then **fn P** or the **wand** |
| Get what you say in the other language (Gemini) | **fn T**, or click **Translate** on the pill |
| Translate text you've selected (on Parakeet) | select it, then **fn T** or **Translate** |
| Press Return once the text is pasted (sends a chat message) | **fn ↩**, or click the **paper plane** on the pill |
| Teach the cloud models a word or a name | select it, hold **fn**, press **D** |
| Paste the last transcript again | **⌘ fn V** |

A small pill at the bottom of the screen shows that you're recording; General → Show the pill chooses always, only
while you dictate, or never. Point at the pill while you dictate, or while its text is on the way, and the wand,
Translate and the paper plane come out beside it. A click, or fn P, fn T and fn ↩, turns one on or off for that
dictation; while texts are on their way, the keys go to the newest. Change the keys (all but esc) in Shortcuts.

You don't have to wait for the text. Start the next dictation while the last one is still being written: the earlier
one moves up onto a pill of its own, and each text is pasted as soon as it's ready, in the order you dictated. Esc
cancels the dictation you're recording, or, when you're not recording, the newest one still on its way.

If music or a video plays on your Mac's speakers while you dictate, the app takes it out of what your microphone hears,
so you don't have to talk over it and the song's words mostly stay out of the transcript. This needs the System Audio
Recording permission, which the app never asks for on its own: click Allow next to it in General → Permissions. If
you said no before, turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, under System
Audio Recording Only. The first second after you start may still pick up the music. With headphones, or without the permission, your microphone is
recorded as it is.

Pasting leaves your clipboard as it was. To copy a transcript, use Copy Last Transcript in the menu bar or Copy in
History.

Polish, Translate and fn D read the selected text through Accessibility. In apps that don't share it that way (Chrome, and
Electron apps such as VS Code or Claude), they copy it with ⌘C and put your clipboard back right after. A clipboard
manager may still keep the selected text.

## Models

- **Parakeet v3** (the default) runs on your Mac. It's the fastest, works offline, needs no key, and recognizes 25
  European languages by itself.
- **Gemini 3.8 Flash** runs in the cloud and is very accurate. It thinks before it writes, so it's slower than
  Parakeet.

On Gemini, press fn P (or click the wand on the pill) and it pastes the message you meant, without the false starts,
detours and repeats. Press fn T (or click Translate) and it pastes what you said in the other language. Russian becomes English and English becomes
Russian; pick another pair in General → Translate. With both on, you get the message you meant, translated.

On Parakeet, fn P and fn T (the wand and Translate) work on the text you've selected instead: Gemini 3.8 Flash writes the result
on a card, and Paste Here puts it in place of the selection.

In Models:

- **Your models** picks the model every dictation starts on (the dot), which models fn ⇥ steps through while you talk
  (the switches, in the order of the list, which you can drag), and each one's pill color. Gemini's row also has a
  Reasoning menu, under its name: how long it thinks before it writes, Low, Medium (the default) or High. Higher is
  slower and costs more. It applies to everything Gemini does: dictations, Polish, Translate, selected text, files
  and History.
- **Hands-free** picks the model fn Space starts on.
- **Parakeet on this Mac** downloads it and shows how it's doing. Delete it there once it's neither the main
  model nor switched on.

Gemini runs on your own [OpenRouter](https://openrouter.ai) key, and you pay OpenRouter per use. Each dictation goes
to Gemini once. If Gemini sometimes thinks for a long time before it writes, try General → Experimental → Race
requests (off by default): at 2 or 3, each Gemini dictation is sent that many times at once, each copy through a
different Google service, the first answer is pasted and the rest are stopped. A dictation can then cost up to 2 or 3
times as much (the third copy 10% more). Selected text, files and History aren't affected.

If you ran Parakeet v3 through OpenRouter, that option is gone: Parakeet runs only on your Mac now. If it isn't
downloaded yet, download it in Models (about 600 MB). Transcripts it made stay in History as "Parakeet v3 · Cloud".

Gemini 4 Argon is gone too. Wherever you had picked it (your main model, fn ⇥, hands-free), Gemini 3.8 Flash
takes its place, so there's nothing to change. Transcripts it made stay in History as "Gemini 4 Argon".

Gemini can also go through another service you pay for, if it has an OpenAI-compatible API. Models → API keys →
Provider picks one of the two, OpenRouter or Custom endpoint, for every Gemini request: dictations, Polish, Translate,
selected text and files. Requests never go to the other one, even when the picked one fails or
isn't set up yet. Only the picked one's fields show; the other's key (and the endpoint's URL) stay saved, so switching
back is instant.

For Custom endpoint, enter its base URL (the one that ends in `/v1`, like `https://api.example.com/v1`) and its API
key. A URL without a path is read as `<address>/api/v1`, so an endpoint saved by its address alone keeps working. The
app checks the key without spending anything and says whether it works. Until both are saved, Gemini shows "Needs
endpoint". The endpoint gets the same request OpenRouter would, audio included, with OpenRouter's model name
(`google/gemini-3.8-flash`), so it has to accept that name. If it fails, the error says it
came from your endpoint. Costs in History are what your endpoint reports, and History names it by its address.

If you had an endpoint set up with "Use for Gemini" on, Custom endpoint is picked for you. Everyone else starts on
OpenRouter.

## Dictionary

Words, names and terms you use, and how they're spelled. Gemini gets them as a hint, so a dictation
spells "Wispr Flow" the way you do; Parakeet takes no hints. Add one with fn D over selected text, or in the
app's Dictionary page, where you can also sort them into groups by dragging. Groups are only for you: the models get
every word.

## Transcribe a file

Have a recording already, say a voice note or a call? Drop the file on Home, or press ⌘O there, and pick the model.
The transcript shows up in History under the file's name instead of being pasted. From there it works like any
dictation: transcribe it again with another model, polish it or translate it.

It takes MP3, M4A, WAV, Telegram voice notes (.ogg) and the sound of a video, up to three hours. Files don't count
toward the numbers on Home: words, speed and dictations are only what you said.

Recording and transcribing your calls as they happen is a separate app now, calls-thing.

## Your data

History, the recordings, your dictionary and your API keys (OpenRouter's and your own endpoint's) stay on your Mac, in
`~/Library/Application Support/transcribe-thing`. Each key is in a file only you can read. Audio leaves your Mac only
when Gemini transcribes it: through OpenRouter, or through your own endpoint when it's the provider. Text leaves it only
when Gemini 3.8 Flash polishes or translates text you selected. Your dictionary's words go along with everything sent to Gemini.

The same folder keeps a log of what the app did in the last 7 days, without your dictations, your selected text or
your key. It stays there until you send it: General → Troubleshooting → Export Logs… saves it as a file.

History keeps every dictation with its recording, and a copy of the sound of every file you transcribe, until you
delete it, so you can transcribe it again with another model, polish it or translate it. General → History can
delete entries older than 1, 7, 30 or 90 days.

If the app quits or crashes, or the Mac shuts down, while you dictate or wait for the transcript, the recording isn't
lost. The next time the app starts, it's in History marked "Couldn't transcribe", with Retry. Nothing goes to a model
until you click it.

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
.build/debug/transcribe-thing --transcribe memo.m4a --engine geminiFlash --effort high
```

Cloud runs use the app's saved key, or `OPENROUTER_API_KEY` when it's set. They think at Medium unless `--effort`
says otherwise; the level picked in the app's Models isn't read. Gemini runs go to the provider picked in the app,
and `--model-status` says which one it is. `Sources/TranscribeThing/App/EngineCLI.swift`
lists every flag.

### Releasing

`make release VERSION=x.y.z` builds, signs and zips the app into `dist/` and drafts the release notes there. It never
pushes or publishes: it prints the `git push` and `gh release create` commands to run yourself.

Always sign releases with the same `transcribe-thing Developer` certificate, and keep it backed up. Installed copies
accept only updates signed with it, so a new certificate means everyone installs the next version by hand.

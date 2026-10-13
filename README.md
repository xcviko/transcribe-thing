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

| To | Press |
|---|---|
| Dictate | hold **fn**, speak, let go |
| Dictate without holding a key | **fn Space** to start, **fn** to finish |
| Cancel | **esc** (Undo brings it back) |
| Switch model while you talk | **fn ⇥** |
| Get the message you meant, not every word (Gemini) | **fn P** while you talk |
| Polish text you've selected (on Parakeet) | select it, hold **fn**, press **P** |
| Get what you say in the other language (Gemini) | **fn T** while you talk |
| Translate text you've selected (on Parakeet) | select it, hold **fn**, press **T** |
| Teach the cloud models a word or a name | select it, hold **fn**, press **D** |
| Paste the last transcript again | **⌘ fn V** |

Change any of them except esc in Shortcuts. A small pill at the bottom of the screen shows that you're recording;
General → Show the pill chooses always, only while you dictate, or never.

Pasting leaves your clipboard as it was. To copy a transcript, use Copy Last Transcript in the menu bar or Copy in
History.

fn P, fn T and fn D read the selected text through Accessibility. In apps that don't share it that way (Chrome, and
Electron apps such as VS Code or Claude), they copy it with ⌘C and put your clipboard back right after. A clipboard
manager may still keep the selected text.

## Models

- **Parakeet v3** (the default) runs on your Mac. It's the fastest, works offline, needs no key, and recognizes 25
  European languages by itself.
- **Gemini 3.8 Flash** runs in the cloud and is very accurate. It thinks before it writes, so it's slower than
  Parakeet.
- **Gemini 4 Argon** runs in the cloud and is the most accurate. It's slower than Flash and costs about 2.7 times as
  much. It's switched off until you switch it on.

On either Gemini, press fn P while you talk and it pastes the message you meant, without the false starts, detours and
repeats. Press fn T and it pastes what you said in the other language. Russian becomes English and English becomes
Russian; pick another pair in General → Translate. With both on, you get the message you meant, translated.

On Parakeet, fn P polishes and fn T translates the text you've selected instead: Gemini 3.8 Flash writes the result on
a card, and Paste Here puts it in place of the selection.

In Models:

- **Your models** picks the model every dictation starts on (the dot), which models fn ⇥ steps through while you talk
  (the switches, in the order of the list, which you can drag), and each one's pill color. Each Gemini's row also has
  a Reasoning menu, under its name: how long that model thinks before it writes, Low, Medium (the default) or High.
  Higher is slower and costs more. It applies to everything that model does: dictations, Polish, Translate, selected
  text, files, History and calls.
- **Hands-free** picks the model fn Space starts on.
- **Calls** picks the model that transcribes and sums up calls: Gemini 3.8 Flash (the default) or Gemini 4 Argon.
- **Parakeet on this Mac** downloads it and shows how it's doing. Delete it there once it's neither the main
  model nor switched on.

The Gemini models run on your own [OpenRouter](https://openrouter.ai) key, and you pay OpenRouter per use. Each Gemini
dictation sends its request twice at once and pastes the first answer, stopping the other, so it can cost up to twice
as much: a model that stops to think on one request doesn't hold you up.

If you ran Parakeet v3 through OpenRouter, that option is gone: Parakeet runs only on your Mac now. If it isn't
downloaded yet, download it in Models (about 600 MB). Transcripts it made stay in History as "Parakeet v3 · Cloud".

Gemini can also go through another service you pay for, if it has an OpenAI-compatible API. Models → API keys →
Provider picks one of the two, OpenRouter or Custom endpoint, for every Gemini request: dictations, Polish, Translate,
selected text, files, calls and their summaries. Requests never go to the other one, even when the picked one fails or
isn't set up yet. Only the picked one's fields show; the other's key (and the endpoint's URL) stay saved, so switching
back is instant.

For Custom endpoint, enter its base URL (the one that ends in `/v1`, like `https://api.example.com/v1`) and its API
key. A URL without a path is read as `<address>/api/v1`, so an endpoint saved by its address alone keeps working. The
app checks the key without spending anything and says whether it works. Until both are saved, Gemini shows "Needs
endpoint". The endpoint gets the same request OpenRouter would, audio included, with OpenRouter's model name
(`google/gemini-3.8-flash` or `google/gemini-4-argon`), so it has to accept those names. If it fails, the error says it
came from your endpoint. Costs in History are what your endpoint reports, and History names it by its address.

If you had an endpoint set up with "Use for Gemini" on, Custom endpoint is picked for you. Everyone else starts on
OpenRouter.

## Dictionary

Words, names and terms you use, and how they're spelled. The Gemini models get them as a hint, so a dictation
or a call's transcript spells "Wispr Flow" the way you do; Parakeet takes no hints. Add one with fn D over selected text, or in the
app's Dictionary page, where you can also sort them into groups by dragging. Groups are only for you: the models get
every word.

## Transcribe a file

Have a recording already, say a voice note or a call? Drop the file on Home, or press ⌘O there, and pick the model.
The transcript shows up in History under the file's name instead of being pasted. From there it works like any
dictation: transcribe it again with another model, polish it or translate it.

It takes MP3, M4A, WAV, Telegram voice notes (.ogg) and the sound of a video, up to three hours. Files don't count
toward your words, speed or time saved.

## Calls

The app records your calls and transcribes them with who said what. They're in the Calls tab.

A call is any app that uses your microphone and plays sound at the same time for 20 seconds: Zoom, Telegram, FaceTime,
Teams, WhatsApp or anything else. Music and recording apps never count: GarageBand, Logic Pro, Ableton Live, OBS,
QuickTime Player, Voice Memos, Simulator, Audio Hijack, Loopback, Final Cut Pro, DaVinci Resolve and Audacity.

In a browser, a call is a tab. In Chrome, Arc, Edge, Brave, Vivaldi, Opera and Yandex Browser, any tab that uses the
microphone counts, and the call is named after the page. Safari and Firefox don't show which tab uses the microphone,
so there only Google Meet, Zoom, Discord, Telegram Web, Slack and Telemost tabs count. The app finds the tab through
Accessibility (already on for pasting); without it, the whole browser counts as the call. To record anything else,
Start Call Recording in the menu bar records your mic and everything the Mac plays.

When a call starts, recording starts too, and the app asks "Transcribe your call in Google Meet?":

- **Transcribe** keeps it.
- **Don't Keep** deletes the recording.
- **Never for Google Meet** (or Never for FaceTime, Never for This Site) deletes the recording, and calls in that app or
  on that site are never recorded again, in any browser. A site other than the services above is known by the start
  of its page title, up to the first separator such as " - " or " | ". To undo it, click − next to it in General → Calls → Never
  recorded.

If you don't answer, the call waits in the Calls tab, and nothing is sent until you click Transcribe there. To transcribe
every call without asking, or to stop noticing calls, change General → Calls → Record calls.

The model picked in Models → Calls writes the transcript (Gemini 3.8 Flash unless you pick Gemini 4 Argon), on
your OpenRouter key or through your own endpoint. Someone whose name comes
up in the call is named; the rest are "Participant 1", "Participant 2", and anyone in the room with you is "Nearby 1". On
the call's page, click a name to rename them, or a time to play the call from there. Once you've played it, the
play/pause key (F8 on Apple keyboards), your headphones' button and Control Center pause and resume it, until you leave
the page. Space works too.

Above the transcript, each call gets a summary in the call's language: what it was about, the key points, what was
decided, the tasks people took on, and the questions left open. Tick a task off when it's done; the Calls tab shows how
many are, like "2/3 tasks". A call up to 45 minutes gets its summary in the same request as its transcript. A longer one
sends its transcript once more, as text, which costs a little extra. Calls transcribed before summaries have Summarize
on their page: it works from the transcript and doesn't send the audio again. If a summary fails, the transcript is
still there, and Summarize tries again.

In Zoom, Discord, Slack, Google Meet, Telemost and Telegram, the app follows your mute: while you're muted, your
microphone isn't recorded, so what you say then is neither kept nor transcribed. Your first words right after you unmute
may be cut too. In other apps, and in a menu bar recording, what you say while muted is recorded and may end up in the
transcript.

To record the other side, turn on transcribe-thing in System Settings → Privacy & Security → Screen & System Audio
Recording, under System Audio Recording Only. Without it, their side comes out silent and the call says so. In a
browser, the app records all of the browser's sound, so music in another tab ends up in the recording.

On your Mac's speakers, your microphone hears the other side too. When a call is kept, the app takes their voices out of
your microphone's track, using the call app's own sound, so the transcript mixes you up with them less. With headphones
there's nothing to take out, and your microphone stays as it was recorded. That original is kept in the call's folder as
`mic-raw.m4a` and deleted with the call.

## Your data

History, the recordings, your dictionary and your API keys (OpenRouter's and your own endpoint's) stay on your Mac, in
`~/Library/Application Support/transcribe-thing`. Each key is in a file only you can read. Audio leaves your Mac only
when a Gemini model transcribes it: through OpenRouter, or through your own endpoint when it's the provider. Text leaves it only
when Gemini 3.8 Flash polishes or translates text you selected, or when a long call's transcript goes back for its
summary. Your dictionary's words go along with everything sent to Gemini.

The same folder keeps a log of what the app did in the last 7 days, without your dictations, your selected text or
your key. It stays there until you send it: General → Troubleshooting → Export Logs… saves it as a file.

History keeps every dictation with its recording, and a copy of the sound of every file you transcribe, until you
delete it, so you can transcribe it again with another model, polish it or translate it. General → History can
delete entries older than 1, 7, 30 or 90 days. Calls are kept in the same folder until you delete them, and that
setting deletes old calls too.

If the app quits or crashes, or the Mac shuts down, while you dictate or wait for the transcript, the recording isn't
lost. The next time the app starts, it's in History marked "Couldn't transcribe", with Retry. Nothing goes to a model
until you click it. A call the app was recording then is kept up to that point, in the Calls tab with Transcribe.

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
.build/debug/transcribe-thing --transcribe memo.m4a --engine geminiArgon --effort high
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

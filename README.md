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

- **Parakeet v3** (the default) runs on your Mac. It's the fastest, works offline, and recognizes 25 European
  languages by itself. It can also run through OpenRouter instead, for about $0.09 per hour of audio.
- **Gemini 3.8 Flash** is the most accurate. It thinks before it writes, so it's slower. It can also polish: press
  fn P while you talk, and it pastes the message you meant, without the false starts, detours and repeats.

Gemini can also translate: press fn T while you talk, and it pastes what you said in the other language. Russian
becomes English and English becomes Russian; pick another pair in General → Translate. With fn P on too, you get the
message you meant, translated.

On another model, fn P polishes and fn T translates the text you've selected instead: Gemini 3.8 Flash writes the
result on a card, and Paste Here puts it in place of the selection.

The cloud models run on your own [OpenRouter](https://openrouter.ai) key, and you pay OpenRouter per use. Each cloud
dictation sends its request twice at once and pastes the first answer, stopping the other, so it can cost up to twice
as much: a model that stops to think on one request doesn't hold you up. In Models, choose which model every
dictation starts on, whether hands-free dictations and fn ⇥ switch to the other one, and each one's pill color.

## Dictionary

Words, names and terms you use, and how they're spelled. Gemini 3.8 Flash gets them as a hint, so a dictation
spells "Wispr Flow" the way you do; Parakeet takes no hints. Add one with fn D over selected text, or in the
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

Gemini 3.8 Flash writes the transcript, on your OpenRouter key. Someone whose name comes up in the call is named; the
rest are "Participant 1", "Participant 2". On the call's page, click a name to rename them, or a time to play the call
from there. What you said while muted is marked "muted" in Zoom, Discord, Slack, Google Meet, Telemost and Telegram. In
other apps, what you said while muted may end up in the transcript.

To record the other side, turn on transcribe-thing in System Settings → Privacy & Security → Screen & System Audio
Recording, under System Audio Recording Only. Without it, their side comes out silent and the call says so. In a
browser, the app records all of the browser's sound, so music in another tab ends up in the recording.

## Your data

History, the recordings, your dictionary and your OpenRouter key stay on your Mac, in
`~/Library/Application Support/transcribe-thing`. The key is in a file only you can read. Audio leaves your Mac only
when a cloud model transcribes it. Text leaves it only when Gemini 3.8 Flash polishes or translates text you selected. Your
dictionary's words go along with everything sent to Gemini 3.8 Flash.

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
```

Cloud runs use the app's saved key, or `OPENROUTER_API_KEY` when it's set. `Sources/TranscribeThing/App/EngineCLI.swift`
lists every flag.

### Releasing

`make release VERSION=x.y.z` builds, signs and zips the app into `dist/` and drafts the release notes there. It never
pushes or publishes: it prints the `git push` and `gh release create` commands to run yourself.

Always sign releases with the same `transcribe-thing Developer` certificate, and keep it backed up. Installed copies
accept only updates signed with it, so a new certificate means everyone installs the next version by hand.

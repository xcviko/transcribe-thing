import SwiftUI

/// Every Hub page in the preview environment, plus the sub-states worth eyeballing.
/// `-full` entries are tall renders of a whole scrolling page.
enum HubSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [
            hub("hub-home", .home),
            hub("hub-home-full", .home, height: 1180),
            hub("hub-home-empty", .home) { c in
                c.history = .preview(entries: [])
            },
            hub("hub-home-attention", .home, height: 900) { c in
                c.permissions = .preview(mic: .denied, ax: .notDetermined)
                c.models = .preview(states: [.parakeet: .downloading(Samples.downloading)])
            },
            hub("hub-home-compact", .home, width: 820, height: 560),
            hub("hub-models-compact", .models, width: 820, height: 560) { c in
                c.models = .preview(states: [.parakeet: .downloading(Samples.downloading)])
            },
            // The narrowest window with Gemini thinking at High: the rows and pickers keep their ends.
            hub("hub-models-compact-high", .models, width: 820, height: 1400) { c in
                c.settings.reasoningEfforts[.geminiFlash] = .high
            },
            hub("hub-home-search", .home) { c in
                c.initialSearch = "zzz"
            },
            // The newest row hovered: Copy, the "…" row menu (Versions) and Delete.
            hub("hub-home-row-menu", .home, height: 900) { c in
                c.previewHoveredEntry = c.history.entries.first?.id
            },
            // Home work under way, each with its × to cancel it: Polish on the newest row, Gemini Flash transcribing
            // the second, a Retry on the failed one.
            hub("hub-home-transcribing", .home, height: 900) { c in
                let entries = c.history.entries
                var running: [UUID: TranscriptVersionKind] = [:]
                if let first = entries.first { running[first.id] = .polish() }
                if entries.count > 1 { running[entries[1].id] = .transcription(.geminiFlash) }
                if let failed = entries.first(where: { $0.status == .failed }) { running[failed.id] = .transcription(.parakeet) }
                c.previewRunning = running
            },
            // Home work that didn't come, said in its row with Retry and a × to dismiss it: Gemini Flash took too long
            // on the newest row, Polish failed on the second. The third's recording couldn't be read (nothing to
            // retry), nor the failed row's, which says it's no longer kept.
            hub("hub-home-work-failed", .home, height: 900) { c in
                c.previewFailures = Samples.homeFailures(c.history.entries)
            },
            // The same without an OpenRouter key: the reasons say so, and the cloud Retries are off until there is one.
            hub("hub-home-work-failed-key", .home, height: 900) { c in
                c.account = .preview(status: .missing)
                c.previewFailures = Samples.homeFailures(c.history.entries, keyMissing: true)
            },
            // The narrowest window: a failure's Retry and × stay on its first line when the reason wraps, and a
            // running line beside a long meta keeps its model's name.
            hub("hub-home-work-compact", .home, width: 820, height: 900) { c in
                let entries = c.history.entries
                guard entries.count > 2 else { return }
                c.previewFailures = [
                    entries[0].id: Samples.homeFailure(.polish(), .openRouterProviderUnavailable("")),
                    entries[2].id: Samples.homeFailure(.transcription(.geminiFlash), .timeout(.geminiFlash)),
                ]
                var running = [entries[1].id: TranscriptVersionKind.transcription(.geminiFlash)]
                if let failed = entries.first(where: { $0.status == .failed }) { running[failed.id] = .transcription(.parakeet) }
                c.previewRunning = running
            },
            // Files dropped on Home: one transcribed, one Gemini is transcribing now, one that failed.
            hub("hub-home-imported", .home, height: 900) { c in
                let imported = Samples.importedEntries()
                c.history = .preview(entries: imported + c.history.entries)
                c.previewRunning = [imported[1].id: .transcription(.geminiFlash)]
            },
            hub("hub-home-drop", .home) { c in
                c.previewDropTarget = true
            },
            // Dictations the app quit during, brought back at launch: one cut off while it was recorded (Continue
            // records on, Transcribe beside it), one quit while it was transcribed (Continue transcribes it).
            hub("hub-home-interrupted", .home) { c in
                c.history = .preview(entries: Samples.interruptedEntries() + c.history.entries)
            },
            // The cut-off one being recorded on after its Continue.
            hub("hub-home-interrupted-recording", .home) { c in
                let interrupted = Samples.interruptedEntries()
                c.history = .preview(entries: interrupted + c.history.entries)
                c.previewRecordingOn = interrupted[0].id
                c.previewDictating = true
            },
            // Their transcriptions didn't come: why, above the same Continue and Transcribe, which try again.
            hub("hub-home-interrupted-failed", .home) { c in
                let interrupted = Samples.interruptedEntries()
                c.history = .preview(entries: interrupted + c.history.entries)
                c.previewFailures = [
                    interrupted[0].id: Samples.homeFailure(.transcription(.geminiFlash), .timeout(.geminiFlash)),
                    interrupted[1].id: Samples.homeFailure(.transcription(.parakeet), .engineFailed(.parakeet, "")),
                ]
            },
            // Another dictation is being recorded: Continue waits for it, and says so on hover.
            hub("hub-home-interrupted-dictating", .home) { c in
                c.history = .preview(entries: Samples.interruptedEntries() + c.history.entries)
                c.previewDictating = true
            },
            // Selected text polished and translated by Gemini 3.8 Flash: each glyph in its model's color.
            hub("hub-home-selections", .home, height: 900) { c in
                c.history = .preview(entries: Samples.selectionEntries() + c.history.entries)
            },

            // Calls (`--only hub-call`): every state a call can be in, by day, with the badge on the sidebar.
            hub("hub-calls", .calls, configure: Samples.calls),
            hub("hub-calls-full", .calls, height: 1120, configure: Samples.calls),
            hub("hub-calls-compact", .calls, width: 820, height: 560, configure: Samples.calls),
            // The Meet call hovered: Copy Transcript and Delete.
            hub("hub-calls-hover", .calls) { c in
                Samples.calls(c)
                c.previewHoveredCall = PreviewFixtures.callID(2)
            },
            // A Meet call being recorded and asked about, 12:34 in: the question in its row, and in the badge.
            hub("hub-calls-asking", .calls) { c in
                Samples.calls(c)
                Samples.live(c, kept: false)
            },
            // The same call kept, still recording.
            hub("hub-calls-recording", .calls) { c in
                Samples.calls(c)
                Samples.live(c, kept: true)
            },
            hub("hub-calls-search", .calls) { c in
                Samples.calls(c)
                c.initialSearch = "аня"
            },
            hub("hub-calls-off", .calls) { c in
                Samples.calls(c)
                c.settings.callRecording = .off
            },
            // Calls made from files: a screen recording done (its film, its cost), a lecture's audio transcribing.
            hub("hub-calls-file", .calls, configure: Samples.callsWithFiles),
            // Files dragged over Calls.
            hub("hub-calls-drop", .calls) { c in
                Samples.calls(c)
                c.previewDropTarget = true
            },
            // The design review's page: where the file was, three speakers, its summary.
            hub("hub-call-detail-file", .callDetail, height: 1100) { c in
                Samples.callsWithFiles(c)
                c.windows.openCallID = PreviewFixtures.callID(7)
            },
            hub("hub-call-detail-file-transcribing", .callDetail) { c in
                Samples.callsWithFiles(c)
                c.windows.openCallID = PreviewFixtures.callID(8)
            },
            hub("hub-calls-empty", .calls),
            hub("hub-calls-empty-off", .calls) { c in c.settings.callRecording = .off },
            // The Meet call: three speakers besides Sam, Matvey renamed, a phrase said muted, another tab's sound.
            hub("hub-call-detail", .callDetail, height: 900) { c in Samples.openCall(c, 2) },
            hub("hub-call-detail-compact", .callDetail, width: 820, height: 560) { c in Samples.openCall(c, 2) },
            // The Meet call's first 3:20, played to 2:48: the waveform in its speakers' colors (the muted phrase dimmed),
            // and before its loudness is read, flat.
            hub("hub-call-detail-waveform", .callDetail) { c in Samples.waveformCall(c) },
            hub("hub-call-detail-waveform-flat", .callDetail) { c in
                Samples.waveformCall(c)
                c.previewWaveformFlat = true
            },
            hub("hub-call-detail-waveform-compact", .callDetail, width: 820, height: 560) { c in Samples.waveformCall(c) },
            // The Meet call's summary whole (two of its four tasks done), then the transcript.
            hub("hub-call-detail-summary", .callDetail, height: 1260) { c in Samples.openCall(c, 2) },
            // The same call transcribed before summaries: Summarize, and the same while it runs.
            hub("hub-call-detail-no-summary", .callDetail) { c in
                Samples.openCall(c, 2)
                c.calls.update(PreviewFixtures.callID(2)) { $0.summary = nil }
            },
            hub("hub-call-detail-summarizing", .callDetail) { c in
                Samples.openCall(c, 2)
                c.calls.update(PreviewFixtures.callID(2)) { $0.summary = nil }
                c.calls.summarizing.insert(PreviewFixtures.callID(2))
            },
            // The design review dropped as a video, its "Speaker 2" being named from the picture.
            hub("hub-call-detail-naming", .callDetail, height: 1100) { c in
                Samples.callsWithFiles(c)
                c.windows.openCallID = PreviewFixtures.callID(7)
                c.calls.namingSpeakers.insert(PreviewFixtures.callID(7))
            },
            // The same once its "Speaker 2" was named from the video: the header says where the name came from.
            hub("hub-call-detail-named", .callDetail, height: 1100) { c in
                Samples.callsWithFiles(c)
                c.windows.openCallID = PreviewFixtures.callID(7)
                c.calls.update(PreviewFixtures.callID(7)) {
                    $0.speakerNames["Speaker 2"] = "Pablo"
                    $0.videoNamedSpeakers = ["Speaker 2"]
                }
            },
            // The step found no one it was sure of, then the step failed: said where the hint was.
            hub("hub-call-detail-naming-none", .callDetail, height: 1100) { c in
                Samples.callsWithFiles(c)
                c.windows.openCallID = PreviewFixtures.callID(7)
                c.calls.namingResult[PreviewFixtures.callID(7)] = .init(message: "Couldn’t tell who’s who from the video.")
            },
            hub("hub-call-detail-naming-failed", .callDetail, height: 1100) { c in
                Samples.callsWithFiles(c)
                c.windows.openCallID = PreviewFixtures.callID(7)
                c.calls.namingResult[PreviewFixtures.callID(7)] = .init(message: "Couldn’t look at the video.",
                                                                        detail: "The video is too large.")
            },
            // Telemost's summary failed: why, and Summarize.
            hub("hub-call-detail-summary-failed", .callDetail) { c in Samples.openCall(c, 6) },
            // Telemost's other side came out silent: the permission, with Open Settings.
            hub("hub-call-detail-silent", .callDetail) { c in Samples.openCall(c, 6) },
            hub("hub-call-detail-unconfirmed", .callDetail) { c in Samples.openCall(c, 4) },
            hub("hub-call-detail-failed", .callDetail) { c in Samples.openCall(c, 3) },
            hub("hub-call-detail-transcribing", .callDetail) { c in Samples.openCall(c, 1) },
            // The Meet call scrolled to its transcript: the card stays at the top, a hairline under it.
            hub("hub-call-detail-scrolled", .callDetail) { c in
                Samples.waveformCall(c)
                c.previewCallScroll = 640
            },
            hub("hub-call-detail-scrolled-compact", .callDetail, width: 820, height: 560) { c in
                Samples.waveformCall(c)
                c.previewCallScroll = 640
            },
            // The Meet call being recorded now, 12:34 in: Recording, with Stop, and no player yet.
            hub("hub-call-detail-recording", .callDetail) { c in
                Samples.live(c, kept: true)
                c.windows.openCallID = PreviewFixtures.callID(99)
            },
            // Recorded from the menu bar: its mute isn't followed, and it ran nowhere in particular.
            hub("hub-call-detail-menu-bar", .callDetail) { c in
                Samples.waveformCall(c)
                c.calls.update(PreviewFixtures.callID(2)) {
                    $0.manual = true
                    $0.muteIntervals = []
                    $0.otherBrowserAudio = []
                }
            },
            // Everything worth a note: muted, mute not known, another tab's sound, speech missed, cut off. Then the
            // same in the narrowest window, with a long page title and eight speakers.
            hub("hub-call-detail-notes", .callDetail) { c in
                Samples.waveformCall(c)
                c.calls.update(PreviewFixtures.callID(2)) { Samples.noteEverything(&$0) }
            },
            hub("hub-call-detail-crowded-compact", .callDetail, width: 820, height: 560) { c in
                Samples.waveformCall(c)
                c.calls.update(PreviewFixtures.callID(2)) {
                    Samples.noteEverything(&$0)
                    Samples.crowd(&$0)
                }
            },
            // A speaker's name clicked: the field that renames them (a popover doesn't render in a page snapshot).
            SnapshotEntry("hub-call-rename", width: 300, height: 170) { _ in
                SpeakerRenameForm(original: "Participant 1", current: "Matvey") { _ in }
                    .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.bgCanvas)
            },
            // A name the video gave: the field says so.
            SnapshotEntry("hub-call-rename-video", width: 300, height: 190) { _ in
                SpeakerRenameForm(original: "Speaker 2", current: "Pablo", fromVideo: true) { _ in }
                    .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.bgCanvas)
            },
            // General → Calls, on its own (the page is taller than a window).
            hub("hub-general-calls", .general, height: 1700),
            // The same, with apps and sites never recorded: an app with its icon, an unknown one, two sites.
            hub("hub-general-calls-exclusions", .general, height: 1900) { c in
                c.settings.callExclusions = [
                    .app(bundleID: "com.apple.FaceTime", name: "FaceTime"),
                    .app(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
                    CallExclusion.site(service: .meet, page: "Meet – abc-defg-hij")!,
                    CallExclusion.site(service: nil, page: "ChatGPT")!,
                ]
            },

            // General → Browser Extension (`--only hub-general-browser`), below Calls: Chrome to install, Arc in two
            // profiles, Firefox and Safari coming later. Then Chrome's Install clicked (its steps open), and no browser.
            hub("hub-general-browser-extension", .general, height: 2150) { c in
                c.browserExtension = .preview(
                    browsers: [PreviewFixtures.chrome, PreviewFixtures.arc, PreviewFixtures.firefox, PreviewFixtures.safari],
                    connections: PreviewFixtures.connections(PreviewFixtures.arc, profiles: 2))
            },
            hub("hub-general-browser-installing", .general, height: 2150) { c in
                c.browserExtension = .preview(browsers: [PreviewFixtures.chrome, PreviewFixtures.safari])
                c.previewInstallingBrowser = PreviewFixtures.chrome.id
            },
            hub("hub-general-browser-connected", .general, height: 2150) { c in
                c.browserExtension = .preview(browsers: [PreviewFixtures.chrome],
                                              connections: PreviewFixtures.connections(PreviewFixtures.chrome, profiles: 1))
            },
            hub("hub-general-browser-none", .general, height: 2150),
            // A Meet call in Chrome, which has no extension: the note above the calls, and the empty tab's pointer.
            hub("hub-calls-browser-hint", .calls) { c in
                Samples.calls(c)
                c.browserExtension = .preview(browsers: [PreviewFixtures.chrome, PreviewFixtures.safari])
            },
            hub("hub-calls-empty-browser", .calls) { c in
                c.browserExtension = .preview(browsers: [PreviewFixtures.chrome, PreviewFixtures.safari])
            },
            hub("hub-calls-empty-browser-compact", .calls, width: 820, height: 560) { c in
                c.browserExtension = .preview(browsers: [PreviewFixtures.chrome, PreviewFixtures.safari])
            },

            hub("hub-models", .models),
            hub("hub-models-full", .models, height: 1080),
            // Hands-free switches to Gemini.
            hub("hub-models-hands-free", .models, height: 1080) { c in c.settings.handsFreeModel = .gemini },
            hub("hub-models-downloading", .models) { c in
                c.models = .preview(states: [.parakeet: .downloading(Samples.downloading)])
            },
            hub("hub-models-preparing", .models) { c in
                c.models = .preview(states: [.parakeet: .preparing(since: Date().addingTimeInterval(-24))])
            },
            hub("hub-models-failed", .models) { c in
                c.models = .preview(states: [.parakeet: .failed("Download didn’t finish. The connection was lost.")],
                                    lastErrors: [.parakeet: .downloadFailed(.parakeet, "The connection was lost.")])
            },
            hub("hub-models-load-failed", .models) { c in
                c.models = .preview(states: [.parakeet: .failed("Couldn’t load the model. Retry, or download it again.")],
                                    lastErrors: [.parakeet: .modelLoadFailed(.parakeet, "Corrupt weights")])
            },
            hub("hub-home-load-failed", .home) { c in
                c.models = .preview(states: [.parakeet: .failed("Couldn’t load the model. Retry, or download it again.")],
                                    lastErrors: [.parakeet: .modelLoadFailed(.parakeet, "Corrupt weights")])
            },
            hub("hub-models-key-limit", .models, height: 1100) { c in
                c.settings.lineup.main = .gemini
                c.account = .preview(status: .noCredit(KeyInfo(label: "transcribe-thing", limit: 5, limitRemaining: 0, usage: 5)))
            },
            hub("hub-models-key-invalid", .models, height: 1100) { c in
                c.account = .preview(status: .invalid("401"))
            },
            hub("hub-models-key-missing", .models, height: 1100) { c in
                c.account = .preview(status: .missing)
            },
            // API keys, at the bottom: OpenRouter picked (its key alone), the custom endpoint picked and working, its
            // key rejected, picked but not set up (Gemini "Needs endpoint"), OpenRouter picked with an endpoint saved,
            // saved as a bare host (read as …/api/v1), and the endpoint alone (no OpenRouter key: Gemini ready
            // through it).
            hub("hub-models-endpoint-unset", .models, height: 1500),
            hub("hub-models-endpoint-not-set-up", .models, height: 1500) { c in
                c.proxy = .preview(status: .notSet, settings: c.settings, enabled: true)
                c.settings.lineup.main = .gemini
            },
            hub("hub-models-endpoint-works", .models, height: 1500) { c in
                c.proxy = .preview(status: .works, settings: c.settings)
            },
            hub("hub-models-endpoint-rejected", .models, height: 1500) { c in
                c.proxy = .preview(status: .keyRejected("API key not valid. Please pass a valid API key."),
                                   settings: c.settings)
            },
            hub("hub-models-endpoint-off", .models, height: 1500) { c in
                c.proxy = .preview(status: .works, settings: c.settings, enabled: false)
            },
            hub("hub-models-endpoint-host-only", .models, height: 1500) { c in
                c.proxy = .preview(status: .works, settings: c.settings, url: "https://llm.example.com")
            },
            hub("hub-models-endpoint-only", .models, height: 1500) { c in
                c.account = .preview(status: .missing)
                c.proxy = .preview(status: .works, settings: c.settings)
                c.settings.lineup.main = .gemini
            },
            hub("hub-home-endpoint-rejected", .home) { c in
                c.settings.lineup.main = .gemini
                c.proxy = .preview(status: .keyRejected("API key not valid."), settings: c.settings)
            },
            // Switch model rebound to right ⌘: the line above the lineup shows the real binding.
            hub("hub-models-extra-custom", .models, height: 1100) { c in
                c.settings.shortcuts[.switchModel] = .rightCommand
            },
            hub("hub-models-compact-key-missing", .models, width: 820, height: 1140) { c in
                c.account = .preview(status: .missing)
            },
            hub("hub-models-extra-unbound", .models, height: 1100) { c in
                c.settings.shortcuts[.switchModel] = nil
            },
            // Gemini as the main model: its row takes the radio and "Main", and Parakeet gets a switch.
            hub("hub-models-main-gemini", .models, height: 1100) { c in
                c.settings.lineup.main = .gemini
            },
            // Dragged into Gemini, Parakeet: the line follows the new order from the main model.
            hub("hub-models-reordered", .models, height: 1100) { c in
                c.settings.lineup.move(.gemini, to: 0)
            },
            // Only the main model takes part: the line says how to reach another.
            hub("hub-models-only-main", .models, height: 1100) { c in
                c.settings.lineup.setSwitchable(.gemini, false)
            },
            // Colors picked in Models: every tile wears its model's, the Parakeet on this Mac tile and the sidebar chip
            // Parakeet's.
            hub("hub-models-colors", .models, height: 1100, configure: Samples.pickColors),
            // History's marks in the picked colors.
            hub("hub-home-model-colors", .home, configure: Samples.pickColors),
            // Each model's colors as its tile opens them (a popover doesn't render in a page snapshot), in its default
            // color.
            SnapshotEntry("hub-model-color-picker", width: 3 * ModelColorPopover.width + 4 * 24, height: 230) { _ in
                HStack(alignment: .top, spacing: 24) {
                    ForEach(ModelChoice.allCases) { choice in
                        ModelColorPopover(choice: choice, color: choice.defaultColor) { _ in }
                            .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.stroke, lineWidth: 1)
                            }
                            .cardShadow(elevated: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.bgCanvas)
            },

            hub("hub-shortcuts", .shortcuts),
            // Hands-free just recorded as ⌃⌥Space: saved, with macOS's input-source shortcut as the warning.
            hub("hub-shortcuts-warning", .shortcuts,
                recorderMessages: ShortcutRecorderSnapshots.message(
                    recording: ShortcutRecorderSnapshots.controlOptionSpace, for: .handsFree).map { [.handsFree: $0] } ?? [:]) { c in
                c.settings.shortcuts[.handsFree] = ShortcutRecorderSnapshots.controlOptionSpace
            },
            // Also a customized binding, so "Restore Defaults" shows in the header.
            hub("hub-shortcuts-secure", .shortcuts) { c in
                c.secureInput = .preview(active: true, owningAppName: "1Password")
                c.settings.shortcuts[.pushToTalk] = .rightOption
            },

            hub("hub-microphone", .microphone),
            hub("hub-microphone-bluetooth", .microphone) { c in
                c.settings.microphoneUID = "preview-airpods"
            },
            // Automatic with AirPods as the macOS default: Automatic means them now, and the hint offers the built-in mic.
            hub("hub-microphone-automatic-airpods", .microphone) { c in
                c.devices = .preview(devices: AudioDeviceCatalog.preview().devices, defaultUID: "preview-airpods")
            },

            hub("hub-dictionary", .dictionary, height: 720) { c in
                c.settings.dictionary = UserDictionary(words: [
                    "Wispr Flow", "OpenRouter", "Parakeet", "GPT-6 Luna", "Gemini 3.8 Flash", "SwiftUI", "Claude Code",
                    "Мелания Трамп", "TestFlight", "xcviko", "Liquid Glass", "Тбилиси", "Kubernetes", "Figma",
                ])
            },
            // Sorted into groups: Ungrouped first, then each group with its handle, count and trash.
            hub("hub-dictionary-groups", .dictionary, height: 900) { c in
                var dictionary = UserDictionary(words: [
                    "Wispr Flow", "OpenRouter", "Parakeet", "GPT-6 Luna", "Gemini 3.8 Flash", "SwiftUI", "Claude Code",
                    "Мелания Трамп", "TestFlight", "xcviko", "Liquid Glass", "Тбилиси", "Kubernetes", "Figma",
                ])
                let apple = dictionary.addGroup(named: "Apple")
                let models = dictionary.addGroup(named: "Models")
                for word in ["OpenRouter", "Parakeet", "GPT-6 Luna", "Gemini 3.8 Flash", "Claude Code"] {
                    dictionary.move(word, to: models)
                }
                for word in ["SwiftUI", "TestFlight", "Liquid Glass"] { dictionary.move(word, to: apple) }
                dictionary.addGroup(named: "Travel")
                c.settings.dictionary = dictionary
            },
            hub("hub-dictionary-empty", .dictionary, height: 560),
            // Pasting set per model: quick Parakeet searches go in bare, Gemini gets a space after.
            hub("hub-general", .general, height: 1080) { c in
                c.settings.modelsAddingSpace = [.gemini]
                c.settings.modelsRemovingFinalPeriod = [.parakeet]
                c.settings.modesRemovingFinalPeriod = [.pushToTalk]
            },
            // The whole page, down to Troubleshooting's Export Logs….
            hub("hub-general-full", .general, height: 1360),
            // The narrowest window: the segmented control leaves the least room for the pill caption; sounds off.
            hub("hub-general-compact", .general, width: 820, height: 560) { c in
                c.settings.pillMode = .always
                c.settings.soundsEnabled = false
            },
            // The narrowest window: Pasting's chips still fit under each rule.
            hub("hub-general-pasting-compact", .general, width: 820, height: 1080) { c in
                c.settings.modelsAddingSpace = [.gemini]
                c.settings.modelsRemovingFinalPeriod = [.parakeet]
                c.settings.modesRemovingFinalPeriod = [.pushToTalk]
            },
            hub("hub-general-permissions", .general, height: 1080) { c in
                c.permissions = .preview(mic: .granted, ax: .denied)
                c.launchAtLogin = .preview()
            },
            // 0.3.0 is out: a red badge on General in the sidebar and on the Software Update row.
            hub("hub-general-update", .general) { c in
                c.updates = Samples.updates(c)
            },
            // Reminders off: no badges, though the row still says what's out.
            hub("hub-general-update-ignored", .general) { c in
                c.settings.checkForUpdatesAutomatically = false
                c.updates = Samples.updates(c)
            },

            hub("hub-update-available", .softwareUpdate, height: 1240) { c in
                c.updates = Samples.updates(c)
            },
            hub("hub-update-available-compact", .softwareUpdate, width: 820, height: 560) { c in
                c.updates = Samples.updates(c)
            },
            hub("hub-update-downloading", .softwareUpdate) { c in
                c.updates = Samples.updates(c, install: .downloading(Samples.newVersion, received: 4_200_000, total: 12_400_000))
            },
            hub("hub-update-waiting", .softwareUpdate) { c in
                c.updates = Samples.updates(c, install: .waitingForDictation(Samples.newVersion))
            },
            hub("hub-update-needs-restart", .softwareUpdate) { c in
                c.updates = Samples.updates(c, install: .needsRestart(Samples.newVersion))
            },
            hub("hub-update-install-failed", .softwareUpdate) { c in
                c.updates = Samples.updates(c, install: .failed(Samples.newVersion, .adHocSigned))
            },
            hub("hub-update-download-failed", .softwareUpdate) { c in
                c.updates = Samples.updates(c, install: .failed(Samples.newVersion, .downloadFailed("The network connection was lost.")))
            },
            hub("hub-update-current", .softwareUpdate, height: 1000) { c in
                c.updates = Samples.updates(c, releases: PreviewFixtures.releases(upTo: PreviewFixtures.installedVersion))
            },
            hub("hub-update-checking", .softwareUpdate) { c in
                c.updates = Samples.updates(c, releases: PreviewFixtures.releases(upTo: PreviewFixtures.installedVersion),
                                            isChecking: true)
            },
            hub("hub-update-check-failed", .softwareUpdate) { c in
                c.updates = Samples.updates(c, releases: PreviewFixtures.releases(upTo: PreviewFixtures.installedVersion),
                                            checkError: .offline)
            },
            hub("hub-update-no-releases", .softwareUpdate) { c in
                c.updates = Samples.updates(c, releases: [])
            },
        ]
    }

    /// `recorderMessages`: what shortcut recorders show, as if a shortcut had just been recorded.
    private static func hub(_ name: String, _ section: HubSection, width: CGFloat = 980, height: CGFloat = 680,
                            recorderMessages: [ShortcutAction: RecorderMessage] = [:],
                            configure: @escaping @MainActor (HubContext) -> Void = { _ in }) -> SnapshotEntry {
        SnapshotEntry(name: name, size: CGSize(width: width, height: height)) { env in
            env.windows.hubSection = section
            let context = HubContext(env: env)
            context.drawsWindowControls = true
            context.firstName = "Sam"
            configure(context)
            return AnyView(HubView(context: context)
                .environment(\.shortcutRecorderPreviewMessages, recorderMessages))
        }
    }

    private enum Samples {
        /// 2:40 PM today, so the hidden pill reads "Back at 3:40 PM".
        static var now: Date {
            Calendar.current.date(bySettingHour: 14, minute: 40, second: 0, of: Date()) ?? Date()
        }
        /// Software Update was last checked at 2:05 PM, five minutes before the page's "now".
        static var checkedAt: Date {
            Calendar.current.date(bySettingHour: 14, minute: 5, second: 0, of: Date()) ?? Date()
        }
        static let newVersion = AppVersion(major: 0, minor: 3, patch: 0)

        /// The fixture calls (`PreviewFixtures.calls`).
        @MainActor static func calls(_ context: HubContext) {
            context.calls = .preview(calls: PreviewFixtures.calls(), settings: context.settings)
        }

        /// The fixture calls, with two made from files (`PreviewFixtures.importedCalls`).
        @MainActor static func callsWithFiles(_ context: HubContext) {
            context.calls = .preview(calls: PreviewFixtures.importedCalls() + PreviewFixtures.calls(),
                                     settings: context.settings)
        }

        /// A Meet call recorded now, 12:34 in: kept (in the store, as the monitor puts it) or asked about.
        @MainActor static func live(_ context: HubContext, kept: Bool) {
            let now = Date()
            let info = PreviewFixtures.liveCall(startedAt: now.addingTimeInterval(-754))
            context.fixedNow = now
            context.previewCallState = kept ? .recording(info) : .asking(info)
            guard kept else { return }
            var record = CallRecord(id: info.id, startedAt: info.startedAt, appName: info.appName,
                                    bundleID: info.bundleID, service: info.service, pageTitle: info.pageTitle,
                                    status: .recording)
            record.muteKnown = true
            context.calls = .preview(calls: [record] + PreviewFixtures.calls(), settings: context.settings)
        }

        /// The Calls tab's call `n` (`PreviewFixtures.callID`) open on its page.
        @MainActor static func openCall(_ context: HubContext, _ n: Int) {
            calls(context)
            context.windows.openCallID = PreviewFixtures.callID(n)
        }

        /// The Meet call cut to its first 3:20, where all its phrases are, 2:48 played.
        @MainActor static func waveformCall(_ context: HubContext) {
            openCall(context, 2)
            context.calls.update(PreviewFixtures.callID(2)) {
                $0.micSeconds = 200
                $0.remoteSeconds = 200
            }
            context.previewCallPosition = 168
        }

        /// Every note a call can have: two mutes, mute not known, another tab's sound, speech maybe missed between
        /// 1:35 and 2:30, cut off at 3:10.
        static func noteEverything(_ call: inout CallRecord) {
            call.muteKnown = false
            call.missedSpeech = [CallInterval(start: 95, end: 150)]
            call.cutOffAt = 190
        }

        /// A long page title and eight speakers: five more on the other side.
        static func crowd(_ call: inout CallRecord) {
            call.pageTitle = "Weekly release sync with design, support and the whole platform team – abc-defg-hij"
            let extra = (3...7).map { n in
                CallTranscript.Segment(start: 190 + Double(n), end: 191 + Double(n), side: .remote,
                                       speaker: "Participant \(n)", text: "Sounds good.")
            }
            call.transcript?.segments += extra
        }

        /// Colors other than the defaults, one each: Parakeet teal, Gemini blue.
        @MainActor static func pickColors(_ context: HubContext) {
            context.settings.modelColors[.parakeet] = .teal
            context.settings.modelColors[.gemini] = .blue
        }

        @MainActor static func updates(_ context: HubContext, releases: [Release] = PreviewFixtures.releases(),
                                       isChecking: Bool = false, checkError: UpdateCheckError? = nil,
                                       install: UpdateCenter.InstallPhase = .idle) -> UpdateCenter {
            context.fixedNow = checkedAt.addingTimeInterval(5 * 60)
            return .preview(settings: context.settings, toasts: context.toasts, releases: releases,
                            lastChecked: checkedAt, isChecking: isChecking, checkError: checkError, install: install)
        }

        static let downloading = DownloadProgress(fraction: 0.42, bytesReceived: 265_600_000, totalBytes: 632_321_326,
                                                  bytesPerSecond: 9_800_000, secondsRemaining: 38)

        /// Selected text rewritten by Flash: translated, and polished.
        static func selectionEntries() -> [TranscriptEntry] {
            let now = Date()
            func entry(_ text: String, _ kind: TranscriptVersionKind, ago: TimeInterval) -> TranscriptEntry {
                let version = TranscriptResult(text: text, engine: kind.engine, processingTime: 3.2)
                    .version(kind)
                return TranscriptEntry(createdAt: now.addingTimeInterval(-ago), engine: kind.engine,
                                       audioDuration: 0, voicedSeconds: 0, versions: [version])
            }
            return [
                entry("Tomorrow I’ll go again and check how it does with intervals.",
                      .selectionTranslation(.geminiFlash), ago: 30),
                entry("We ship the import on Friday, and Pasha checks the long files over the weekend.",
                      .selection(.geminiFlash), ago: 90),
            ]
        }

        /// Dictations the app quit during: one cut off while it was recorded, one quit while it was transcribed.
        static func interruptedEntries() -> [TranscriptEntry] {
            let now = Date()
            func entry(_ interruption: TranscriptEntry.Interruption, engine: EngineID, seconds: TimeInterval,
                       ago: TimeInterval) -> TranscriptEntry {
                var entry = TranscriptEntry(createdAt: now.addingTimeInterval(-ago), text: "", engine: engine,
                                            status: .failed, audioDuration: seconds, voicedSeconds: seconds * 0.8,
                                            errorMessage: interruption.message, mode: .handsFree,
                                            audioFileName: "interrupted-\(interruption.rawValue).m4a")
                entry.interruption = interruption
                return entry
            }
            return [
                entry(.whileRecording, engine: .geminiFlash, seconds: 48, ago: 20),
                entry(.whileTranscribing, engine: .parakeet, seconds: 12, ago: 50),
            ]
        }

        /// Rows made from files: a transcript, one not transcribed yet, one that failed.
        static func importedEntries() -> [TranscriptEntry] {
            let now = Date()
            return [
                TranscriptEntry(createdAt: now.addingTimeInterval(-60),
                                text: "Okay, so the plan for the release: we ship the import on Friday, and Pasha checks the long files over the weekend.",
                                engine: .geminiFlash, audioDuration: 754, voicedSeconds: 600, costUSD: 0.012,
                                audioFileName: "a.m4a", importedFrom: "Standup 2026-10-09.m4a"),
                TranscriptEntry(createdAt: now.addingTimeInterval(-120), text: "", engine: .geminiFlash,
                                status: .cancelled, audioDuration: 2_710, voicedSeconds: 2_400, audioFileName: "b.m4a",
                                importedFrom: "Interview with Anna, part 2.mp3"),
                TranscriptEntry(createdAt: now.addingTimeInterval(-180), text: "", engine: .parakeetCloud,
                                status: .failed, audioDuration: 41, voicedSeconds: 30,
                                errorMessage: "Parakeet v3 · Cloud took too long", audioFileName: "c.m4a",
                                importedFrom: "voice_2026-10-08.ogg"),
            ]
        }

        /// Home work that didn't come, in the words the controller uses: Gemini Flash on the newest row, Polish on the
        /// second, and Parakeet · Cloud on the third and Parakeet on the failed row, whose recordings couldn't be read.
        static func homeFailures(_ entries: [TranscriptEntry], keyMissing: Bool = false) -> [UUID: HomeFailure] {
            var failures: [UUID: HomeFailure] = [:]
            if let first = entries.first {
                failures[first.id] = homeFailure(.transcription(.geminiFlash),
                                                 keyMissing ? .openRouterMissingKey : .timeout(.geminiFlash))
            }
            if entries.count > 1 {
                failures[entries[1].id] = homeFailure(.polish(),
                                                      keyMissing ? .openRouterMissingKey : .openRouterProviderUnavailable(""))
            }
            if entries.count > 2 { failures[entries[2].id] = .recordingGone(.transcription(.parakeetCloud)) }
            if let failed = entries.first(where: { $0.status == .failed }) {
                failures[failed.id] = .recordingGone(.transcription(.parakeet))
            }
            return failures
        }

        /// `kind` didn't come because of `error`, as the controller says it.
        static func homeFailure(_ kind: TranscriptVersionKind, _ error: AppError) -> HomeFailure {
            HomeFailure(kind: kind, reason: DictationController.homeFailureReason(error, making: kind))
        }
    }
}

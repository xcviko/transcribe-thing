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
                c.models = .preview(states: [.gigaam: .downloading(Samples.downloading)])
            },
            hub("hub-home-compact", .home, width: 820, height: 560),
            hub("hub-models-compact", .models, width: 820, height: 560) { c in
                c.models = .preview(states: [.gigaam: .downloading(Samples.downloading)])
            },
            // The narrowest window with Gemini thinking at High: the rows and pickers keep their ends.
            hub("hub-models-compact-high", .models, width: 820, height: 1400) { c in
                c.settings.reasoningEfforts[.geminiFlash] = .high
            },
            // The narrowest window with Gemini 4 Carbon switched on and thinking at High.
            hub("hub-models-compact-carbon", .models, width: 820, height: 1100) { c in
                c.settings.lineup.setSwitchable(.carbon, true)
                c.settings.reasoningEfforts[.geminiCarbon] = .high
            },
            // The narrowest window with Gemini 4 Hydrogen switched on and thinking at High.
            hub("hub-models-compact-hydrogen", .models, width: 820, height: 1100) { c in
                c.settings.lineup.setSwitchable(.hydrogen, true)
                c.settings.reasoningEfforts[.geminiHydrogen] = .high
            },
            // The narrowest window with Gemini 4 Neon switched on and thinking at High.
            hub("hub-models-compact-neon", .models, width: 820, height: 1200) { c in
                c.settings.lineup.setSwitchable(.neon, true)
                c.settings.reasoningEfforts[.geminiNeon] = .high
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
                if let failed = entries.first(where: { $0.status == .failed }) { running[failed.id] = .gigaam(.v3) }
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
                if let failed = entries.first(where: { $0.status == .failed }) { running[failed.id] = .gigaam(.v3) }
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
                    interrupted[1].id: Samples.homeFailure(.gigaam(.v3), .engineFailed(.gigaam, "")),
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
            // Dictations by Gemini 4 Carbon, one polished: its C glyph in Carbon's blue.
            hub("hub-home-carbon", .home, height: 900) { c in
                c.history = .preview(entries: Samples.carbonEntries() + c.history.entries)
            },
            // Dictations by Gemini 4 Hydrogen, one polished: its H glyph in Hydrogen's pink.
            hub("hub-home-hydrogen", .home, height: 900) { c in
                c.history = .preview(entries: Samples.hydrogenEntries() + c.history.entries)
            },
            // Dictations by Gemini 4 Neon, one polished: its N glyph in Neon's orange.
            hub("hub-home-neon", .home, height: 900) { c in
                c.history = .preview(entries: Samples.neonEntries() + c.history.entries)
            },
            // GigaAM v3 as the main model, and dictations by it and by the retired v3 e2e: its G glyph in its green.
            hub("hub-home-gigaam", .home, height: 900) { c in
                c.history = .preview(entries: Samples.gigaamEntries() + c.history.entries)
            },
            // What retired models wrote, still in History (`--only hub-gigaam-compare`): a dictation Parakeet wrote and
            // each GigaAM version transcribed again before v3 e2e and Multilingual were retired, its row showing v3's
            // text and four versions.
            hub("hub-gigaam-compare-home", .home, height: 760) { c in
                c.history = .preview(entries: [Samples.gigaamCompareEntry()] + c.history.entries)
            },
            // Its Versions menu (drawn: a menu doesn't render in a snapshot): the four versions, v3's checked, and
            // Transcribe With offering no GigaAM, v3 being there; the retired ones are never offered.
            menu("hub-gigaam-compare-menu", entry: Samples.gigaamCompareEntry(), models: [.gigaam: .ready]),
            // A Parakeet dictation's Transcribe With: GigaAM v3, the one version left, downloaded.
            menu("hub-gigaam-compare-transcribe-with", entry: Samples.gigaamCompareEntry(parakeetOnly: true),
                 models: [.gigaam: .installed]),

            hub("hub-models", .models),
            hub("hub-models-full", .models, height: 1080),
            // Hands-free switches to Gemini.
            hub("hub-models-hands-free", .models, height: 1080) { c in c.settings.handsFreeModel = .gemini },
            // Gemini 4 Carbon switched on, thinking at its default (Low), and hands-free's model; Flash at High.
            hub("hub-models-carbon", .models, height: 1100) { c in
                c.settings.lineup.setSwitchable(.carbon, true)
                c.settings.handsFreeModel = .carbon
                c.settings.reasoningEfforts[.geminiFlash] = .high
            },
            // Gemini 4 Hydrogen switched on, thinking at its default (Medium), and hands-free's model; Flash at Low.
            hub("hub-models-hydrogen", .models, height: 1100) { c in
                c.settings.lineup.setSwitchable(.hydrogen, true)
                c.settings.handsFreeModel = .hydrogen
                c.settings.reasoningEfforts[.geminiFlash] = .low
            },
            // Gemini 4 Hydrogen as the main model: GigaAM gets a switch, and GigaAM and Flash stay in the cycle.
            hub("hub-models-main-hydrogen", .models, height: 1100) { c in
                c.settings.lineup.main = .hydrogen
            },
            // Gemini 4 Neon switched on beside Hydrogen, thinking at its default (Low), and hands-free's model: the two
            // new colors side by side.
            hub("hub-models-neon", .models, height: 1200) { c in
                c.settings.lineup.setSwitchable(.hydrogen, true)
                c.settings.lineup.setSwitchable(.neon, true)
                c.settings.handsFreeModel = .neon
            },
            // Gemini 4 Neon as the main model: GigaAM gets a switch, and GigaAM and Flash stay in the cycle.
            hub("hub-models-main-neon", .models, height: 1200) { c in
                c.settings.lineup.main = .neon
            },
            hub("hub-models-downloading", .models) { c in
                c.models = .preview(states: [.gigaam: .downloading(Samples.downloading)])
            },
            // GigaAM v3 (`--only hub-models-gigaam`): the main model not downloaded (an update from Parakeet, which it
            // took the place of), its zip coming in, loading; ready but unused (Delete), in use (switched on and
            // hands-free's) beside Gemini as the main model.
            hub("hub-models-gigaam-not-downloaded", .models, height: 1080) { c in
                c.models = .preview(states: [.gigaam: .notInstalled], settings: c.settings)
            },
            hub("hub-models-gigaam-downloading", .models, height: 1080) { c in
                c.models = .preview(states: [.gigaam: .downloading(Samples.gigaamDownloading)], settings: c.settings)
            },
            hub("hub-models-gigaam-preparing", .models, height: 1080) { c in
                c.models = .preview(states: [.gigaam: .preparing(since: Date().addingTimeInterval(-3))],
                                    settings: c.settings)
            },
            hub("hub-models-gigaam-ready", .models, height: 1080) { c in
                c.settings.lineup.main = .gemini
                c.settings.lineup.setSwitchable(.gigaam, false)
            },
            hub("hub-models-gigaam-in-use", .models, height: 1080) { c in
                c.settings.lineup.main = .gemini
                c.settings.lineup.setSwitchable(.gigaam, true)
                c.settings.handsFreeModel = .gigaam
            },
            hub("hub-models-gigaam-not-published", .models, height: 1080) { c in
                let file = GigaAMEngine.Variant.v3.zipName
                c.models = .preview(
                    states: [.gigaam: .failed("Not published yet. Put \(file) in your Downloads folder, then Retry.")],
                    lastErrors: [.gigaam: .modelNotPublished(.gigaam, file: file)], settings: c.settings)
            },
            // What the retired models left on this Mac (`--only hub-models-leftovers`): Parakeet, GigaAM v3 e2e and
            // Multilingual, each with its size, "No longer used" and Delete, and the footer that says so. Then one
            // left, GigaAM v3 still downloading; and the narrowest window.
            hub("hub-models-leftovers", .models, height: 1300) { c in
                c.models = .preview(states: [.gigaam: .ready], leftovers: Samples.leftovers, settings: c.settings)
            },
            hub("hub-models-leftovers-one", .models, height: 1180) { c in
                c.models = .preview(states: [.gigaam: .downloading(Samples.gigaamDownloading)],
                                    leftovers: [.parakeet: Samples.leftovers[.parakeet] ?? 0], settings: c.settings)
            },
            hub("hub-models-leftovers-compact", .models, width: 820, height: 1300) { c in
                c.models = .preview(states: [.gigaam: .ready], leftovers: Samples.leftovers, settings: c.settings)
            },
            hub("hub-models-preparing", .models) { c in
                c.models = .preview(states: [.gigaam: .preparing(since: Date().addingTimeInterval(-24))])
            },
            hub("hub-models-failed", .models) { c in
                c.models = .preview(states: [.gigaam: .failed("Download didn’t finish. The connection was lost.")],
                                    lastErrors: [.gigaam: .downloadFailed(.gigaam, "The connection was lost.")])
            },
            hub("hub-models-load-failed", .models) { c in
                c.models = .preview(states: [.gigaam: .failed("Couldn’t load the model. Retry, or download it again.")],
                                    lastErrors: [.gigaam: .modelLoadFailed(.gigaam, "Corrupt weights")])
            },
            hub("hub-home-load-failed", .home) { c in
                c.models = .preview(states: [.gigaam: .failed("Couldn’t load the model. Retry, or download it again.")],
                                    lastErrors: [.gigaam: .modelLoadFailed(.gigaam, "Corrupt weights")])
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
            // Gemini as the main model: its row takes the radio and "Main", and GigaAM gets a switch.
            hub("hub-models-main-gemini", .models, height: 1100) { c in
                c.settings.lineup.main = .gemini
            },
            // Gemini 4 Carbon as the main model: GigaAM gets a switch, and GigaAM and Flash stay in the cycle.
            hub("hub-models-main-carbon", .models, height: 1100) { c in
                c.settings.lineup.main = .carbon
            },
            // Dragged into Gemini, GigaAM: the line follows the new order from the main model.
            hub("hub-models-reordered", .models, height: 1100) { c in
                c.settings.lineup.move(.gemini, to: 0)
            },
            // Only the main model takes part: the line says how to reach another.
            hub("hub-models-only-main", .models, height: 1100) { c in
                c.settings.lineup.setSwitchable(.gemini, false)
            },
            // Colors picked in Models: every tile wears its model's, the GigaAM on this Mac tile and the sidebar chip
            // GigaAM's.
            hub("hub-models-colors", .models, height: 1100, configure: Samples.pickColors),
            // History's marks in the picked colors.
            hub("hub-home-model-colors", .home, configure: Samples.pickColors),
            // Each model's colors as its tile opens them (a popover doesn't render in a page snapshot), in its default
            // color.
            SnapshotEntry("hub-model-color-picker",
                          width: CGFloat(ModelChoice.allCases.count) * ModelColorPopover.width
                              + CGFloat(ModelChoice.allCases.count + 1) * 24,
                          height: 230) { _ in
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
            // Push to talk on F5: hands-free and the keys used while dictating are pressed off it (F5 Space, F5 D…).
            hub("hub-shortcuts-talk-key", .shortcuts, height: 860) { c in
                c.settings.shortcuts = ShortcutRecorderSnapshots.movedToF5.bindings
            },
            // Push to talk just changed from fn to F5: the others went along, and the line under it says so.
            hub("hub-shortcuts-talk-key-moved", .shortcuts, height: 860,
                recorderMessages: ShortcutRecorderSnapshots.movedToF5.message.map { [.pushToTalk: $0] } ?? [:]) { c in
                c.settings.shortcuts = ShortcutRecorderSnapshots.movedToF5.bindings
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
            // Pasting set per model: quick GigaAM searches go in bare, the Geminis get a space after.
            hub("hub-general", .general, height: 1080) { c in
                c.settings.modelsAddingSpace = [.gemini, .hydrogen, .neon, .carbon]
                c.settings.modelsRemovingFinalPeriod = [.gigaam]
                c.settings.modesRemovingFinalPeriod = [.pushToTalk]
            },
            // The whole page, down to Troubleshooting's Export Logs….
            hub("hub-general-full", .general, height: 1600),
            // Pasting's "Hold the paste after a click" (`--only hub-general-hold-paste`): on (the default), and off.
            hub("hub-general-hold-paste", .general, height: 900),
            hub("hub-general-hold-paste-off", .general, height: 900) { c in
                c.settings.holdsPasteAfterClick = false
            },
            // The whole page down to Experimental at the bottom: Race requests on 2.
            hub("hub-general-experimental", .general, height: 1700) { c in
                c.settings.raceRequests = .two
            },
            // The narrowest window: the segmented control leaves the least room for the pill caption; sounds off.
            hub("hub-general-compact", .general, width: 820, height: 560) { c in
                c.settings.pillMode = .always
                c.settings.soundsEnabled = false
            },
            // The narrowest window: Pasting's chips still fit under each rule, a column for each of the five models.
            hub("hub-general-pasting-compact", .general, width: 820, height: 1080) { c in
                c.settings.modelsAddingSpace = [.gemini, .hydrogen, .neon, .carbon]
                c.settings.modelsRemovingFinalPeriod = [.gigaam]
                c.settings.modesRemovingFinalPeriod = [.pushToTalk]
            },
            hub("hub-general-permissions", .general, height: 1600) { c in
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

    /// A row's Versions menu as it opens (`VersionsMenuDrawing`), for `entry` with the models in `models`.
    private static func menu(_ name: String, entry: TranscriptEntry,
                             models: [EngineID: LocalModelState]) -> SnapshotEntry {
        SnapshotEntry(name: name, size: CGSize(width: 520, height: 460)) { env in
            let context = HubContext(env: env)
            context.models = .preview(states: models, settings: context.settings)
            return AnyView(VersionsMenuDrawing(menu: context.versionsMenu(for: entry)))
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

        /// Colors other than the defaults, one each: GigaAM teal, Gemini blue.
        @MainActor static func pickColors(_ context: HubContext) {
            context.settings.modelColors[.gigaam] = .teal
            context.settings.modelColors[.gemini] = .blue
            context.settings.modelColors[.carbon] = .orange
        }

        @MainActor static func updates(_ context: HubContext, releases: [Release] = PreviewFixtures.releases(),
                                       isChecking: Bool = false, checkError: UpdateCheckError? = nil,
                                       install: UpdateCenter.InstallPhase = .idle) -> UpdateCenter {
            context.fixedNow = checkedAt.addingTimeInterval(5 * 60)
            return .preview(settings: context.settings, toasts: context.toasts, releases: releases,
                            lastChecked: checkedAt, isChecking: isChecking, checkError: checkError, install: install)
        }

        static let downloading = DownloadProgress(fraction: 0.42, bytesReceived: 171_900_000, totalBytes: 409_369_862,
                                                  bytesPerSecond: 9_800_000, secondsRemaining: 24)
        /// GigaAM v3's zip coming in from the release.
        static let gigaamDownloading = DownloadProgress(fraction: 0.37, bytesReceived: 151_500_000,
                                                        totalBytes: 409_369_862, bytesPerSecond: 8_200_000,
                                                        secondsRemaining: 31)
        /// What the retired models leave on disk: Parakeet's files, GigaAM v3 e2e's and Multilingual's unpacked zips.
        static let leftovers: [RetiredLocalModel: Int64] = [.parakeet: 632_400_000, .gigaamV3e2e: 443_698_324,
                                                            .gigaamMultilingual: 1_173_144_132]

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

        /// Dictations by Gemini 4 Carbon: a transcript at its default Low, and a polish.
        static func carbonEntries() -> [TranscriptEntry] {
            let now = Date()
            func entry(_ text: String, _ kind: TranscriptVersionKind, ago: TimeInterval) -> TranscriptEntry {
                var result = TranscriptResult(text: text, engine: kind.engine, processingTime: 9.4)
                result.reasoningEffort = .low
                return TranscriptEntry(createdAt: now.addingTimeInterval(-ago), engine: kind.engine,
                                       audioDuration: 21.3, voicedSeconds: 18.2, audioFileName: "carbon.m4a",
                                       versions: [result.version(kind)])
            }
            return [
                entry("Let’s keep Carbon on for a few days and compare it with Flash on the long dictations.",
                      .transcription(.geminiCarbon), ago: 40),
                entry("Could you send the draft by Thursday? I’d like to go through it before the review.",
                      .polish(by: .geminiCarbon), ago: 150),
            ]
        }

        /// Dictations by Gemini 4 Hydrogen: a transcript at its default Medium, and a polish.
        static func hydrogenEntries() -> [TranscriptEntry] {
            let now = Date()
            func entry(_ text: String, _ kind: TranscriptVersionKind, ago: TimeInterval) -> TranscriptEntry {
                var result = TranscriptResult(text: text, engine: kind.engine, processingTime: 6.1)
                result.reasoningEffort = .medium
                return TranscriptEntry(createdAt: now.addingTimeInterval(-ago), engine: kind.engine,
                                       audioDuration: 48.6, voicedSeconds: 41.9, audioFileName: "hydrogen.m4a",
                                       versions: [result.version(kind)])
            }
            return [
                entry("Hydrogen came back in six seconds on a long one, so let’s see how it does on the rest this week.",
                      .transcription(.geminiHydrogen), ago: 40),
                entry("Can we move the call to Friday morning? Thursday is full of reviews for me.",
                      .polish(by: .geminiHydrogen), ago: 150),
            ]
        }

        /// Dictations by Gemini 4 Neon: a transcript at its default Low, and a polish.
        static func neonEntries() -> [TranscriptEntry] {
            let now = Date()
            func entry(_ text: String, _ kind: TranscriptVersionKind, ago: TimeInterval) -> TranscriptEntry {
                var result = TranscriptResult(text: text, engine: kind.engine, processingTime: 7.8)
                result.reasoningEffort = .low
                return TranscriptEntry(createdAt: now.addingTimeInterval(-ago), engine: kind.engine,
                                       audioDuration: 36.2, voicedSeconds: 30.4, audioFileName: "neon.m4a",
                                       versions: [result.version(kind)])
            }
            return [
                entry("Let’s try Neon on the long ones next to Carbon and see whether it’s worth the price.",
                      .transcription(.geminiNeon), ago: 40),
                entry("I’ll send the slides tonight, so we can go through them first thing tomorrow.",
                      .polish(by: .geminiNeon), ago: 150),
            ]
        }

        /// A dictation with English terms in Russian speech, as Parakeet wrote it, then each GigaAM version, from before
        /// Parakeet, v3 e2e and Multilingual were retired: v3 hears the terms in Cyrillic, e2e and Multilingual mangle
        /// them. v3's is current. `parakeetOnly`: before any of them.
        static func gigaamCompareEntry(parakeetOnly: Bool = false) -> TranscriptEntry {
            let created = Date().addingTimeInterval(-25 * 60)
            func version(_ kind: TranscriptVersionKind, _ text: String, _ seconds: Double) -> TranscriptVersion {
                TranscriptVersion(kind: kind, text: text,
                                  metadata: TranscriptMetadata(createdAt: created, modelID: kind.gigaamVariant?.rawValue,
                                                               processingTime: seconds))
            }
            let parakeet = version(.transcription(.parakeet),
                                   "Открой Chrome DevTools MCP и проверь, что Claude Code видит вкладку.", 0.4)
            let versions = parakeetOnly ? [parakeet] : [
                parakeet,
                version(.gigaam(.v3e2e), "Открой hrome Deftuls MCP и проверь, что Clod Code видит вкладку.", 0.36),
                version(.gigaam(.multilingual), "открой chrome devtuls mcp и проверь что clod chr видит вкладку", 0.59),
                version(.gigaam(.v3), "открой хром девтулс эм си пи и проверь что клод код видит вкладку", 0.35),
            ]
            return TranscriptEntry(id: UUID(uuidString: "7D3A4E6A-0000-4A7B-9C3D-5E6F7A8B9C01")!, createdAt: created,
                                   engine: .parakeet, audioDuration: 6.4, voicedSeconds: 5.6,
                                   audioFileName: "compare.m4a", versions: versions)
        }

        /// Dictations by GigaAM on this Mac: one by the retired v3 e2e (punctuation, digits), one by v3 (plain).
        static func gigaamEntries() -> [TranscriptEntry] {
            let now = Date()
            func entry(_ text: String, _ variant: GigaAMEngine.Variant, ago: TimeInterval,
                       seconds: TimeInterval) -> TranscriptEntry {
                var result = TranscriptResult(text: text, engine: .gigaam, processingTime: 0.36)
                result.modelID = variant.rawValue
                return TranscriptEntry(createdAt: now.addingTimeInterval(-ago), engine: .gigaam,
                                       audioDuration: seconds, voicedSeconds: seconds * 0.85,
                                       audioFileName: "gigaam.m4a", versions: [result.version()])
            }
            return [
                entry("Созвонимся в четверг в 11:30, я пришлю ссылку.", .v3e2e, ago: 35, seconds: 4.2),
                entry("давай перенесём ревью на пятницу к этому времени допишу тесты", .v3, ago: 120, seconds: 6.8),
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
        /// second, and Parakeet · Cloud on the third and GigaAM v3 on the failed row, whose recordings couldn't be read.
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
                failures[failed.id] = .recordingGone(.gigaam(.v3))
            }
            return failures
        }

        /// `kind` didn't come because of `error`, as the controller says it.
        static func homeFailure(_ kind: TranscriptVersionKind, _ error: AppError) -> HomeFailure {
            HomeFailure(kind: kind, reason: DictationController.homeFailureReason(error, making: kind))
        }
    }
}

/// A row's Versions menu drawn as it opens, for snapshots (a menu doesn't render in one): what's running, the versions
/// with the current one checked, then Transcribe With (or Retry With), unavailable items dimmed with their reason. The
/// items are `VersionsMenuItems`' own, from the same `VersionsMenu`.
private struct VersionsMenuDrawing: View {
    var menu: VersionsMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let running = menu.runningTitle { item(running, enabled: false) }
            if !menu.versions.isEmpty {
                header(VersionsMenu.versionsSectionTitle)
                ForEach(menu.versions) { version in
                    item(version.itemTitle, checked: version.isCurrent)
                }
            }
            if !menu.actions.isEmpty {
                if !menu.versions.isEmpty { Divider().padding(.vertical, 5).padding(.horizontal, 10) }
                header(menu.isRetry ? menu.title : VersionsMenu.actionsSectionTitle)
                ForEach(menu.actions) { action in
                    item(action.title, symbol: "waveform", enabled: action.isEnabled)
                }
            }
        }
        .padding(5)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.stroke, lineWidth: 0.5) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.bgCanvas)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.inkTertiary)
            .padding(.horizontal, 10)
            .frame(height: 22, alignment: .leading)
    }

    private func item(_ title: String, checked: Bool = false, symbol: String? = nil, enabled: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(checked ? 1 : 0)
                .frame(width: 14)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
            }
            Text(title).font(.system(size: 13)).lineLimit(1)
        }
        .foregroundStyle(enabled ? Color.ink : Color.inkTertiary)
        .padding(.horizontal, 8)
        .frame(height: 24, alignment: .leading)
    }
}

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
            hub("hub-models-compact-cloud", .models, width: 820, height: 1100) { c in
                c.settings.parakeetEngine = .parakeetCloud
            },
            hub("hub-home-search", .home) { c in
                c.initialSearch = "zzz"
            },
            // The newest row hovered: Copy, the "…" row menu (Versions) and Delete.
            hub("hub-home-row-menu", .home, height: 900) { c in
                c.previewHoveredEntry = c.history.entries.first?.id
            },
            // Home work under way, each with its × to cancel it: a clean-up on the newest row, Gemini Flash
            // transcribing the second, a Retry on the failed one.
            hub("hub-home-transcribing", .home, height: 900) { c in
                let entries = c.history.entries
                var running: [UUID: TranscriptVersionKind] = [:]
                if let first = entries.first { running[first.id] = .cleanup(of: .parakeet, by: .default) }
                if entries.count > 1 { running[entries[1].id] = .transcription(.geminiFlash) }
                if let failed = entries.first(where: { $0.status == .failed }) { running[failed.id] = .transcription(.parakeet) }
                c.previewRunning = running
            },
            // Home work that didn't come, said in its row with Retry and a × to dismiss it: Gemini Flash took too long
            // on the newest row, a clean-up failed on the second. The third's recording couldn't be read (nothing to
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
                let cleanUp = TranscriptVersionKind.cleanup(of: .parakeet, by: .default)
                c.previewFailures = [
                    entries[0].id: Samples.homeFailure(cleanUp, .openRouterProviderUnavailable("")),
                    entries[2].id: Samples.homeFailure(.transcription(.parakeetCloud), .timeout(.parakeetCloud)),
                ]
                var running = [entries[1].id: TranscriptVersionKind.transcription(.geminiFlash)]
                if let failed = entries.first(where: { $0.status == .failed }) { running[failed.id] = .transcription(.parakeet) }
                c.previewRunning = running
            },

            hub("hub-models", .models),
            hub("hub-models-full", .models, height: 1080),
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
            hub("hub-models-cloud-stt", .models, height: 1100) { c in
                c.settings.parakeetEngine = .parakeetCloud
            },
            hub("hub-models-key-limit", .models, height: 1100) { c in
                c.settings.parakeetEngine = .parakeetCloud
                c.account = .preview(status: .noCredit(KeyInfo(label: "transcribe-thing", limit: 5, limitRemaining: 0, usage: 5)))
            },
            hub("hub-models-key-invalid", .models, height: 1100) { c in
                c.account = .preview(status: .invalid("401"))
            },
            hub("hub-models-key-missing", .models, height: 1100) { c in
                c.account = .preview(status: .missing)
            },
            // Switch model rebound to right ⌘, clean-up left out: the line above the lineup shows the real binding.
            hub("hub-models-extra-custom", .models, height: 1100) { c in
                c.settings.shortcuts[.switchModel] = .rightCommand
                c.settings.lineup.setSwitchable(.cleanup, false)
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
            // Clean-up as the main model, with Parakeet through OpenRouter.
            hub("hub-models-main-cleanup-cloud", .models, height: 1100) { c in
                c.settings.parakeetEngine = .parakeetCloud
                c.settings.lineup.main = .cleanup
            },
            // Dragged into Gemini, clean-up, Parakeet: the line follows the new order from the main model.
            hub("hub-models-reordered", .models, height: 1100) { c in
                c.settings.lineup.move(.gemini, to: 0)
                c.settings.lineup.move(.cleanup, to: 1)
            },
            // Only the main model takes part: the line says how to reach another.
            hub("hub-models-only-main", .models, height: 1100) { c in
                c.settings.lineup.setSwitchable(.cleanup, false)
                c.settings.lineup.setSwitchable(.gemini, false)
            },
            // Colors picked in Models: every tile wears its model's, the Where Parakeet runs tiles and the sidebar chip
            // Parakeet's.
            hub("hub-models-colors", .models, height: 1100, configure: Samples.pickColors),
            // History's marks in the picked colors.
            hub("hub-home-model-colors", .home, configure: Samples.pickColors),
            // Each model's colors as its tile opens them (a popover doesn't render in a page snapshot), in its default
            // color.
            SnapshotEntry("hub-model-color-picker", width: 3 * ModelColorPopover.width + 4 * 24, height: 230) { _ in
                HStack(alignment: .top, spacing: 24) {
                    ForEach(ModelChoice.allCases) { choice in
                        ModelColorPopover(choice: choice, parakeet: .parakeet, color: choice.defaultColor) { _ in }
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

            hub("hub-general", .general, height: 1080),
            // The narrowest window: the segmented control leaves the least room for the pill caption; sounds off.
            hub("hub-general-compact", .general, width: 820, height: 560) { c in
                c.settings.pillMode = .always
                c.settings.soundsEnabled = false
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

        /// Colors other than the defaults, one each: Parakeet teal, clean-up pink, Gemini blue.
        @MainActor static func pickColors(_ context: HubContext) {
            context.settings.modelColors[.parakeet] = .teal
            context.settings.modelColors[.cleanup] = .pink
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

        /// Home work that didn't come, in the words the controller uses: Gemini Flash on the newest row, a clean-up of
        /// cloud Parakeet on the second, and Parakeet · Cloud on the third and Parakeet on the failed row, whose
        /// recordings couldn't be read.
        static func homeFailures(_ entries: [TranscriptEntry], keyMissing: Bool = false) -> [UUID: HomeFailure] {
            var failures: [UUID: HomeFailure] = [:]
            if let first = entries.first {
                failures[first.id] = homeFailure(.transcription(.geminiFlash),
                                                 keyMissing ? .openRouterMissingKey : .timeout(.geminiFlash))
            }
            if entries.count > 1 {
                failures[entries[1].id] = homeFailure(.cleanup(of: .parakeetCloud, by: .default),
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

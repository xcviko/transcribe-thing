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
                c.settings.selectedEngine = .parakeetCloud
            },
            hub("hub-home-search", .home) { c in
                c.initialSearch = "zzz"
            },

            hub("hub-models", .models),
            hub("hub-models-full", .models, height: 1320),
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
                c.settings.selectedEngine = .parakeetCloud
            },
            hub("hub-models-key-limit", .models, height: 1100) { c in
                c.settings.selectedEngine = .geminiFlash
                c.account = .preview(status: .noCredit(KeyInfo(label: "transcribe-thing", limit: 5, limitRemaining: 0, usage: 5)))
            },
            hub("hub-models-key-invalid", .models, height: 1100) { c in
                c.settings.selectedEngine = .geminiFlash
                c.account = .preview(status: .invalid("401"))
            },
            hub("hub-models-key-missing", .models, height: 1100) { c in
                c.account = .preview(status: .missing)
                c.settings.geminiSystemPrompt = "Transcribe the audio verbatim. Output only the transcript."
            },

            hub("hub-shortcuts", .shortcuts, height: 860),
            // Hands-free just recorded as ⌃⌥Space: saved, with macOS's input-source shortcut as the warning.
            hub("hub-shortcuts-warning", .shortcuts, height: 940,
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
                c.settings.preferBuiltInMicOverBluetooth = false
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

        @MainActor static func updates(_ context: HubContext, releases: [Release] = PreviewFixtures.releases(),
                                       isChecking: Bool = false, checkError: UpdateCheckError? = nil,
                                       install: UpdateCenter.InstallPhase = .idle) -> UpdateCenter {
            context.fixedNow = checkedAt.addingTimeInterval(5 * 60)
            return .preview(settings: context.settings, toasts: context.toasts, releases: releases,
                            lastChecked: checkedAt, isChecking: isChecking, checkError: checkError, install: install)
        }

        static let downloading = DownloadProgress(fraction: 0.42, bytesReceived: 265_600_000, totalBytes: 632_321_326,
                                                  bytesPerSecond: 9_800_000, secondsRemaining: 38)
    }
}

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
            // A pill hidden from the menu bar ("Show Now"), sounds off.
            hub("hub-general-pill-hidden", .general) { c in
                c.fixedNow = Samples.now
                c.settings.pillMode = .always
                c.settings.hidePill(now: Samples.now)
                c.settings.soundsEnabled = false
            },
            // The narrowest window: "Show Now" + the segmented control leave the least room for the caption.
            hub("hub-general-pill-hidden-compact", .general, width: 820, height: 560) { c in
                c.fixedNow = Samples.now
                c.settings.pillMode = .always
                c.settings.hidePill(now: Samples.now)
            },
            hub("hub-general-permissions", .general, height: 1080) { c in
                c.permissions = .preview(mic: .granted, ax: .denied)
                c.launchAtLogin = .preview()
            },
        ]
    }

    private static func hub(_ name: String, _ section: HubSection, width: CGFloat = 980, height: CGFloat = 680,
                            configure: @escaping @MainActor (HubContext) -> Void = { _ in }) -> SnapshotEntry {
        SnapshotEntry(name: name, size: CGSize(width: width, height: height)) { env in
            env.windows.hubSection = section
            let context = HubContext(env: env)
            context.drawsWindowControls = true
            context.firstName = "Sam"
            configure(context)
            return AnyView(HubView(context: context))
        }
    }

    private enum Samples {
        /// 2:40 PM today, so the hidden pill reads "Back at 3:40 PM".
        static var now: Date {
            Calendar.current.date(bySettingHour: 14, minute: 40, second: 0, of: Date()) ?? Date()
        }
        static let downloading = DownloadProgress(fraction: 0.42, bytesReceived: 265_600_000, totalBytes: 632_321_326,
                                                  bytesPerSecond: 9_800_000, secondsRemaining: 38)
    }
}

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
                c.settings.selectedEngine = .whisper
                c.models = .preview(states: [.parakeet: .ready, .whisper: .downloading(Samples.downloading)])
            },
            hub("hub-home-compact", .home, width: 820, height: 560),
            hub("hub-models-compact", .models, width: 820, height: 560) { c in
                c.models = .preview(states: [.parakeet: .ready, .whisper: .downloading(Samples.downloading)])
            },
            hub("hub-home-search", .home) { c in
                c.initialSearch = "zzz"
            },

            hub("hub-models", .models),
            hub("hub-models-full", .models, height: 1560),
            hub("hub-models-downloading", .models) { c in
                c.models = .preview(states: [.parakeet: .ready, .whisper: .downloading(Samples.downloading)])
            },
            hub("hub-models-preparing", .models) { c in
                c.settings.selectedEngine = .whisper
                c.models = .preview(states: [.parakeet: .installed, .whisper: .preparing(since: Date().addingTimeInterval(-34))])
            },
            hub("hub-models-failed", .models) { c in
                c.models = .preview(states: [.parakeet: .ready, .whisper: .failed("Download didn’t finish. The connection was lost.")])
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
            hub("hub-shortcuts-secure", .shortcuts) { c in
                c.secureInput = .preview(active: true, owningAppName: "1Password")
            },

            hub("hub-pill", .pillAndSounds, height: 860),
            hub("hub-pill-handsfree", .pillAndSounds) { c in
                c.initialPillPreview = .locked
            },
            hub("hub-pill-hidden", .pillAndSounds, height: 860) { c in
                c.settings.pillMode = .always
                c.settings.hidePill(now: Date())
                c.settings.soundsEnabled = false
            },

            hub("hub-microphone", .microphone),
            hub("hub-microphone-bluetooth", .microphone) { c in
                c.settings.microphoneUID = "preview-airpods"
                c.settings.preferBuiltInMicOverBluetooth = false
            },

            hub("hub-general", .general, height: 1060),
            hub("hub-general-permissions", .general, height: 1060) { c in
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
        static let downloading = DownloadProgress(fraction: 0.42, bytesReceived: 264_500_000, totalBytes: 629_700_000,
                                                  bytesPerSecond: 9_800_000, secondsRemaining: 38)
    }
}

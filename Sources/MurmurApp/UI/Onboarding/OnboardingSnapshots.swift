import SwiftUI

/// Every onboarding step, plus the sub-states worth checking by eye.
enum OnboardingSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [
            entry("onboarding-1-welcome", still: 2.25) { model in model.stage(step: .welcome) },

            entry("onboarding-2-permissions", context: { ctx in
                ctx.permissions = .preview(mic: .notDetermined, ax: .notDetermined)
            }) { model in
                model.stage(step: .permissions)
                model.fnKeyUsageOverride = .other("Emoji & Symbols")
            },
            entry("onboarding-2-permissions-partial", context: { ctx in
                ctx.permissions = .preview(mic: .granted, ax: .notDetermined)
            }) { model in
                model.stage(step: .permissions)
                model.accessibilityStaleOverride = true
            },
            entry("onboarding-2-permissions-granted") { model in model.stage(step: .permissions) },

            entry("onboarding-3-model", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .notInstalled, .whisper: .notInstalled])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-downloading", context: { ctx in
                ctx.models = .preview(states: [
                    .parakeet: .downloading(DownloadProgress(fraction: 0.335, bytesReceived: 212_000_000,
                                                             totalBytes: 632_321_326, bytesPerSecond: 14_000_000,
                                                             secondsRemaining: 30)),
                    .whisper: .notInstalled,
                ])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-optimizing", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .ready, .whisper: .preparing(since: Date().addingTimeInterval(-34))])
                ctx.settings.selectedEngine = .whisper
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-disk", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .notInstalled, .whisper: .ready])
                ctx.account = .preview(status: .missing)
            }) { model in
                model.stage(step: .model)
                model.stageDisk(free: 412_000_000)
            },
            entry("onboarding-3-model-cloud-valid", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .ready, .whisper: .notInstalled])
                ctx.settings.selectedEngine = .geminiFlash
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-cloud-invalid", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .notInstalled, .whisper: .notInstalled])
                ctx.settings.selectedEngine = .geminiPro
                ctx.account = .preview(status: .invalid("401"))
            }) { model in
                model.stage(step: .model)
                model.stageKey(draft: "sk-or-v1-...", replacing: true)
            },

            entry("onboarding-4-shortcuts", still: 0.4) { model in model.stage(step: .shortcuts) },
            entry("onboarding-4-shortcuts-fn", still: 1.3) { model in
                model.stage(step: .shortcuts)
                model.stagePressed([.fn], heldPTT: true)
            },
            entry("onboarding-4-shortcuts-handsfree", still: 1.7) { model in
                model.stage(step: .shortcuts)
                model.stagePressed([.fn, .space], heldPTT: true, triedHandsFree: true, latched: true)
            },

            entry("onboarding-5-tryit") { model in model.stage(step: .tryIt) },
            entry("onboarding-5-tryit-success") { model in
                model.stage(step: .tryIt)
                model.stagePractice(
                    messages: [
                        ChatMessage(sender: .alex, text: OnboardingModel.alexOpening),
                        ChatMessage(sender: .me, text: "Heading to the studio to finish the onboarding designs, then a quick run before dinner."),
                        ChatMessage(sender: .alex, text: OnboardingModel.alexAfterFirst),
                    ],
                    completed: [.pushToTalk],
                    stat: PracticeStat(words: 18, seconds: 6.2))
            },
            entry("onboarding-5-tryit-downloading", context: { ctx in
                ctx.models = .preview(states: [
                    .parakeet: .downloading(DownloadProgress(fraction: 0.62, bytesReceived: 392_000_000,
                                                             totalBytes: 632_321_326, secondsRemaining: 18)),
                    .whisper: .notInstalled,
                ])
            }) { model in model.stage(step: .tryIt) },

            entry("onboarding-6-done", still: 0.42) { model in model.stage(step: .done) },
        ]
    }

    @MainActor private static func entry(_ name: String, still: Double = 1.0,
                                         context: @escaping @MainActor (inout OnboardingContext) -> Void = { _ in },
                                         configure: @escaping @MainActor (OnboardingModel) -> Void) -> SnapshotEntry {
        SnapshotEntry(name, width: OnboardingLayout.window.width, height: OnboardingLayout.window.height) { env in
            var ctx = OnboardingContext(env: env)
            // A fresh install, not the preview fixture's completed setup.
            ctx.settings.onboardingCompleted = false
            ctx.freeDiskBytes = { 212_400_000_000 }
            context(&ctx)
            let model = OnboardingModel(context: ctx)
            configure(model)
            return OnboardingView(model: model).environment(\.onboardingStillTime, still)
        }
    }
}

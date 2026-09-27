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
                ctx.models = .preview(states: [.parakeet: .notInstalled])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-downloading", context: { ctx in
                ctx.models = .preview(states: [
                    .parakeet: .downloading(DownloadProgress(fraction: 0.335, bytesReceived: 212_000_000,
                                                             totalBytes: 632_321_326, bytesPerSecond: 14_000_000,
                                                             secondsRemaining: 30)),
                ])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-ready", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .ready])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-optimizing", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .preparing(since: Date().addingTimeInterval(-24))])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-load-failed", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .failed("Couldn’t load the model. Retry, or download it again.")],
                                      lastErrors: [.parakeet: .modelLoadFailed(.parakeet, "Corrupt weights")])
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-disk", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .notInstalled])
                ctx.account = .preview(status: .missing)
            }) { model in
                model.stage(step: .model)
                model.stageDisk(free: 412_000_000)
            },
            entry("onboarding-3-model-cloud-valid", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .ready])
                ctx.settings.selectedEngine = .parakeetCloud
            }) { model in model.stage(step: .model) },
            // Switch model rebound to right ⌘: the Gemini line names it.
            entry("onboarding-3-model-custom-switch", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .ready])
                ctx.settings.shortcuts[.switchModel] = .rightCommand
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-cloud-stt", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .ready])
                ctx.settings.selectedEngine = .parakeetCloud
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-cloud-stt-missing", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .notInstalled])
                ctx.settings.selectedEngine = .parakeetCloud
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .model) },
            entry("onboarding-3-model-cloud-invalid", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .notInstalled])
                ctx.settings.selectedEngine = .parakeetCloud
                ctx.account = .preview(status: .invalid("401"))
            }) { model in
                model.stage(step: .model)
                model.stageKey(draft: "sk-or-v1-...", replacing: true)
            },

            entry("onboarding-4-tryit") { model in model.stage(step: .tryIt) },
            // No working key: the optional "Switch to Gemini" row stays hidden.
            entry("onboarding-4-tryit-no-key", context: { ctx in
                ctx.account = .preview(status: .missing)
            }) { model in model.stage(step: .tryIt) },
            entry("onboarding-4-tryit-fn", still: 1.3) { model in
                model.stage(step: .tryIt)
                model.stagePressed([.fn], heldPTT: true)
            },
            entry("onboarding-4-tryit-success") { model in
                model.stage(step: .tryIt)
                model.stagePractice(messages: firstExchange, completed: [.pushToTalk],
                                    stat: PracticeStat(words: 18, seconds: 6.2))
            },
            entry("onboarding-4-tryit-handsfree", still: 1.7) { model in
                model.stage(step: .tryIt)
                model.stagePractice(messages: firstExchange, completed: [.pushToTalk],
                                    stat: PracticeStat(words: 18, seconds: 6.2))
                model.stagePressed([.fn, .space], heldPTT: true, triedHandsFree: true, latched: true)
            },
            entry("onboarding-4-tryit-complete") { model in
                model.stage(step: .tryIt)
                model.stagePractice(
                    messages: firstExchange + [
                        ChatMessage(sender: .me, text: "Probably the farmers market in the morning and then a long lunch with Sam."),
                        ChatMessage(sender: .alex, text: OnboardingModel.alexAfterSecond),
                        ChatMessage(sender: .note, text: OnboardingModel.cancelNote),
                    ],
                    completed: [.pushToTalk, .handsFree, .cancel],
                    stat: PracticeStat(words: 16, seconds: 4.9))
            },
            entry("onboarding-4-tryit-hands-free-hint") { model in
                model.stage(step: .tryIt)
                model.stagePractice(
                    messages: firstExchange + [
                        ChatMessage(sender: .me, text: "Probably the farmers market in the morning."),
                        ChatMessage(sender: .alex, text: OnboardingModel.alexAfterSecond),
                    ],
                    completed: [.pushToTalk], stat: PracticeStat(words: 7, seconds: 2.4), hint: .tryHandsFree)
            },
            entry("onboarding-4-tryit-keyboard-hint") { model in
                model.stage(step: .tryIt)
                model.stageKeyboardHint(true)
            },
            entry("onboarding-4-tryit-preparing", context: { ctx in
                ctx.models = .preview(states: [.parakeet: .preparing(since: Date().addingTimeInterval(-12))])
            }) { model in model.stage(step: .tryIt) },
            entry("onboarding-4-tryit-downloading", context: { ctx in
                ctx.models = .preview(states: [
                    .parakeet: .downloading(DownloadProgress(fraction: 0.62, bytesReceived: 392_000_000,
                                                             totalBytes: 632_321_326, secondsRemaining: 18)),
                ])
            }) { model in
                model.stage(step: .tryIt)
                model.stagePressed([.fn], heldPTT: true)
            },

            entry("onboarding-5-done", still: 0.42) { model in model.stage(step: .done) },
            entry("onboarding-5-done-cloud", still: 0.42, context: { ctx in
                ctx.settings.selectedEngine = .parakeetCloud
            }) { model in model.stage(step: .done) },
        ]
    }

    @MainActor private static var firstExchange: [ChatMessage] {
        [
            ChatMessage(sender: .alex, text: OnboardingModel.alexOpening),
            ChatMessage(sender: .me, text: "Heading to the studio to finish the onboarding designs, then a quick run before dinner."),
            ChatMessage(sender: .alex, text: OnboardingModel.alexAfterFirst),
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

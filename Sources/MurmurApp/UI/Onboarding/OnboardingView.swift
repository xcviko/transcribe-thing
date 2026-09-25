import SwiftUI

// STUB (FOUNDATION): ONBOARDING replaces this with the six-step flow.
struct OnboardingView: View {
    let env: AppEnvironment

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            MiniPill(phase: .listening)
            Text("Welcome to Murmur").typeface(.display).foregroundStyle(.ink)
            Text("Hold fn, speak, let go. Your words appear wherever you type.")
                .typeface(.body).foregroundStyle(.inkSecondary)
            Button("Get started") {
                env.settings.onboardingCompleted = true
                env.windows.closeOnboarding()
            }
            .buttonStyle(PrimaryButtonStyle(size: .large))
        }
        .frame(width: 820, height: 600)
        .background(.bgCanvas)
    }
}

import SwiftUI

struct PermissionsStep: View {
    let model: OnboardingModel

    private var permissions: PermissionsCenter { model.ctx.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Two quick permissions",
                       subtitle: "Murmur listens only while you hold the key, then pastes the words where your cursor is.")
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                microphoneCard
                accessibilityCard
                if model.accessibilityLooksStale || (model.showAccessibilityHelp && permissions.accessibility != .granted) {
                    staleHint
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if model.skipAccessibilityArmed {
                    StepNote(symbol: "exclamationmark.triangle.fill", tint: .warning,
                             text: Text("Without Accessibility, Murmur can't paste into other apps or hear your shortcut. You can turn it on later in Settings."))
                        .transition(.opacity)
                }
                if model.showsFnKeyCard {
                    fnKeyCard
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.expand, value: model.accessibilityLooksStale)
            .animation(Theme.Motion.expand, value: model.showAccessibilityHelp)
            .animation(Theme.Motion.fade, value: model.skipAccessibilityArmed)
        }
    }

    // MARK: Cards

    private var microphoneCard: some View {
        let state = permissions.microphone
        return PermissionCard(
            symbol: state == .denied ? "mic.slash.fill" : "mic.fill",
            tint: state == .denied ? .warning : .accent,
            title: "Microphone",
            subtitle: state == .denied
                ? "Access is off. Turn on Murmur in Privacy & Security › Microphone."
                : "So Murmur can hear you while you hold the key.",
            status: state == .granted ? .granted : (state == .denied ? .attention : .pending)
        ) {
            switch state {
            case .granted:
                GrantedLabel()
            case .denied:
                Button("Open Settings") { model.requestMicrophone() }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            case .notDetermined:
                if model.isRequestingMicrophone {
                    ProgressView().controlSize(.small).frame(width: 60)
                } else {
                    Button("Allow") { model.requestMicrophone() }
                        .buttonStyle(PrimaryButtonStyle(size: .small))
                }
            }
        }
    }

    private var accessibilityCard: some View {
        let granted = permissions.accessibility == .granted
        let micDone = permissions.microphone == .granted
        return PermissionCard(
            symbol: "accessibility",
            tint: .accent,
            title: "Accessibility",
            subtitle: "So Murmur can paste and hear your shortcut.",
            status: granted ? .granted : .pending
        ) {
            if granted {
                GrantedLabel()
            } else if micDone {
                Button("Open Settings") { model.requestAccessibility() }
                    .buttonStyle(PrimaryButtonStyle(size: .small))
            } else {
                Button("Open Settings") { model.requestAccessibility() }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }

    private var staleHint: some View {
        let minus = Text(verbatim: "−").fontWeight(.bold)
        let plus = Text(verbatim: "+").fontWeight(.bold)
        let text: Text = model.accessibilityLooksStale
            ? Text("Murmur was rebuilt, so macOS needs it added again: select Murmur, click \(minus), then \(plus) and pick Murmur.")
            : Text("Already switched on? If this doesn't update, select Murmur in the list, click \(minus), then \(plus) and add it again.")
        return StepNote(symbol: "arrow.triangle.2.circlepath", tint: .warning, text: text) {
            Button {
                model.revealAppInFinder()
            } label: {
                Label("Reveal Murmur in Finder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
            .padding(.leading, -8)
            .frame(height: 20)
        }
    }

    private var fnKeyCard: some View {
        let opens: String = switch model.fnKeyUsage {
        case .other(let name): name
        default: "another macOS feature"
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                PermissionIcon(symbol: "globe", tint: .warm)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Free up the fn key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Text("Pressing fn opens \(opens) right now. Set \(Text("Press fn key to").fontWeight(.medium).foregroundColor(.ink)) to \(Text("Do Nothing").fontWeight(.medium).foregroundColor(.ink)) so holding it only talks to Murmur.")
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Settings") { model.openKeyboardSettings() }
                        .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
                        .padding(.leading, -8)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
        }
    }
}

// MARK: - Card

enum PermissionCardStatus {
    case pending, granted, attention
}

struct PermissionIcon: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct PermissionCard<Trailing: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String
    var status: PermissionCardStatus
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let border: Color = switch status {
        case .pending: .stroke
        case .granted: Color.success.opacity(0.28)
        case .attention: Color.warning.opacity(0.35)
        }
        HStack(alignment: .center, spacing: 12) {
            PermissionIcon(symbol: status == .granted ? symbol : symbol,
                           tint: status == .granted ? .success : tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(status == .attention ? Color.warning : Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(status == .granted ? Color.success.opacity(0.05)
                              : (status == .attention ? Color.warning.opacity(0.06) : .clear))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(border, lineWidth: 1)
        }
        .cardShadow()
        .animation(Theme.Motion.expand, value: status)
        .accessibilityElement(children: .contain)
    }
}

struct GrantedLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            DrawOnCheck(size: 18)
            Text("Allowed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.success)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Allowed")
    }
}

// MARK: - Stage

/// Murmur in the middle, the microphone and the text cursor either side. Lines light up as access arrives,
/// and a System Settings sketch shows exactly which switch to flip.
struct PermissionsStage: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let permissions = model.ctx.permissions
        let mic = permissions.microphone == .granted
        let ax = permissions.accessibility == .granted
        StageClock(paused: reduceMotion, framesPerSecond: 30) { t in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ConnectionDiagram(micGranted: mic, axGranted: ax, time: reduceMotion ? 0.35 : t)
                Spacer(minLength: 0)
                Group {
                    if mic && ax {
                        AllSetCard()
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if !mic {
                        MicPromptSketch()
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        SettingsSketch(isOn: ax, time: reduceMotion ? 0 : t)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 36)
                .animation(Theme.Motion.expand, value: mic)
                .animation(Theme.Motion.expand, value: ax)
            }
        }
    }
}

private struct ConnectionDiagram: View {
    var micGranted: Bool
    var axGranted: Bool
    var time: Double

    var body: some View {
        HStack(spacing: 0) {
            Satellite(symbol: "mic.fill", label: "Hears you", granted: micGranted)
            Connector(active: micGranted, time: time, flowsRight: true)
            ZStack {
                StageGlow(color: .accent, radius: 70, opacity: micGranted && axGranted ? 0.35 : 0.16)
                AppMark(size: 68)
            }
            .frame(width: 84, height: 84)
            Connector(active: axGranted, time: time + 0.4, flowsRight: true)
            Satellite(symbol: "character.cursor.ibeam", label: "Types for you", granted: axGranted)
        }
        .padding(.top, 24)
    }
}

private struct Satellite: View {
    var symbol: String
    var label: String
    var granted: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(granted ? Color.accent : Color.inkTertiary)
                    .frame(width: 58, height: 58)
                    .background(Color.bgSurface, in: Circle())
                    .overlay { Circle().strokeBorder(granted ? Color.accentRing : Color.stroke, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
                if granted {
                    DrawOnCheck(size: 20)
                        .overlay { Circle().strokeBorder(Color.bgSurface, lineWidth: 2) }
                        .offset(x: 3, y: -3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.ink)
                Text(granted ? "Allowed" : "Waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(granted ? Color.success : Color.inkTertiary)
                    .contentTransition(.opacity)
            }
        }
        .frame(width: 96)
        .animation(Theme.Motion.expand, value: granted)
    }
}

private struct Connector: View {
    var active: Bool
    var time: Double
    var flowsRight: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if active {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [Color.accent.opacity(0.35), Color.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                let phase = (time / 1.6).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(Color.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: Color.accent.opacity(0.8), radius: 4)
                    .offset(x: CGFloat(flowsRight ? phase : 1 - phase) * 26 - 3)
                    .opacity(sin(phase * .pi))
            } else {
                Line()
                    .stroke(Color.inkTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
                    .frame(height: 2)
            }
        }
        .frame(width: 26, height: 6)
        .offset(y: -22)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// A sketch of the macOS microphone prompt, pointing at the button to press.
private struct MicPromptSketch: View {
    var body: some View {
        VStack(spacing: 12) {
            AppMark(size: 40)
            VStack(spacing: 4) {
                Text("“Murmur” would like to access the microphone.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.ink)
                    .multilineTextAlignment(.center)
                Text("So Murmur can hear you while you hold the key.")
                    .font(.system(size: 11))
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                sketchButton("Don't Allow", prominent: false)
                sketchButton("Allow", prominent: true)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(Color.bgSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow(elevated: true)
        .accessibilityHidden(true)
    }

    private func sketchButton(_ title: String, prominent: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.onAccent : Color.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(prominent ? Color.accentFill : Color.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if prominent {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentRing, lineWidth: 2)
                        .padding(-3)
                }
            }
    }
}

/// A sketch of Privacy & Security › Accessibility with Murmur's switch called out.
private struct SettingsSketch: View {
    var isOn: Bool
    var time: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
                Text("Accessibility")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Spacer(minLength: 0)
                Text("System Settings")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.inkTertiary)
            }
            .padding(.bottom, 10)
            VStack(spacing: 0) {
                row(isMurmur: true, width: 0)
                Rectangle().fill(Color.stroke).frame(height: 1).padding(.leading, 40)
                row(isMurmur: false, width: 92)
                Rectangle().fill(Color.stroke).frame(height: 1).padding(.leading, 40)
                row(isMurmur: false, width: 64)
            }
            .background(Color.bgCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        }
        .padding(16)
        .background(Color.bgSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow(elevated: true)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func row(isMurmur: Bool, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            if isMurmur {
                AppMark(size: 22)
                Text("Murmur")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.ink)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.ink.opacity(0.08))
                    .frame(width: 22, height: 22)
                Capsule().fill(Color.ink.opacity(0.08)).frame(width: width, height: 7)
            }
            Spacer(minLength: 0)
            SketchSwitch(isOn: isMurmur && isOn, dimmed: !isMurmur)
                .overlay(alignment: .trailing) {
                    if isMurmur && !isOn {
                        let bob = sin(time * 2 * .pi / 1.4) * 3
                        HStack(spacing: 4) {
                            Text("Turn this on")
                                .font(.system(size: 10.5, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.onAccent)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Color.accentFill, in: Capsule(style: .continuous))
                        .fixedSize()
                        .offset(x: -44 + bob)
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background {
            if isMurmur && !isOn {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentSoft)
                    .padding(3)
            }
        }
    }
}

private struct SketchSwitch: View {
    var isOn: Bool
    var dimmed: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? Color.accentFill : Color.ink.opacity(dimmed ? 0.08 : 0.16))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 0.5)
                .padding(2)
        }
        .frame(width: 30, height: 18)
        .opacity(dimmed ? 0.7 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: isOn)
    }
}

private struct AllSetCard: View {
    var body: some View {
        HStack(spacing: 12) {
            DrawOnCheck(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all set")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Text("Murmur can hear you and type for you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.bgSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.success.opacity(0.25), lineWidth: 1) }
        .cardShadow(elevated: true)
    }
}

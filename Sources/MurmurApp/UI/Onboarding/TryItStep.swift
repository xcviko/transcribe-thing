import SwiftUI

struct TryItStep: View {
    let model: OnboardingModel

    private var settings: AppSettings { model.ctx.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Try it out",
                       subtitle: "Answer Alex out loud. Murmur types into the message box, just like it will in any app.")
                .padding(.bottom, 18)

            VStack(spacing: 8) {
                LessonRow(number: 1, title: "Hold to talk", detail: "Hold it, answer Alex, then let go.",
                          keys: settings.shortcuts[.pushToTalk], state: state(of: .pushToTalk))
                LessonRow(number: 2, title: "Go hands-free", detail: "Press once, talk as long as you like, press again.",
                          keys: settings.shortcuts[.handsFree], state: state(of: .handsFree))
                LessonRow(number: 3, title: "Change your mind", detail: "Start talking, then cancel. Nothing gets sent.",
                          keys: settings.shortcuts[.cancel], state: state(of: .cancel))
            }
            .animation(Theme.Motion.expand, value: model.completedLessons)

            Group {
                if let hint = model.practiceHint {
                    hintView(hint)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let stat = model.practiceStat {
                    SpeedFlash(stat: stat)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .animation(Theme.Motion.expand, value: model.practiceHint)
            .animation(Theme.Motion.expand, value: model.practiceStat)

            if model.currentLesson == nil {
                HStack(spacing: 8) {
                    DrawOnCheck(size: 16)
                    Text("Practice complete. It works like this in every app.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                }
                .padding(.top, 14)
                .padding(.leading, 12)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fade, value: model.currentLesson)
    }

    private func state(of lesson: PracticeLesson) -> LessonRow.State {
        if model.completedLessons.contains(lesson) { return .done }
        return model.currentLesson == lesson ? .current : .upcoming
    }

    @ViewBuilder private func hintView(_ hint: PracticeHint) -> some View {
        switch hint {
        case .noSpeech:
            StepNote(symbol: "mic.badge.xmark", tint: .warning,
                     text: Text("Didn’t catch that. Is the right mic selected?")) {
                MicrophoneMenu(model: model)
            }
        case .typedInstead:
            StepNote(symbol: "keyboard", tint: .accent,
                     text: Text("That one was typed. Try saying it: hold \(model.pushToTalkLabel) and talk."))
        }
    }
}

private struct LessonRow: View {
    enum State { case done, current, upcoming }

    var number: Int
    var title: String
    var detail: String
    var keys: Shortcut?
    var state: State

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state == .upcoming ? Color.inkSecondary : Color.ink)
                    Spacer(minLength: 0)
                    ShortcutChips(shortcut: keys, size: .small)
                        .opacity(state == .upcoming ? 0.6 : 1)
                }
                if state == .current {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, state == .current ? 12 : 9)
        .background {
            if state == .current {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bgSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentRing, lineWidth: 1)
                    }
                    .cardShadow()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : (state == .current ? "Current" : ""))
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .done:
            DrawOnCheck(size: 20)
        case .current:
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.onAccent)
                .frame(width: 20, height: 20)
                .background(Color.accentFill, in: Circle())
        case .upcoming:
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.inkTertiary)
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(Color.strokeStrong, lineWidth: 1) }
        }
    }
}

/// "207 wpm" moment after the first dictation: you vs typing.
private struct SpeedFlash: View {
    var stat: PracticeStat

    private static let typingWPM = 40

    var body: some View {
        let wpm = stat.wordsPerMinute
        let scaleMax = Double(max(wpm, 120))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(wpm)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText(value: Double(wpm)))
                Text("words per minute")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                Spacer(minLength: 0)
                Text("\(Fmt.words(stat.words)) in \(Int(stat.seconds.rounded())) s")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.inkTertiary)
            }
            VStack(alignment: .leading, spacing: 5) {
                bar(label: "You", number: wpm, value: Double(wpm) / scaleMax, tint: .accent)
                bar(label: "Typing", number: Self.typingWPM, value: Double(Self.typingWPM) / scaleMax, tint: .inkTertiary)
            }
        }
        .padding(14)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(wpm) words per minute. Typing averages about \(Self.typingWPM).")
    }

    private func bar(label: String, number: Int, value: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.inkSecondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                Capsule(style: .continuous)
                    .fill(tint == .accent
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accent.opacity(0.7), Color.accent], startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(tint.opacity(0.45)))
                    .frame(width: max(6, geo.size.width * value))
            }
            .frame(height: 6)
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint == .accent ? Color.accent : Color.inkTertiary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

/// Inline microphone picker for the "didn't catch that" hint.
struct MicrophoneMenu: View {
    let model: OnboardingModel

    var body: some View {
        let devices = model.ctx.devices.devices.filter(\.isAvailable)
        let current = model.ctx.settings.microphoneUID
        let currentName = model.ctx.devices.device(uid: current)?.name ?? "Automatic"
        Menu {
            Button {
                model.setMicrophone(nil)
            } label: {
                if current == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(devices) { device in
                Button {
                    model.setMicrophone(device.id)
                } label: {
                    if current == device.id { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill").font(.system(size: 10, weight: .semibold))
                Text(currentName).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

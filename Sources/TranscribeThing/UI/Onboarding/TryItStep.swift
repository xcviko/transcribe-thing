import SwiftUI

/// Shortcuts and practice in one step: each lesson row carries the shortcut it teaches (with Change), the stage
/// runs the practice chat above a keyboard strip that lights up with the real keys.
struct TryItStep: View {
    let model: OnboardingModel

    private var settings: AppSettings { model.ctx.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Try it out",
                       subtitle: "Answer Alex out loud. Your words land in the message box, just like they will in any app.")
                .padding(.bottom, 16)

            VStack(spacing: 2) {
                LessonRow(number: 1, title: "Hold to talk",
                          detail: model.lessonsFollowKeys
                              ? "Hold \(model.pushToTalkLabel) for a moment, then let go."
                              : "Hold \(model.pushToTalkLabel), answer Alex, then let go.",
                          action: .pushToTalk, state: state(of: .pushToTalk), settings: settings)
                LessonRow(number: 2, title: "Go hands-free", detail: handsFreeDetail,
                          action: .handsFree, state: state(of: .handsFree), settings: settings)
                LessonRow(number: 3, title: "Change your mind",
                          detail: "Start talking, then press \(label(.cancel, fallback: "esc")). Nothing gets typed.",
                          action: .cancel, state: state(of: .cancel), settings: settings)
                RowDivider(inset: 44)
                    .padding(.vertical, 2)
                LessonRow(number: 0, title: "Paste last", detail: nil, action: .pasteLast, state: .extra,
                          settings: settings)
            }
            .animation(Theme.Motion.expand, value: model.completedLessons)

            footnote
                .animation(Theme.Motion.expand, value: model.practiceHint)
                .animation(Theme.Motion.expand, value: model.practiceStat)
                .animation(Theme.Motion.expand, value: model.showKeyboardHint)
                .animation(Theme.Motion.fade, value: model.currentLesson)
        }
    }

    private var handsFreeDetail: String {
        let base = "Press once, talk as long as you like, press \(model.pushToTalkLabel) to finish."
        return settings.doublePressForHandsFree ? base + " Or double-press \(model.pushToTalkLabel)." : base
    }

    /// "fn Space" stays on one line inside running copy.
    private func label(_ action: ShortcutAction, fallback: String) -> String {
        (settings.shortcuts[action]?.compactDescription ?? fallback).replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    private func state(of lesson: PracticeLesson) -> LessonRow.State {
        if model.completedLessons.contains(lesson) { return .done }
        return model.currentLesson == lesson ? .current : .upcoming
    }

    /// One thing under the lessons at a time: a hint that needs acting on, else the speed flash, else the wrap-up.
    @ViewBuilder private var footnote: some View {
        if let hint = model.practiceHint {
            hintView(hint)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if model.showKeyboardHint {
            StepNote(symbol: "keyboard", tint: .accent,
                     text: Text("\(model.pushToTalkLabel) not lighting up? Some external keyboards keep fn to themselves. You can pick another key, like right ⌥.")) {
                Button("Use Right ⌥ to Talk") {
                    settings.shortcuts[.pushToTalk] = .rightOption
                }
                .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
                .padding(.leading, -8)
                .frame(height: 20)
            }
            .padding(.top, 12)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let stat = model.practiceStat {
            SpeedFlash(stat: stat, complete: model.currentLesson == nil)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        } else if model.currentLesson == nil {
            PracticeComplete()
                .padding(.top, 14)
                .padding(.leading, 12)
                .transition(.opacity)
        }
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
        case .tryHandsFree:
            StepNote(symbol: "hand.raised", tint: .accent,
                     text: Text("That one was push to talk. For hands-free, press \(label(.handsFree, fallback: "fn Space")), then talk."))
        }
    }
}

// MARK: - Rows

/// A lesson and the shortcut it teaches. The current lesson lifts into a card with its instructions.
private struct LessonRow: View {
    enum State { case done, current, upcoming, extra }

    var number: Int
    var title: String
    var detail: String?
    var action: ShortcutAction
    var state: State
    let settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
                .frame(height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    ShortcutRecorderView(shortcut: binding, action: action)
                        .opacity(state == .upcoming || state == .extra ? 0.8 : 1)
                        .layoutPriority(2)
                }
                .frame(minHeight: 30)
                if state == .current, let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .lineSpacing(1.5)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, state == .current ? 9 : 3)
        .background {
            if state == .current {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bgSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentRing, lineWidth: 1)
                    }
                    .cardShadow()
                    .transition(.opacity)
            }
        }
        .padding(.vertical, state == .current ? 3 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityValue(state == .done ? "Done" : (state == .current ? "Current" : ""))
    }

    private var titleColor: Color {
        switch state {
        case .done, .current: .ink
        case .upcoming, .extra: .inkSecondary
        }
    }

    private var binding: Binding<Shortcut?> {
        let settings = settings
        let action = action
        return Binding(get: { settings.shortcuts[action] }, set: { settings.shortcuts[action] = $0 })
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
        case .extra:
            Image(systemName: action.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.inkTertiary)
                .frame(width: 20, height: 20)
        }
    }
}

private struct PracticeComplete: View {
    var body: some View {
        HStack(spacing: 8) {
            DrawOnCheck(size: 16)
            Text("All set. It works like this in every app.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.inkSecondary)
        }
    }
}

/// "207 wpm" moment after the first dictation: you vs typing.
private struct SpeedFlash: View {
    var stat: PracticeStat
    /// All three lessons done: the card carries the wrap-up line too.
    var complete = false

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
            if complete {
                RowDivider(inset: 0)
                PracticeComplete()
                    .transition(.opacity)
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

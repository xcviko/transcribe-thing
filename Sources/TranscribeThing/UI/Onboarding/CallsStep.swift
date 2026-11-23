import SwiftUI

/// Calls: what the app does with them, how it asks, and the browser extension for calls in web pages. Nothing here
/// blocks: Continue is always on.
struct CallsStep: View {
    let model: OnboardingModel

    private var settings: AppSettings { model.ctx.settings }
    private var ext: BrowserExtension { model.ctx.browserExtension }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Your calls, too",
                       subtitle: "\(Brand.name) notices a call in any app or browser and records both sides. "
                           + "Then you get a transcript and a summary with the tasks.")
                .padding(.bottom, 16)

            modeCard
                .padding(.bottom, 18)

            SectionHeader("Works better with the browser extension")
                .padding(.bottom, 4)
            Text(BrowserExtensionCopy.whatItDoes)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            ScrollView {
                browsersCard
                    .padding(.horizontal, 1)
                    .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.horizontal, -1)
        }
        .animation(Theme.Motion.expand, value: model.installingBrowsers)
        .animation(Theme.Motion.expand, value: ext.connections)
    }

    // MARK: Mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: settings.callRecording == .off ? "phone.down.fill" : "phone.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 24, height: 24)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Record calls")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                Spacer(minLength: 8)
                HubMenuPicker(title: "Record calls", options: CallRecordingMode.pickerOrder,
                              selection: Binding(get: { settings.callRecording }, set: { settings.callRecording = $0 }),
                              label: \.title)
            }
            Text(Self.modeLine(settings.callRecording))
                .font(.system(size: 11.5))
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow()
    }

    static func modeLine(_ mode: CallRecordingMode) -> String {
        switch mode {
        case .ask: "You’re asked before a call is transcribed."
        case .automatic: "Every call is recorded and transcribed."
        case .off: "Calls aren’t noticed. The menu bar can still record one."
        }
    }

    // MARK: Browsers

    /// Under a browser's name: that it waits for the extension after Install, or how many profiles have it.
    static func rowDetail(_ state: BrowserExtensionCopy.State, installing: Bool) -> String? {
        switch state {
        case .notInstalled: installing ? "Waiting for it to connect…" : nil
        case .connected(let profiles): profiles > 1 ? "In \(BrowserExtensionCopy.profilesPhrase(profiles))" : nil
        case .comingLater: nil
        }
    }

    private var browsersCard: some View {
        VStack(spacing: 0) {
            if ext.browsers.isEmpty {
                Text("No browser here takes it yet. \(BrowserExtensionCopy.noBrowsers)")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(Array(ext.browsers.enumerated()), id: \.element.id) { index, browser in
                if index > 0 { RowDivider(inset: 44) }
                browserRow(browser)
            }
        }
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow()
    }

    private func browserRow(_ browser: BrowserExtension.Browser) -> some View {
        let state = BrowserExtensionCopy.state(of: browser, profiles: ext.connections(of: browser).count)
        let installing = model.installingBrowsers.contains(browser.id)
        return HStack(spacing: 10) {
                BrowserIcon(browser: browser, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(state == .comingLater ? Color.inkSecondary : Color.ink)
                        .lineLimit(1)
                    if let error = ext.installErrors[browser.id], state == .notInstalled {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let detail = Self.rowDetail(state, installing: installing) {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.inkTertiary)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                switch state {
                case .comingLater:
                    Text("Coming later")
                        .font(.system(size: 12))
                        .foregroundStyle(.inkTertiary)
                case .notInstalled:
                    Button(installing ? "Open Again" : "Install") { model.installExtension(browser) }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .connected:
                    HStack(spacing: 6) {
                        DrawOnCheck(size: 16)
                        Text("Connected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.success)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 42)
    }
}

// MARK: - Stage

/// A call under way (both sides talking, the time running) and what comes of it: a summary with its tasks. While a
/// browser is being set up, a sketch of its extensions page: Developer mode on, the folder dragged in.
struct CallsStage: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ext = model.ctx.browserExtension
        StageClock(paused: reduceMotion, framesPerSecond: 30) { t in
            let time = reduceMotion ? 1.2 : t
            Group {
                if let browser = model.installingBrowser {
                    let connected = !ext.connections(of: browser).isEmpty
                    VStack(spacing: 14) {
                        ExtensionPageSketch(browser: browser, connected: connected, time: time)
                        InstallStepsCard(browser: browser, connected: connected)
                    }
                    .padding(.horizontal, 28)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    CallScene(time: time)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.Motion.expand, value: model.installTarget)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.installingBrowser == nil
            ? "Illustration: a call being recorded, then its summary with tasks."
            : "Illustration: the browser’s extensions page, with Developer mode on and the folder dragged in.")
    }
}

private struct CallScene: View {
    var time: Double

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            CallCard(time: time)
                .padding(.horizontal, 32)
            FlowDots(time: time)
                .frame(height: 44)
            SummaryCard()
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
    }
}

/// A call window: who's in it, who's speaking, and the recording's time.
private struct CallCard: View {
    var time: Double

    private struct Person {
        var initial: String
        var name: String
        var tint: Color
    }

    private let people = [
        Person(initial: "A", name: "Anya", tint: Color(nsColor: Palette.modelViolet)),
        Person(initial: "M", name: "Matvey", tint: Color(nsColor: Palette.modelTeal)),
        Person(initial: "S", name: "You", tint: Color(nsColor: Palette.modelPink)),
    ]

    var body: some View {
        // Each person speaks for a while in turn.
        let speaker = Int(time / 2.2) % people.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 22, height: 22)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Weekly sync")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.ink)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.danger)
                        .frame(width: 6, height: 6)
                        .opacity(0.55 + 0.45 * (0.5 + 0.5 * cos(time * 2 * .pi / 1.6)))
                    Text(Fmt.duration(754 + time))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.inkSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(Color.stroke).frame(height: 1)
            HStack(spacing: 8) {
                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    tile(person, speaking: index == speaker)
                }
            }
            .padding(10)
        }
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow(elevated: true)
    }

    private func tile(_ person: Person, speaking: Bool) -> some View {
        VStack(spacing: 6) {
            Text(person.initial)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(person.tint, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accent.opacity(speaking ? 0.9 : 0), lineWidth: 1.5).padding(-3)
                }
            HStack(spacing: 4) {
                Text(person.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                MiniBars(level: speaking ? 0.9 : 0.12, time: time)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.bgSunken.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: speaking)
    }
}

/// Four little bars that move while someone speaks.
private struct MiniBars: View {
    var level: Double
    var time: Double

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<4, id: \.self) { i in
                let wobble = 0.55 + 0.45 * sin(time * 2 * .pi * (1.7 + 0.37 * Double(i)) + Double(i) * 1.3)
                Capsule(style: .continuous)
                    .fill(Color.inkSecondary)
                    .frame(width: 2, height: 2 + 7 * CGFloat(level * wobble))
            }
        }
        .frame(height: 10)
    }
}

/// Dots travelling down from the call to its summary.
private struct FlowDots: View {
    var time: Double

    var body: some View {
        VStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                let phase = (time / 1.4 - Double(i) * 0.18).truncatingRemainder(dividingBy: 1)
                let lift = max(0, sin(phase * .pi))
                Circle()
                    .fill(Color.inkTertiary.opacity(0.35 + 0.5 * lift))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

/// What the call leaves: a key point, a decision and two tasks, one done.
private struct SummaryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 22, height: 22)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Summary")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.ink)
                Spacer(minLength: 0)
                Text("3 speakers")
                    .font(.system(size: 11))
                    .foregroundStyle(.inkTertiary)
            }
            VStack(alignment: .leading, spacing: 5) {
                label("Decided")
                Text("The release moves to Friday.")
                    .font(.system(size: 12))
                    .foregroundStyle(.ink)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Tasks")
                task("Send the new deck to Matvey", owner: "You", done: false)
                task("Check the slow long files", owner: "Anya", done: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow(elevated: true)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.inkTertiary)
    }

    private func task(_ text: String, owner: String, done: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(done ? Color.success : Color.inkTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(done ? Color.inkTertiary : Color.ink)
                .strikethrough(done, color: .inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(owner)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.inkSecondary)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Color.accentSoft, in: Capsule(style: .continuous))
        }
    }
}

// MARK: - Extensions page sketch

/// The browser's extensions page: Developer mode called out, the folder on its way in from Finder. Once a profile
/// connects, the extension's card sits there, switched on.
private struct ExtensionPageSketch: View {
    var browser: BrowserExtension.Browser
    var connected: Bool
    var time: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Rectangle().fill(Color.stroke).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Extensions")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.ink)
                    Spacer(minLength: 0)
                    Text("Developer mode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                    SketchSwitch(isOn: switchOn, dimmed: false)
                        .overlay(alignment: .bottomTrailing) {
                            if !switchOn { callout("Turn this on", systemImage: "arrow.up").offset(y: 28 + bob) }
                        }
                }
                if connected {
                    installedCard
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    dropZone
                        .padding(.top, 18)
                }
            }
            .padding(16)
        }
        .background(Color.bgSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow(elevated: true)
        .animation(Theme.Motion.expand, value: connected)
    }

    private var bob: Double { sin(time * 2 * .pi / 1.4) * 3 }

    /// One loop: Developer mode goes on, then the folder slides in from Finder, rests over the page, and fades.
    private var cycle: Double { (time / 4.6).truncatingRemainder(dividingBy: 1) }
    private var switchOn: Bool { connected || cycle > 0.3 }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.ink.opacity(0.12)).frame(width: 8, height: 8)
                }
            }
            HStack(spacing: 6) {
                BrowserIcon(browser: browser, size: 14)
                Text(Self.extensionsPage(for: browser))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Where Chromium browsers keep their extensions: chrome://extensions, arc://extensions…
    static func extensionsPage(for browser: BrowserExtension.Browser) -> String {
        let scheme = switch browser.id {
        case "company.thebrowser.Browser": "arc"
        case "com.microsoft.edgemac": "edge"
        case "com.brave.Browser": "brave"
        case "com.vivaldi.Vivaldi": "vivaldi"
        case "ru.yandex.desktop.yandex-browser": "browser"
        default: "chrome"
        }
        return "\(scheme)://extensions"
    }

    private var dropZone: some View {
        let travel = Ease.outCubic(Ease.progress(cycle, 0.38, 0.72))
        let fade = Ease.progress(cycle, 0.34, 0.4) * (1 - Ease.progress(cycle, 0.9, 1))
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentSoft.opacity(0.5 + 0.5 * travel))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.strokeStrong, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }
            Text("Drop the folder here")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.inkTertiary)
                .offset(y: 42)
            folder
                .offset(x: Ease.lerp(110, 0, travel), y: Ease.lerp(70, -12, travel))
                .opacity(fade)
        }
        .frame(height: 128)
    }

    private var folder: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 3) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(nsColor: .systemBlue).opacity(0.85))
                Text("Extension")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.ink)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .shadow(color: .white, radius: 0.6)
                .offset(x: 12, y: 10)
        }
    }

    private var installedCard: some View {
        HStack(spacing: 10) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Brand.name) for calls")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text("Talking to the app")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 0)
            DrawOnCheck(size: 18)
        }
        .padding(12)
        .background(Color.bgCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.success.opacity(0.25), lineWidth: 1) }
    }

    private func callout(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.onAccent)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Color.accentFill, in: Capsule(style: .continuous))
        .fixedSize()
    }
}

/// Under the sketch: the steps, numbered; once a profile connects, that it worked and what's left.
private struct InstallStepsCard: View {
    var browser: BrowserExtension.Browser
    var connected: Bool

    var body: some View {
        Group {
            if connected {
                HStack(spacing: 10) {
                    DrawOnCheck(size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected in \(browser.name)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.ink)
                        Text("Have calls in another profile? Add it there the same way.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                BrowserExtensionSteps(fontSize: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color.bgSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(connected ? Color.success.opacity(0.25) : Color.stroke, lineWidth: 1)
        }
        .cardShadow()
    }
}

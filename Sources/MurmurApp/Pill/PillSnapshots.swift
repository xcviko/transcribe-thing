import SwiftUI

/// Pill and toast renders for visual QA (`Murmur --snapshots <dir> --only pill`).
enum PillSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [
            SnapshotEntry("pill-states", width: 760, height: 880) { _ in PillStateSheet() },
            SnapshotEntry("pill-tooltip", width: 640, height: 140) { _ in
                SideBySide { _ in
                    PillView(model: .preview(phase: .rest, isHovering: true))
                        .overlay(alignment: .top) {
                            PillRestTooltip(model: .preview(phase: .rest)).fixedSize()
                                .alignmentGuide(.top) { $0[.bottom] + 8 }
                        }
                }
            },
            SnapshotEntry("pill-locked-tooltip", width: 640, height: 140) { _ in
                SideBySide { _ in
                    PillView(model: lockedWithStopTooltip())
                }
            },
            SnapshotEntry("pill-hello", width: 640, height: 150) { _ in
                CanvasScene(model: helloModel(), notices: [])
            },
            SnapshotEntry("pill-toast-info", width: 640, height: 250) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.canceled])
            },
            SnapshotEntry("pill-toast-warning", width: 640, height: 250) { _ in
                CanvasScene(model: .preview(phase: .locked, recordingFor: 1142, limitSeconds: 1200),
                            notices: [PillSnapshotFixtures.oneMinuteLeft])
            },
            SnapshotEntry("pill-toast-error", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.keyRejected])
            },
            SnapshotEntry("pill-toast-transcript", width: 640, height: 340) { _ in
                CanvasScene(model: .preview(phase: .success), notices: [PillSnapshotFixtures.switchedApps])
            },
            SnapshotEntry("pill-toast-stack", width: 640, height: 330) { _ in
                CanvasScene(model: .preview(phase: .processing), notices: [PillSnapshotFixtures.micFallback,
                                                                             PillSnapshotFixtures.noSpeech])
            },
            SnapshotEntry("pill-toast-hidden", width: 640, height: 200) { _ in
                CanvasScene(model: hiddenModel(), notices: [PillSnapshotFixtures.hiddenForHour])
            },
        ]
    }

    /// Post-onboarding hello in the real canvas: peek + tooltip.
    @MainActor private static func helloModel() -> PillModel {
        let model = PillModel.preview(phase: .rest)
        model.beginHello(duration: 60)
        return model
    }

    @MainActor private static func restModel() -> PillModel {
        let model = PillModel.preview(phase: .rest)
        return model
    }

    /// "Never" mode / hidden for an hour: no pill, the toast sits where the pill would be.
    @MainActor private static func hiddenModel() -> PillModel {
        let model = PillModel.preview(phase: .rest)
        model.isPresented = false
        model.isPillAllowed = false
        return model
    }

    @MainActor private static func lockedWithStopTooltip() -> PillModel {
        let model = PillModel.preview(phase: .locked, isHovering: true, recordingFor: 42)
        model.showControlTooltip(.stop)
        return model
    }
}

// MARK: - Fixtures

enum PillSnapshotFixtures {
    static let canceled = Notice(
        dedupeKey: "dictation.canceled", style: .info, symbol: "arrow.uturn.backward",
        title: "Dictation canceled", body: "Saved in History for 14 days.",
        actions: [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true),
                  NoticeAction(title: "Open History", kind: .openHub(.home))],
        lifetime: .seconds(6), sound: .cancel)

    static let oneMinuteLeft = Notice(
        dedupeKey: "dictation.limitWarning", style: .warning, symbol: "timer",
        title: "1 minute left", body: "Recording stops at 20 min and gets transcribed.",
        lifetime: .seconds(6), sound: .alert)

    static let keyRejected = MurmurError.openRouterInvalidKey("Invalid API key")
        .notice(recordingID: UUID(), fallbackEngine: .parakeet)

    static let switchedApps = Notice(
        dedupeKey: "paste.transcript", style: .info, symbol: "doc.on.clipboard",
        title: "You switched apps", body: "Paste here, or copy it.",
        transcript: "Let's move the design review to Thursday afternoon so Maya can join, and I'll send the updated deck tonight. Also, can someone check whether the staging build picked up the new onboarding copy?",
        actions: [NoticeAction(title: "Paste Here", kind: .pasteText("…"), isPrimary: true)],
        lifetime: .seconds(20))

    static let micFallback = Notice(
        dedupeKey: "mic.fallback", style: .warning, symbol: "mic.fill",
        title: "Using MacBook Pro Microphone instead", body: "AirPods Pro isn't available right now.",
        actions: [NoticeAction(title: "Choose Mic", kind: .chooseMicrophone, isPrimary: true)],
        lifetime: .seconds(8), sound: .alert)

    static let noSpeech = MurmurError.noSpeech.notice(recordingID: nil, fallbackEngine: nil)

    static let hiddenForHour = Notice(
        dedupeKey: "pill.hiddenForHour", style: .info, symbol: "eye.slash",
        title: "Pill hidden for an hour",
        actions: [NoticeAction(title: "Show Now", kind: .showPillNow, isPrimary: true)],
        lifetime: .seconds(5))
}

// MARK: - Scenes

/// A stand-in desktop: a light document or a dark editor under the pill, to prove it reads on both.
private struct SnapshotDesktop: View {
    var dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(nsColor: .hex(0x1B1F33)), Color(nsColor: .hex(0x0E0F14))]
                                        : [Color(nsColor: .hex(0xD9E4F5)), Color(nsColor: .hex(0xF4E4DA))],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                let inset: CGFloat = 18
                let window = RoundedRectangle(cornerRadius: 12, style: .continuous)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)).frame(width: 9, height: 9)
                        }
                    }
                    .padding(.bottom, 8)
                    ForEach(0..<14, id: \.self) { i in
                        Capsule()
                            .fill(dark ? Color.white.opacity(i % 5 == 0 ? 0.16 : 0.08) : Color.black.opacity(i % 5 == 0 ? 0.14 : 0.07))
                            .frame(width: max(40, geo.size.width * [0.55, 0.8, 0.7, 0.62, 0.3, 0.75, 0.66, 0.82, 0.48, 0.7, 0.35, 0.74, 0.6, 0.5][i] - inset * 2),
                                   height: 6)
                    }
                }
                .padding(18)
                .frame(width: geo.size.width - inset * 2, height: geo.size.height, alignment: .topLeading)
                .background {
                    window.fill(dark ? Color(nsColor: .hex(0x1E1E21)) : .white)
                        .overlay { window.strokeBorder(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                }
                .offset(x: inset, y: inset)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A document page (white) or a dark editor, filled with faint text lines, for close-up cells.
private struct SnapshotPage: View {
    var dark: Bool
    private static let widths: [CGFloat] = [0.82, 0.64, 0.9, 0.48, 0.76, 0.58, 0.86]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<Self.widths.count, id: \.self) { i in
                    Capsule()
                        .fill(dark ? Color.white.opacity(0.09) : Color.black.opacity(0.075))
                        .frame(width: (geo.size.width - 48) * Self.widths[i], height: 5)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(dark ? Color(nsColor: .hex(0x1E1E21)) : .white)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Two cells, light document left and dark editor right, each with the content at bottom-center.
private struct SideBySide<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                ZStack(alignment: .bottom) {
                    SnapshotDesktop(dark: dark)
                    content(dark)
                        .padding(.bottom, 24)
                }
                .clipped()
            }
        }
        .environment(\.pillStaticRendering, true)
    }
}

/// The real panel canvas over a desktop that follows the appearance.
private struct CanvasScene: View {
    let model: PillModel
    let notices: [Notice]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottom) {
            SnapshotDesktop(dark: scheme == .dark)
            PillCanvasView(model: model, toasts: .preview(notices))
                .frame(width: PillCanvasMetrics.size.width)
        }
        .clipped()
        .environment(\.pillStaticRendering, true)
    }
}

/// Every pill state on a white document and on a dark editor.
private struct PillStateSheet: View {
    private struct Row: Identifiable {
        let id: String
        let caption: String
        let make: @MainActor () -> PillModel
    }

    private var rows: [Row] {
        [
            Row(id: "rest", caption: "Rest · 40×10") { .preview(phase: .rest) },
            Row(id: "peek", caption: "Hover · 76×24") { .preview(phase: .rest, isHovering: true) },
            Row(id: "connecting", caption: "Connecting") { .preview(phase: .listening, levelMeter: LevelMeter()) },
            Row(id: "listening", caption: "Listening · 104×32") { .preview(phase: .listening, level: 0.7) },
            Row(id: "silence", caption: "Listening · silence") { .preview(phase: .listening, level: 0) },
            Row(id: "locked", caption: "Hands-free · 168×36") { .preview(phase: .locked, level: 0.5) },
            Row(id: "locked-hover", caption: "Hands-free · hover") { .preview(phase: .locked, level: 0.62, isHovering: true, recordingFor: 83) },
            Row(id: "locked-last", caption: "Hands-free · last minute") {
                .preview(phase: .locked, level: 0.4, recordingFor: 1193, limitSeconds: 1200)
            },
            Row(id: "processing", caption: "Processing") { .preview(phase: .processing) },
            Row(id: "processing-wide", caption: "Processing · after hands-free") { PillStateSheet.processingAfterLocked() },
            Row(id: "success", caption: "Done") { .preview(phase: .success) },
            Row(id: "error", caption: "Error") { .preview(phase: .error) },
        ]
    }

    @MainActor static func processingAfterLocked() -> PillModel {
        let model = PillModel.preview(phase: .locked)
        model.phase = .processing
        return model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Pill states").frame(width: 200, alignment: .leading)
                Text("On a document").frame(maxWidth: .infinity)
                Text("On a dark editor").frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.inkTertiary)
            .padding(.horizontal, 24)
            .frame(height: 44)

            ForEach(rows) { row in
                HStack(spacing: 0) {
                    Text(row.caption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                        .frame(width: 200, alignment: .leading)
                        .padding(.leading, 24)
                    ForEach([false, true], id: \.self) { dark in
                        ZStack {
                            SnapshotPage(dark: dark)
                            PillView(model: row.make())
                        }
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                }
                .frame(height: 68)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.stroke).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
        .environment(\.pillStaticRendering, true)
    }
}

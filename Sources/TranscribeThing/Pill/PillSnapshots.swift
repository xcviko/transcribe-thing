import SwiftUI

/// Pill and toast renders for visual QA (`transcribe-thing --snapshots <dir> --only pill`).
enum PillSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [
            SnapshotEntry("pill-states", width: 760, height: 44 + 14 * 68) { _ in PillStateSheet() },
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
            // Film strips of the pill leaving (`--only pill-exit`).
            SnapshotEntry("pill-exit", width: PillFilmSheet.width(cell: 132, columns: 11), height: 452) { _ in
                PillFilmSheet(cell: 132, columns: 11, strips: [
                    .exit("Processing → hidden", .processing(afterHandsFree: false), model: .preview(phase: .processing)),
                    .exit("Error → hidden", .error, model: .preview(phase: .error)),
                    .exit("Listening → hidden (Esc)", .listening, model: .preview(phase: .listening, level: 0.7)),
                    .exit("Reduce Motion", .processing(afterHandsFree: false), model: .preview(phase: .processing),
                          reduceMotion: true),
                ])
            },
            SnapshotEntry("pill-exit-wide", width: PillFilmSheet.width(cell: 226, columns: 6), height: 630) { _ in
                PillFilmSheet(cell: 226, columns: 6, strips: [
                    .exit("Processing after hands-free → hidden", .processing(afterHandsFree: true),
                          model: PillStateSheet.processingAfterLocked()),
                    .handsFreeToHidden(),
                    .morph("Processing after hands-free → rest (Always)", from: .processing(afterHandsFree: true),
                           model: PillStateSheet.processingAfterLocked()),
                ])
            },
            // The token count (`--only pill-counter`): the dots give way to it, it counts through thinking and
            // writing (a clean-up only writes), and the pill leaves with its last number.
            SnapshotEntry("pill-counter", width: PillFilmSheet.width(cell: 158, columns: 11), height: 330) { _ in
                PillFilmSheet(cell: 158, columns: 11, strips: [
                    .counter("No tint", choice: nil),
                    .counter("Gemini Flash", choice: .gemini),
                    .counter("Clean-up", choice: .cleanup),
                ])
            },
            SnapshotEntry("pill-counter-rest", width: PillFilmSheet.width(cell: 158, columns: 11), height: 120) { _ in
                PillFilmSheet(cell: 158, columns: 11, strips: [
                    .morph("Counting → rest (Always)", from: .processing(afterHandsFree: false, counting: true),
                           model: PillModel.preview(phase: .processing)
                               .previewCounter(PillTokenCount(phase: .writing, tokens: 1_800)),
                           choice: .gemini),
                ])
            },
            SnapshotEntry("pill-exit-rest", width: PillFilmSheet.width(cell: 132, columns: 11), height: 452) { _ in
                PillFilmSheet(cell: 132, columns: 11, strips: [
                    .morph("Processing → rest (Always)", from: .processing(afterHandsFree: false), model: .preview(phase: .processing)),
                    .morph("Error → rest", from: .error, model: .preview(phase: .error)),
                    .morph("Listening → rest (Esc)", from: .listening, model: .preview(phase: .listening, level: 0.7)),
                    .morph("Hover ends", from: .peek, model: .preview(phase: .rest, isHovering: true)),
                ])
            },
            // Film strips of a Gemini or clean-up pill leaving: the chip and the tint go with it.
            SnapshotEntry("pill-exit-models", width: PillFilmSheet.width(cell: 132, columns: 11), height: 480) { _ in
                PillFilmSheet(cell: 132, columns: 11, cellHeight: 92, strips: [
                    .exit("Processing · Gemini Flash → hidden", .processing(afterHandsFree: false),
                          model: .preview(phase: .processing), choice: .gemini),
                    .exit("Processing · Clean-up → hidden", .processing(afterHandsFree: false),
                          model: .preview(phase: .processing), choice: .cleanup),
                    .morph("Processing · Gemini Flash → rest (Always)", from: .processing(afterHandsFree: false),
                           model: .preview(phase: .processing), choice: .gemini),
                ])
            },
            // Models (`--only pill-models`): the chip, the tint, the hint and the no-key notice.
            SnapshotEntry("pill-models", width: 760, height: 44 + 14 * 92) { _ in PillModelSheet() },
            SnapshotEntry("pill-polish", width: 760, height: 44 + 6 * 92 + 150) { _ in PolishSheet() },
            SnapshotEntry("pill-models-hint", width: 640, height: 150) { _ in
                CanvasScene(model: hintModel(), notices: [])
            },
            SnapshotEntry("pill-models-hint-custom", width: 640, height: 150) { _ in
                CanvasScene(model: hintModel(binding: Shortcut(modifiers: [.init(.control), .init(.option)],
                                                               keyCode: KeyCode.space)), notices: [])
            },
            SnapshotEntry("pill-models-no-key", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .listening, level: 0.7),
                            notices: [DictationController.switchWithoutKeyNotice(.missing, blocked: [.cleanup, .gemini])])
            },
            SnapshotEntry("pill-models-toast", width: 640, height: 290) { _ in
                CanvasScene(model: PillModelSheet.model(.locked, choice: .gemini, recordingFor: 362),
                            notices: [PillSnapshotFixtures.micFallback])
            },
            // Model colors (`--only pill-model-colors`): every color Models offers as a model's tint, on the pill and
            // in the Hub; on a document in light, a dark editor in dark.
            SnapshotEntry("pill-model-colors", width: ModelColorSheet.width, height: ModelColorSheet.height) { _ in
                ModelColorSheet()
            },
            SnapshotEntry("pill-toast-info", width: 640, height: 250) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.canceled])
            },
            SnapshotEntry("pill-toast-warning", width: 640, height: 250) { _ in
                CanvasScene(model: .preview(phase: .locked, recordingFor: 1142),
                            notices: [PillSnapshotFixtures.secureInput])
            },
            SnapshotEntry("pill-toast-error", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.keyRejected])
            },
            SnapshotEntry("pill-toast-cloud-speech", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.cloudSpeechRateLimited])
            },
            SnapshotEntry("pill-toast-no-connection", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.noConnection])
            },
            SnapshotEntry("pill-toast-region", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.regionBlocked])
            },
            SnapshotEntry("pill-toast-firewall", width: 640, height: 270) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.connectionBlocked])
            },
            SnapshotEntry("pill-toast-transcript", width: 640, height: 340) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.switchedApps])
            },
            SnapshotEntry("pill-toast-not-pasted", width: 640, height: 360) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.notPasted])
            },
            SnapshotEntry("pill-toast-shortcut", width: 640, height: 270) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.shortcutUnavailable])
            },
            SnapshotEntry("pill-toast-truncated", width: 640, height: 360) { _ in
                CanvasScene(model: .preview(phase: .error), notices: [PillSnapshotFixtures.truncated])
            },
            SnapshotEntry("pill-toast-stack", width: 640, height: 330) { _ in
                CanvasScene(model: .preview(phase: .processing), notices: [PillSnapshotFixtures.micFallback,
                                                                             PillSnapshotFixtures.noSpeech])
            },
            SnapshotEntry("pill-toast-update", width: 640, height: 270) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.updateAvailable])
            },
            SnapshotEntry("pill-toast-updated", width: 640, height: 220) { _ in
                CanvasScene(model: restModel(), notices: [PillSnapshotFixtures.updated])
            },
            SnapshotEntry("pill-toast-never", width: 640, height: 200) { _ in
                CanvasScene(model: neverModel(), notices: [PillSnapshotFixtures.noSpeech])
            },
        ]
    }

    /// Post-onboarding hello in the real canvas: the bloom mid-ripple with its "Hold fn anywhere" tooltip.
    @MainActor private static func helloModel() -> PillModel {
        let model = PillModel.preview(phase: .rest)
        model.beginHello(duration: 60)
        return model
    }

    /// A long push-to-talk hold showing the Switch model hint, with the default binding or `binding`.
    @MainActor private static func hintModel(binding: Shortcut? = nil) -> PillModel {
        let model = PillModel.preview(phase: .listening, level: 0.7)
        if let binding { model.settings.shortcuts[.switchModel] = binding }
        model.showsTabHint = true
        return model
    }

    @MainActor private static func restModel() -> PillModel {
        let model = PillModel.preview(phase: .rest)
        return model
    }

    /// "Never" mode: no pill, the toast sits where the pill would be.
    @MainActor private static func neverModel() -> PillModel {
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
        dedupeKey: "dictation.canceled", style: .info, symbol: "xmark.circle", title: "Dictation canceled",
        actions: [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)], lifetime: .seconds(6), sound: .cancel)

    /// What DictationController posts when a dictation starts while another app holds Secure Input.
    static let secureInput = Notice(
        dedupeKey: "secureInput", style: .warning, symbol: "lock.shield", title: "Secure typing is on in 1Password",
        body: "Holding fn still works. fn Space and Esc work again once it’s off.",
        actions: [NoticeAction(title: "Dismiss", kind: .dismiss)], lifetime: .seconds(10), sound: .alert)

    static let keyRejected = AppError.openRouterInvalidKey("Invalid API key")
        .notice(recordingID: UUID(), fallbackEngine: .parakeet)

    /// Cloud speech errors name the model and offer the same model on this Mac first.
    static let cloudSpeechRateLimited = AppError.openRouterRateLimited(retryAfter: nil)
        .notice(recordingID: UUID(), fallbackEngine: .parakeet, engine: .parakeetCloud)

    /// OpenRouter out of reach (a VPN that stopped), and a VPN that went off where Gemini isn't served.
    static let noConnection = AppError.offline.notice(recordingID: UUID(), fallbackEngine: .parakeet)
    static let regionBlocked = AppError.regionBlocked.notice(recordingID: UUID(), fallbackEngine: .parakeet)
    /// OpenRouter's firewall turning a VPN's address away.
    static let connectionBlocked = AppError.connectionBlocked.notice(recordingID: UUID(), fallbackEngine: .parakeet)

    static let truncated = AppError.openRouterTruncated(
        "So the plan for Thursday is to move the design review to the afternoon so Maya can join, and then so the plan for Thursday is to move the design review to the afternoon so Maya can join, and then so the plan for Thursday is")
        .notice(recordingID: UUID(), fallbackEngine: nil)

    static let switchedApps = Notice(
        dedupeKey: "paste.transcript", style: .info, symbol: "doc.on.clipboard",
        title: "You switched apps", body: "Paste here, or copy it.",
        transcript: "Let's move the design review to Thursday afternoon so Maya can join, and I'll send the updated deck tonight. Also, can someone check whether the staging build picked up the new onboarding copy?",
        actions: [NoticeAction(title: "Paste Here", kind: .pasteText("…"), isPrimary: true),
                  NoticeAction(title: "Copy", kind: .copyText("…"))],
        lifetime: .seconds(20))

    /// What DictationController posts when Accessibility is missing at paste time.
    static let notPasted: Notice = {
        let text = "Let's move the design review to Thursday afternoon so Maya can join."
        var notice = AppError.accessibilityMissing.notice(recordingID: nil, fallbackEngine: nil)
        notice.transcript = text
        notice.actions = [NoticeAction(title: "Allow Access", kind: .openSettingsPane(.accessibility), isPrimary: true),
                          NoticeAction(title: "Copy", kind: .copyText(text))]
        return notice
    }()

    static let shortcutUnavailable = Notice.shortcutUnavailable(accessibility: .denied, likelyStale: false, shortcut: "fn")

    static let micFallback = Notice(
        dedupeKey: "mic.fallback", style: .warning, symbol: "mic.fill",
        title: "Using MacBook Pro Microphone instead", body: "AirPods Pro isn’t available right now.",
        actions: [NoticeAction(title: "Choose Mic", kind: .chooseMicrophone, isPrimary: true)],
        lifetime: .seconds(8), sound: .alert)

    static let noSpeech = AppError.noSpeech.notice(recordingID: nil, fallbackEngine: nil)

    /// Right after a paste: the newest release, announced once.
    static let updateAvailable = UpdateCenter.availableNotice(PreviewFixtures.releases()[0])

    /// The first launch after installing it.
    static let updated = UpdateCenter.installedNotice(PreviewFixtures.releases()[0].version,
                                                      notes: PreviewFixtures.releases()[0].notes)
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

/// Film strips: each frame of a pill leaving, pinned at its progress, on a document (light) or a dark editor.
private struct PillFilmSheet: View {
    struct Frame {
        let caption: String
        let face: @MainActor (PillModel) -> AnyView
    }

    struct Strip {
        let title: String
        let model: PillModel
        let frames: [Frame]

        /// Hidden: the whole pill leaves, t = 0, 0.1 … 1 of the exit.
        @MainActor static func exit(_ title: String, _ visual: PillVisual, model: PillModel,
                                    reduceMotion: Bool = false, choice: ModelChoice? = nil) -> Strip {
            Strip(title: title, model: model, frames: exitFrames(visual, reduceMotion: reduceMotion,
                                                                 steps: Array(0...10), choice: choice))
        }

        /// Always mode: the content shrinks with the capsule into the resting one, every 30 ms of the spring.
        @MainActor static func morph(_ title: String, from visual: PillVisual, model: PillModel,
                                     choice: ModelChoice? = nil) -> Strip {
            let frames = (0...10).map { i in
                let time = Double(i) * 0.03
                let progress = CGFloat(Spring(duration: PillMotion.morphDuration, bounce: 0).value(target: 1.0, time: time))
                let pose = PillMotion.morphPose(at: progress, from: visual.size, to: PillVisual.rest.size)
                return Frame(caption: "\(Int((time * 1000).rounded())) ms") { model in
                    AnyView(PillFace(model: model, capsule: .rest, content: visual, morph: progress, size: pose.size,
                                     choice: choice))
                }
            }
            return Strip(title: title, model: model, frames: frames)
        }

        /// Hands-free, Stop (the pill narrows to the push-to-talk size), then the processing pill leaving.
        @MainActor static func handsFreeToHidden() -> Strip {
            let locked = PillVisual.locked(), processing = PillVisual.processing(afterHandsFree: true)
            let model = PillModel.preview(phase: .locked, level: 0.5)
            let stills = [Frame(caption: "hands-free") { model in
                AnyView(PillFace(model: model, capsule: locked, content: locked))
            }, Frame(caption: "Stop → processing") { model in
                AnyView(PillFace(model: model, capsule: processing, content: processing))
            }]
            return Strip(title: "Hands-free → processing → hidden", model: model,
                         frames: stills + exitFrames(processing, reduceMotion: false, steps: [0, 3, 5, 7, 9, 10]))
        }

        /// A streamed answer: the dots, then its count as it thinks and writes (the capsule has widened for it),
        /// then the pill leaving with its last number. A clean-up (GPT-6 Luna, which doesn't think) only writes.
        @MainActor static func counter(_ title: String, choice: ModelChoice?) -> Strip {
            let dots = PillVisual.processing(afterHandsFree: false)
            let counting = PillVisual.processing(afterHandsFree: false, counting: true)
            let counts = choice == .cleanup
                ? [40, 120, 640, 1_800].map { PillTokenCount(phase: .writing, tokens: $0) }
                : [PillTokenCount(phase: .thinking, tokens: 340), PillTokenCount(phase: .thinking, tokens: 2_400),
                   PillTokenCount(phase: .writing, tokens: 120), PillTokenCount(phase: .writing, tokens: 1_800)]
            let model = PillModel.preview(phase: .processing)
            let last = PillModel.preview(phase: .processing).previewCounter(counts[counts.count - 1])
            let stills = [Frame(caption: "dots") { _ in
                AnyView(PillFace(model: model, capsule: dots, content: dots, choice: choice))
            }] + counts.map { count in
                let counted = PillModel.preview(phase: .processing).previewCounter(count)
                return Frame(caption: "\(count.text) \(count.word)") { _ in
                    AnyView(PillFace(model: counted, capsule: counting, content: counting, choice: choice))
                }
            }
            let exit = exitFrames(counting, reduceMotion: false, steps: [0, 2, 4, 6, 8, 10], choice: choice)
                .map { frame in Frame(caption: frame.caption) { _ in frame.face(last) } }
            let steps = choice == .cleanup ? "processing → writing → hidden" : "processing → thinking → writing → hidden"
            return Strip(title: "\(title): \(steps)", model: model,
                         frames: stills + exit)
        }

        @MainActor private static func exitFrames(_ visual: PillVisual, reduceMotion: Bool, steps: [Int],
                                                  choice: ModelChoice? = nil) -> [Frame] {
            let duration = reduceMotion ? PillMotion.reducedExitDuration : PillMotion.exitDuration
            return steps.map { i in
                let progress = CGFloat(i) / 10
                return Frame(caption: "\(Int((Double(progress) * duration * 1000).rounded())) ms") { model in
                    AnyView(PillFace(model: model, capsule: visual, content: visual, choice: choice)
                        .modifier(PillExitEffect(progress: progress, reduceMotion: reduceMotion)))
                }
            }
        }
    }

    let cell: CGFloat
    let columns: Int
    /// Taller for a pill with its model chip.
    var cellHeight: CGFloat = 62
    let strips: [Strip]

    @Environment(\.colorScheme) private var scheme

    static let padding: CGFloat = 20
    static func width(cell: CGFloat, columns: Int) -> CGFloat { CGFloat(columns) * cell + 2 * padding }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(strips.enumerated()), id: \.offset) { _, strip in
                VStack(alignment: .leading, spacing: 6) {
                    Text(strip.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.inkSecondary)
                    let rows = stride(from: 0, to: strip.frames.count, by: columns).map {
                        Array(strip.frames[$0 ..< min($0 + columns, strip.frames.count)])
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, frame in
                                cellView(frame, model: strip.model)
                            }
                        }
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.bgCanvas)
        .environment(\.pillStaticRendering, true)
    }

    private func cellView(_ frame: Frame, model: PillModel) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                SnapshotPage(dark: scheme == .dark)
                frame.face(model)
                    .padding(.bottom, 14)
            }
            .frame(width: cell - 4, height: cellHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(frame.caption)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.inkTertiary)
        }
        .frame(width: cell)
    }
}

/// The pill with each model, on a white document and on a dark editor: the chip above it, the tint, and hands-free's
/// clickable chip.
private struct PillModelSheet: View {
    private struct Row: Identifiable {
        let id: String
        let caption: String
        let make: @MainActor () -> PillModel
    }

    /// `chip`: right after the switch, the chip still up; else later on, the tint alone. `main`: the lineup's main
    /// model, which changes nothing the pill draws.
    @MainActor static func model(_ phase: PillPhase, choice: ModelChoice?, level: Float = 0.7, chip: Bool = true,
                                 main: ModelChoice = .parakeet, recordingFor elapsed: TimeInterval? = nil) -> PillModel {
        let model = PillModel.preview(phase: phase, level: level, recordingFor: elapsed)
        model.settings.lineup.main = main
        model.sessionModel = choice
        if chip, choice != nil { model.flashChip() }
        return model
    }

    private var rows: [Row] {
        [
            Row(id: "parakeet", caption: "Push-to-talk · Parakeet") {
                Self.model(.listening, choice: .parakeet, chip: false)
            },
            Row(id: "gemini-main", caption: "Push-to-talk · Gemini (main)") {
                Self.model(.listening, choice: .gemini, chip: false, main: .gemini)
            },
            Row(id: "cleanup", caption: "Push-to-talk · Clean-up") { Self.model(.listening, choice: .cleanup) },
            Row(id: "cleanup-later", caption: "Clean-up · chip gone") {
                Self.model(.listening, choice: .cleanup, chip: false)
            },
            Row(id: "flash", caption: "Push-to-talk · Gemini Flash") { Self.model(.listening, choice: .gemini) },
            Row(id: "flash-later", caption: "Gemini Flash · chip gone") {
                Self.model(.listening, choice: .gemini, chip: false)
            },
            Row(id: "back", caption: "Back to Parakeet") { Self.model(.listening, choice: .parakeet) },
            Row(id: "locked-cleanup", caption: "Hands-free · Clean-up") { Self.model(.locked, choice: .cleanup, level: 0.5) },
            Row(id: "locked-flash", caption: "Hands-free · Gemini Flash") { Self.model(.locked, choice: .gemini, level: 0.5) },
            Row(id: "processing-cleanup", caption: "Processing · Clean-up") { Self.model(.processing, choice: .cleanup) },
            Row(id: "processing-flash", caption: "Processing · Gemini Flash") { Self.model(.processing, choice: .gemini) },
            Row(id: "processing-thinking-gemini", caption: "Thinking · Gemini Flash") {
                Self.model(.processing, choice: .gemini, chip: false)
                    .previewCounter(PillTokenCount(phase: .thinking, tokens: 2_400))
            },
            Row(id: "processing-writing-gemini", caption: "Writing · Gemini Flash") {
                Self.model(.processing, choice: .gemini, chip: false)
                    .previewCounter(PillTokenCount(phase: .writing, tokens: 17_700))
            },
            Row(id: "processing-writing-cleanup", caption: "Writing · Clean-up") {
                Self.model(.processing, choice: .cleanup, chip: false)
                    .previewCounter(PillTokenCount(phase: .writing, tokens: 340))
            },
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Models").frame(width: 200, alignment: .leading)
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
                        ZStack(alignment: .bottom) {
                            SnapshotPage(dark: dark)
                            PillView(model: row.make())
                                .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                }
                .frame(height: 92)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.stroke).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
        .environment(\.pillStaticRendering, true)
    }
}

/// Polish's drop: on in each state it shows in, then its way out of the pill, frame by frame.
private struct PolishSheet: View {
    private struct Row: Identifiable {
        let id: String
        let caption: String
        let make: @MainActor () -> PillModel
    }

    @MainActor static func model(_ phase: PillPhase, choice: ModelChoice, polish: PolishMode,
                                 level: Float = 0.7) -> PillModel {
        let model = PillModelSheet.model(phase, choice: choice, level: level, chip: false)
        model.polishMode = polish
        return model
    }

    private var rows: [Row] {
        [
            Row(id: "one", caption: "Push-to-talk · Polish") { Self.model(.listening, choice: .gemini, polish: .oneRequest) },
            Row(id: "two", caption: "Push-to-talk · Polish in two steps") {
                Self.model(.listening, choice: .parakeet, polish: .twoSteps)
            },
            Row(id: "locked", caption: "Hands-free · Polish") {
                Self.model(.locked, choice: .gemini, polish: .oneRequest, level: 0.5)
            },
            Row(id: "locked-two", caption: "Hands-free · two steps") {
                Self.model(.locked, choice: .parakeet, polish: .twoSteps, level: 0.5)
            },
            Row(id: "processing", caption: "Processing · Polish") {
                Self.model(.processing, choice: .gemini, polish: .oneRequest)
            },
            Row(id: "writing", caption: "Writing · two steps") {
                Self.model(.processing, choice: .parakeet, polish: .twoSteps)
                    .previewCounter(PillTokenCount(phase: .writing, tokens: 340))
            },
        ]
    }

    private static let frames: [Double] = [0.1, 0.25, 0.4, 0.5, 0.6, 0.7, 0.78, 0.88, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Polish").frame(width: 200, alignment: .leading)
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
                        ZStack(alignment: .bottom) {
                            SnapshotPage(dark: dark)
                            PillView(model: row.make())
                                .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                }
                .frame(height: 92)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.stroke).frame(height: 1) }
            }

            Text("The way out")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.inkSecondary)
                .padding(.leading, 24)
                .padding(.top, 14)
            HStack(spacing: 4) {
                ForEach(Self.frames, id: \.self) { progress in
                    ZStack {
                        SnapshotPage(dark: true)
                        PillCapsule()
                            .frame(width: 44, height: PillMetrics.listeningSize.height)
                            .overlay(alignment: .trailing) {
                                PillPolishDrop(mode: .oneRequest, height: PillMetrics.listeningSize.height,
                                               tint: .white, progress: progress)
                                    .frame(width: 0, height: PillMetrics.listeningSize.height)
                            }
                            .offset(x: -14)
                    }
                    .frame(width: 74, height: 90)
                    .clipped()
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
        .environment(\.pillStaticRendering, true)
    }
}

/// Each model color in a row, as every model's tint: listening, a Gemini chip, the clean-up chip over a count, the
/// processing dots, hands-free's ring beside Stop, and in the Hub a model's tile and History's mark. On a white
/// document in the light appearance (where a ring is hardest to see), on a dark editor in the dark one.
private struct ModelColorSheet: View {
    private struct Column {
        let title: String
        let width: CGFloat
        let make: @MainActor (ModelColor) -> AnyView
    }

    private static let captionWidth: CGFloat = 170
    private static let rowHeight: CGFloat = 100
    private static let headerHeight: CGFloat = 44
    /// Canvas bottom → pill bottom, as in the panel (`PillCanvasMetrics.pillBottomInset`).
    private static let pillInset = PillCanvasMetrics.pillBottomInset

    static var width: CGFloat { 24 + captionWidth + columns.reduce(0) { $0 + $1.width } + 24 }
    static var height: CGFloat { headerHeight + CGFloat(ModelColor.allCases.count) * rowHeight }

    /// The pill with every model in `color`: the preview model's settings carry it, as the app's carry the user's.
    @MainActor private static func pill(_ color: ModelColor, _ phase: PillPhase, choice: ModelChoice, chip: Bool = false,
                                        level: Float = 0.7, recordingFor elapsed: TimeInterval? = nil) -> PillModel {
        let model = PillModelSheet.model(phase, choice: choice, level: level, chip: chip, recordingFor: elapsed)
        for c in ModelChoice.allCases { model.settings.modelColors[c] = color }
        return model
    }

    /// The pill standing where the panel puts it.
    @MainActor private static func standing(_ model: PillModel) -> AnyView {
        AnyView(PillView(model: model).padding(.bottom, pillInset))
    }

    private static let columns: [Column] = [
        Column(title: "Listening", width: 140) { standing(pill($0, .listening, choice: .parakeet)) },
        Column(title: "Gemini chip", width: 170) { standing(pill($0, .listening, choice: .gemini, chip: true)) },
        // The chip's dimmed "Parakeet" and the counter's word are the dimmest text on the fill.
        Column(title: "Clean-up chip", width: 200) {
            standing(pill($0, .processing, choice: .cleanup, chip: true)
                .previewCounter(PillTokenCount(phase: .writing, tokens: 340)))
        },
        Column(title: "Processing", width: 130) { standing(pill($0, .processing, choice: .cleanup)) },
        Column(title: "Hands-free", width: 230) {
            standing(pill($0, .locked, choice: .gemini, level: 0.5, recordingFor: 42))
        },
        // The Hub's side: a model's tile (Models, the sidebar) and its mark in History, on a card.
        Column(title: "Hub", width: 130) { color in
            var colors = ModelColors.default
            for c in ModelChoice.allCases { colors[c] = color }
            return AnyView(HStack(spacing: 12) {
                ModelChoiceIcon(choice: .gemini, parakeet: .parakeet, color: color, size: 36)
                EngineGlyph(engine: .geminiFlash, colors: colors)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgSurface))
        },
    ]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Model colors").frame(width: Self.captionWidth, alignment: .leading)
                ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                    Text(column.title).frame(width: column.width)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.inkTertiary)
            .padding(.horizontal, 24)
            .frame(height: Self.headerHeight)

            ForEach(ModelColor.allCases) { color in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(color.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.inkSecondary)
                        Text(PillPalette.accent(for: color).map {
                            String(format: "ring #%06X\nmarks #%06X", $0.ringHex, $0.markHex)
                        } ?? "the plain pill")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.inkTertiary)
                    }
                    .frame(width: Self.captionWidth, alignment: .leading)
                    ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                        ZStack(alignment: .bottom) {
                            SnapshotPage(dark: scheme == .dark)
                            column.make(color)
                        }
                        .frame(width: column.width, height: Self.rowHeight - 1)
                        .clipped()
                    }
                }
                .padding(.horizontal, 24)
                .frame(height: Self.rowHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.stroke).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
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
            Row(id: "starting", caption: "Listening · just started") { .preview(phase: .listening, levelMeter: LevelMeter()) },
            Row(id: "listening", caption: "Listening · 104×32") { .preview(phase: .listening, level: 0.7) },
            Row(id: "silence", caption: "Listening · silence") { .preview(phase: .listening, level: 0) },
            Row(id: "locked", caption: "Hands-free · 198×36") { .preview(phase: .locked, level: 0.5) },
            Row(id: "locked-long", caption: "Hands-free · 28 min") {
                .preview(phase: .locked, level: 0.62, recordingFor: 1728)
            },
            Row(id: "locked-hours", caption: "Hands-free · past an hour") {
                .preview(phase: .locked, level: 0.4, recordingFor: 3733)
            },
            Row(id: "processing", caption: "Processing") { .preview(phase: .processing) },
            Row(id: "processing-wide", caption: "Processing · after hands-free") { PillStateSheet.processingAfterLocked() },
            Row(id: "processing-counter", caption: "Processing · counting · \(Int(PillMetrics.counterSize.width))×32") {
                PillModel.preview(phase: .processing).previewCounter(PillTokenCount(phase: .thinking, tokens: 1_249))
            },
            Row(id: "processing-counter-after-hands-free", caption: "Counting · after hands-free") {
                PillStateSheet.processingAfterLocked().previewCounter(PillTokenCount(phase: .writing, tokens: 88_800))
            },
            Row(id: "error", caption: "Error") { .preview(phase: .error) },
            Row(id: "no-speech", caption: "No speech") {
                let model = PillModel.preview(phase: .error)
                model.errorMessage = PillMetrics.noSpeechText
                return model
            },
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

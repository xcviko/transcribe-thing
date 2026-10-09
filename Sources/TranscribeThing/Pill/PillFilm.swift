import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// `transcribe-thing --pill-film <dir> [--only <scenario>] [--appearance light|dark]`
///
/// Films the pill's animations so they can be checked frame by frame without watching the screen. Each scenario hosts
/// the real panel canvas (`PillCanvasView`: the pill and its toasts) in a `PillPanel` placed off every screen, plays a
/// script of the calls `DictationController` makes on `PillModel` and `ToastCenter` (with their real timings: the error
/// hold, the counter's delay, the chip's hold, a toast's lifetime), and after each change captures a frame every 1/60 s
/// for about 0.6 s from the layers' presentation state: what the screen shows at that instant, mid-animation. A frame
/// whose capture overran its slot skips the slots it took; every label is the true time since the change.
///
/// Writes per scenario `<dir>/<NN-name>-<appearance>.png`, a contact sheet of its frames (each with the ms since its
/// change and the width of what is opaque in the pill's row: the capsule, or a toast in its slot), and the frames
/// themselves in `<dir>/<NN-name>-<appearance>/`. Prints each sheet's path and a line per change. Settings live in
/// memory; no hotkeys, no microphone, no network, no sound. Dark by default.
@MainActor
enum PillFilm {
    static func run(arguments: [String]) -> Int32 {
        guard let outPath = value(after: "--pill-film", in: arguments) else {
            printError("Usage: transcribe-thing --pill-film <outDir> [--only <scenario>] [--appearance light|dark]")
            return 64
        }
        let dark: Bool
        switch value(after: "--appearance", in: arguments) {
        case nil, "dark": dark = true
        case "light": dark = false
        case let other?:
            printError("Unknown appearance “\(other)”. Use light or dark.")
            return 64
        }
        let only = value(after: "--only", in: arguments)
        let scenarios = FilmScript.all.enumerated()
            .map { (name: String(format: "%02d-%@", $0.offset + 1, $0.element.name), scenario: $0.element) }
            .filter { entry in only.map { entry.name.hasPrefix($0) || entry.scenario.name.hasPrefix($0) } ?? true }
        guard !scenarios.isEmpty else {
            printError("No scenario matches “\(only ?? "")”. Scenarios: "
                       + FilmScript.all.map(\.name).joined(separator: ", "))
            return 1
        }

        NSApplication.shared.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            printError("Couldn’t create \(outDir.path): \(error.localizedDescription)")
            return 73
        }

        var failures = 0
        for (name, scenario) in scenarios {
            let ok = autoreleasepool { () -> Bool in
                let set = FilmSet(mode: scenario.mode, area: scenario.area, appearance: appearance)
                set.wait(0.6)
                scenario.play(set)
                set.close()
                let base = "\(name)-\(dark ? "dark" : "light")"
                let sheet = outDir.appendingPathComponent(base + ".png")
                do {
                    let reel = FilmReel(takes: set.takes, region: set.region)
                    try reel.write(title: "\(name) · \(scenario.mode.title)", note: scenario.note, dark: dark,
                                   sheet: sheet, frames: outDir.appendingPathComponent(base, isDirectory: true))
                    print(sheet.path)
                    for line in reel.summary { print("  " + line) }
                    return !set.takes.isEmpty && set.missed.isEmpty
                } catch {
                    printError("Couldn’t write \(base): \(error.localizedDescription)")
                    return false
                }
            }
            if !ok {
                failures += 1
                printError("Scenario \(name) didn’t film everything.")
            }
        }
        return failures == 0 ? 0 : 1
    }

    fileprivate static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        let value = arguments[i + 1]
        return value.hasPrefix("--") ? nil : value
    }
}

// MARK: - Script

private struct FilmScenario {
    /// What is filmed, centered at the canvas's bottom: the smaller, the faster a frame renders.
    static let pill = CGSize(width: 300, height: 100)
    static let toast = CGSize(width: 420, height: 170)

    let name: String
    let mode: PillMode
    var area = pill
    let note: String
    let play: @MainActor (FilmSet) -> Void
}

/// The scenarios, in the order `--pill-film` plays them. Each starts from a fresh model and toasts, idle and settled.
private enum FilmScript {
    @MainActor static let all: [FilmScenario] = [
        FilmScenario(name: "handsfree-start-accent", mode: .always,
                     note: "fn Space on Parakeet, Gemini the hands-free model: graphite, no ring → locked, violet ring") { s in
            s.record(.listening, on: .parakeet)
            s.wait(0.8)
            s.film("listening (Parakeet) → locked (Gemini)") {
                s.switchModel(to: .gemini)
                s.record(.locked, on: .gemini)
            }
        },
        FilmScenario(name: "handsfree-stop", mode: .always, note: "Stop in hands-free on Gemini") { s in
            s.record(.locked, on: .gemini, startedAgo: 14)
            s.wait(0.8)
            s.film("locked → processing after hands-free") { s.process(on: .gemini) }
        },
        FilmScenario(name: "nospeech-to-listening", mode: .always,
                     note: "A Gemini dictation of nothing, then fn again within the flash’s hold") { s in
            s.record(.listening, on: .gemini)
            s.wait(0.6)
            s.process(on: .gemini)
            s.wait(0.6)
            s.film("processing → “No speech detected” (Gemini ring)") { s.noSpeech(on: .gemini) }
            s.film("“No speech detected” → listening (Parakeet)") { s.record(.listening, on: .parakeet) }
        },
        FilmScenario(name: "nospeech-to-hidden", mode: .whileDictating,
                     note: "“No speech detected” on Gemini, left alone until its hold runs out") { s in
            s.record(.listening, on: .gemini)
            s.wait(0.6)
            s.process(on: .gemini)
            s.wait(0.6)
            s.noSpeech(on: .gemini)
            s.film("“No speech detected” → hidden (hold over)", when: { s.model.visiblePhase != .error })
        },
        FilmScenario(name: "canceled-undo", mode: .always, area: FilmScenario.toast,
                     note: "Esc, then Undo clicked on “Dictation canceled” over the resting pill, the pointer on the toast") { s in
            s.record(.listening, on: .parakeet)
            s.wait(0.6)
            let canceled = FilmScript.canceled()
            s.toasts.post(canceled)
            s.rest()
            s.wait(1)
            // The pointer came onto the toast: PillController pauses the toasts, and keeps them paused while the
            // dismissed toast's region lingers through its removal.
            s.toasts.setPaused(true)
            s.wait(0.3)
            // DictationController.undo: the dictation goes on hands-free with its model, its kept audio first.
            s.toasts.onAction = { _, action in
                guard case .undoCancel = action.kind else { return }
                s.record(.locked, on: .parakeet, startedAgo: 4)
            }
            // A click: ToastCenter hands the action over, then dismisses the toast.
            s.film("Undo: “Dictation canceled” → locked", for: 0.8) {
                s.toasts.perform(canceled.actions[0], on: canceled)
            }
        },
        FilmScenario(name: "handsfree-cancel-then-fn", mode: .whileDictating, area: FilmScenario.toast,
                     note: "Hands-free on Gemini with its chip, Esc (“Dictation canceled”), fn again 0.3 s later on Parakeet") { s in
            s.record(.locked, on: .gemini, startedAgo: 3)
            s.switchModel(to: .gemini)
            s.wait(0.6)
            s.toasts.post(FilmScript.canceled())
            s.rest()
            s.wait(0.3)
            s.film("fn while the hands-free pill is still leaving", for: 0.6) {
                s.record(.listening, on: .parakeet)
            }
        },
        FilmScenario(name: "handsfree-cancel-then-fn-later", mode: .whileDictating, area: FilmScenario.toast,
                     note: "The same, fn 0.8 s after Esc: the pill gone, its last content not yet dropped") { s in
            s.record(.locked, on: .gemini, startedAgo: 3)
            s.switchModel(to: .gemini)
            s.wait(0.6)
            s.toasts.post(FilmScript.canceled())
            s.rest()
            s.wait(0.8)
            s.film("fn after the hands-free pill has gone", for: 0.6) {
                s.record(.listening, on: .parakeet)
            }
        },
        FilmScenario(name: "processing-to-toast", mode: .always, area: FilmScenario.toast,
                     note: "Esc while processing: rest, and “Dictation canceled” grows out of the pill") { s in
            s.record(.listening, on: .parakeet)
            s.wait(0.5)
            s.process(on: .parakeet)
            s.wait(0.8)
            s.film("processing → rest + one-row toast", for: 0.7) {
                s.toasts.post(FilmScript.canceled())
                s.rest()
            }
        },
        FilmScenario(name: "toast-dismiss-uncover", mode: .always, area: FilmScenario.toast,
                     note: "A one-row toast in the resting pill’s slot runs out; the pill comes back") { s in
            s.toasts.post(Notice(dedupeKey: "engine.selected", style: .success, symbol: "waveform",
                                 title: "Now using Parakeet v3", lifetime: .seconds(3)))
            s.film("toast expires → rest pill back", when: { s.toasts.notices.isEmpty }, for: 0.8)
        },
        FilmScenario(name: "appear-at-once", mode: .whileDictating, note: "Key down with no pill on screen") { s in
            s.film("hidden → listening") { s.record(.listening, on: .parakeet) }
        },
        FilmScenario(name: "appear-at-once-colored", mode: .whileDictating,
                     note: "A polish of selected text (Gemini, violet ring) with no pill on screen") { s in
            s.film("hidden → processing (Gemini)") { s.process(on: .gemini) }
        },
        FilmScenario(name: "counting", mode: .always,
                     note: "Gemini’s count shows after the counter’s delay, ticks, and the text lands") { s in
            s.record(.listening, on: .gemini)
            s.wait(0.5)
            s.process(on: .gemini)
            s.wait(0.6)
            s.model.tokenCount = PillTokenCount(phase: .thinking, tokens: 420)
            s.film("processing → counting", when: { s.model.showsCounter })
            s.film("count ticks 420 → 1.2k") { s.model.tokenCount = PillTokenCount(phase: .thinking, tokens: 1_240) }
            s.film("counting → rest") { s.rest() }
        },
        FilmScenario(name: "polish-to-count", mode: .always,
                     note: "Polish Selection on Gemini: the wand and “Polishing”, then the capsule widens for the count") { s in
            s.polish(on: .gemini, selection: true)
            s.wait(0.6)
            s.model.tokenCount = PillTokenCount(phase: .thinking, tokens: 380)
            s.film("polishing → counting", when: { s.model.showsCounter })
            s.film("thinking → writing") { s.model.tokenCount = PillTokenCount(phase: .writing, tokens: 12) }
        },
        FilmScenario(name: "dictation-polish-to-count", mode: .always,
                     note: "A polished dictation on Gemini: the bars turn into the wave beside the wand, then the count") { s in
            s.model.polishes = true
            s.record(.listening, on: .gemini)
            s.wait(0.5)
            s.film("listening → processing (wave and wand)") { s.polish(on: .gemini) }
            s.model.tokenCount = PillTokenCount(phase: .thinking, tokens: 420)
            s.film("processing → counting", when: { s.model.showsCounter })
        },
        FilmScenario(name: "handsfree-polish-stop", mode: .always,
                     note: "Stop in hands-free with Polish on: the bars fade, the dots come in right of the wand") { s in
            s.model.polishes = true
            s.record(.locked, on: .gemini, startedAgo: 14)
            s.wait(0.5)
            s.film("locked → processing (wave and wand)") { s.polish(on: .gemini) }
        },
        FilmScenario(name: "chip-switch", mode: .always,
                     note: "fn ⇥ twice while listening, then the chip’s hold runs out") { s in
            s.record(.listening, on: .parakeet)
            s.wait(0.6)
            s.film("switch to Gemini: chip up, violet ring") { s.switchModel(to: .gemini) }
            s.film("back to Parakeet: chip rolls, ring goes") { s.switchModel(to: .parakeet) }
            s.film("chip goes", when: { !s.model.isChipFlashing })
        },
        FilmScenario(name: "polish-toggle", mode: .always,
                     note: "fn P on and off on Gemini: the capsule widens and the wand comes in left of the bars") { s in
            s.record(.listening, on: .gemini)
            s.wait(0.6)
            s.film("polish on (push-to-talk)") { s.model.polishes = true }
            s.wait(0.3)
            s.film("polish off (push-to-talk)") { s.model.polishes = false }
            s.record(.locked, on: .gemini, startedAgo: 14)
            s.wait(0.6)
            s.film("polish on (hands-free)") { s.model.polishes = true }
        },
        FilmScenario(name: "error-glyph-to-listening", mode: .always,
                     note: "An error flash from rest, then fn within its hold") { s in
            s.film("rest → error (shake)") { s.errorFlash() }
            s.film("error → listening (Parakeet)") { s.record(.listening, on: .parakeet) }
        },
        FilmScenario(name: "handsfree-hours", mode: .always, note: "Hands-free reaches its first hour") { s in
            s.record(.locked, on: .parakeet, startedAgo: 3600 - 1)
            s.film("the hour comes: the timer widens", when: { s.model.showsHours })
        },
        FilmScenario(name: "toast-dismiss-stacked", mode: .always, area: FilmScenario.toast,
                     note: "Two toasts over the resting pill’s slot; X on the newest: it closes, the older comes down") { s in
            s.toasts.post(Notice(dedupeKey: "engine.selected", style: .success, symbol: "waveform",
                                 title: "Now using Parakeet v3", lifetime: .seconds(30)))
            s.wait(0.6)
            let canceled = FilmScript.canceled()
            s.toasts.post(canceled)
            s.wait(1)
            s.film("X on “Dictation canceled”", for: 0.7) { s.toasts.dismiss(canceled.id) }
        },
        FilmScenario(name: "toast-dismiss-older", mode: .always, area: FilmScenario.toast,
                     note: "Two toasts over the resting pill’s slot; X on the older one, above: it goes where it is") { s in
            let older = Notice(dedupeKey: "engine.selected", style: .success, symbol: "waveform",
                               title: "Now using Parakeet v3", lifetime: .seconds(30))
            s.toasts.post(older)
            s.wait(0.6)
            s.toasts.post(FilmScript.canceled())
            s.wait(1)
            s.toasts.setPaused(true)
            s.wait(0.3)
            s.film("X on “Now using Parakeet v3”", for: 0.5) { s.toasts.dismiss(older.id) }
        },
        FilmScenario(name: "toast-trim", mode: .always, area: FilmScenario.toast,
                     note: "Two toasts up, a third comes: the oldest goes, the others move up") { s in
            s.toasts.post(Notice(dedupeKey: "engine.selected", style: .success, symbol: "waveform",
                                 title: "Now using Parakeet v3", lifetime: .seconds(30)))
            s.wait(0.6)
            s.toasts.post(FilmScript.canceled())
            s.wait(1)
            s.film("a third toast", for: 0.6) {
                s.toasts.post(Notice(dedupeKey: "mic.switched", style: .success, symbol: "laptopcomputer",
                                     title: "Switched to MacBook Pro Microphone", lifetime: .seconds(30)))
            }
        },
        FilmScenario(name: "toast-over-handsfree-expires", mode: .always, area: FilmScenario.toast,
                     note: "A toast above a hands-free pill runs out: it closes into the pill below") { s in
            s.record(.locked, on: .parakeet, startedAgo: 12)
            s.wait(0.6)
            s.toasts.post(Notice(dedupeKey: "mic.switched", style: .success, symbol: "laptopcomputer",
                                 title: "Switched to MacBook Pro Microphone", lifetime: .seconds(2.4)))
            s.film("the toast runs out", when: { s.toasts.notices.isEmpty }, for: 0.7)
        },
        FilmScenario(name: "retry-from-slot", mode: .whileDictating, area: FilmScenario.toast,
                     note: "Retry clicked on a failure card in the hidden pill’s slot: the processing pill takes its place") { s in
            let failed = Notice(dedupeKey: "transcription.failed", style: .warning, symbol: "exclamationmark.triangle",
                                title: "Gemini didn’t answer",
                                actions: [NoticeAction(title: "Retry", kind: .retry, isPrimary: true)],
                                lifetime: .seconds(10), recordingID: UUID())
            s.toasts.post(failed)
            s.wait(1)
            s.toasts.onAction = { _, action in
                guard case .retry = action.kind else { return }
                s.process(on: .gemini)
            }
            s.film("Retry: failure card → processing", for: 0.7) { s.toasts.perform(failed.actions[0], on: failed) }
        },
        FilmScenario(name: "switch-hint-to-handsfree", mode: .always,
                     note: "The Switch model hint over a long hold, then fn Space: it goes as the pill widens") { s in
            s.record(.listening, on: .parakeet)
            s.model.showsTabHint = true
            s.wait(0.8)
            s.film("listening + hint → locked") {
                s.model.showsTabHint = false
                s.record(.locked, on: .parakeet)
            }
        },
        FilmScenario(name: "chip-to-error-glyph", mode: .always,
                     note: "Gemini’s count with the chip up, then the job fails: the glyph, the chip goes as the pill narrows") { s in
            s.model.timing.chipHold = 30
            s.record(.listening, on: .gemini)
            s.wait(0.5)
            s.process(on: .gemini)
            s.switchModel(to: .gemini)
            s.model.tokenCount = PillTokenCount(phase: .thinking, tokens: 1_240)
            s.film("processing → counting", when: { s.model.showsCounter })
            s.wait(0.4)
            s.film("counting → error glyph") { s.errorFlash() }
        },
        FilmScenario(name: "peek-during-chip", mode: .always,
                     note: "Pointer on the pill as a dictation with the chip up ends: rest shows as the peek, the chip goes") { s in
            s.model.timing.chipHold = 30
            s.record(.listening, on: .gemini)
            s.switchModel(to: .gemini)
            s.wait(0.5)
            s.process(on: .gemini)
            s.model.setPointerInside(true)
            s.wait(0.5)
            s.film("processing → peek") { s.rest() }
        },
        FilmScenario(name: "rest-tooltip-to-listening", mode: .always,
                     note: "Pointer on the resting pill with its tooltip up, then fn") { s in
            s.model.setPointerInside(true)
            s.wait(0.8)
            s.film("peek + tooltip → listening") { s.record(.listening, on: .parakeet) }
        },
    ]

    /// `DictationController.postCanceled`: "Dictation canceled · Undo".
    static func canceled() -> Notice {
        Notice(dedupeKey: "dictation.canceled", style: .info, symbol: "xmark.circle", title: "Dictation canceled",
               actions: [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)], lifetime: .seconds(6),
               recordingID: UUID())
    }
}

// MARK: - Set

private struct FilmFrame {
    /// Since the change; nil for the frame just before it.
    let ms: Double?
    let image: CGImage
}

private struct FilmTake {
    let label: String
    let frames: [FilmFrame]
}

/// The real canvas in a real panel, its model and toasts, and the camera.
@MainActor
private final class FilmSet {
    static let frameInterval: CFTimeInterval = 1.0 / 60
    static let scale: CGFloat = 2

    let model: PillModel
    let toasts = ToastCenter()
    /// What is filmed, in canvas points with a bottom-left origin.
    let region: CGRect
    private(set) var takes: [FilmTake] = []
    /// Changes whose condition never came.
    private(set) var missed: [String] = []
    private let mode: PillMode
    private let panel: PillPanel
    private let host: PillHostingView

    init(mode: PillMode, area: CGSize, appearance: NSAppearance) {
        self.mode = mode
        let canvas = PillCanvasMetrics.size
        region = CGRect(x: ((canvas.width - area.width) / 2).rounded(), y: 0, width: area.width, height: area.height)
        model = PillModel(settings: .inMemory(), levelMeter: .preview(level: 0.55, animated: false))
        panel = PillPanel(size: canvas)
        // As `PillController.start()` sets it up.
        host = PillHostingView(rootView: PillCanvasView(model: model, toasts: toasts, regions: PillHitRegions()))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: canvas)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.appearance = appearance
        panel.appearance = appearance
        panel.contentView = host
        model.onVisiblePhaseChange = { [weak self] in self?.present() }
        present()
        track()
        // Off every screen: nobody sees it, and SwiftUI still draws and animates it.
        let screens = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        panel.setFrameOrigin(CGPoint(x: screens.minX - 4 * canvas.width, y: screens.minY - 4 * canvas.height))
        panel.orderFrontRegardless()
    }

    func close() {
        model.onVisiblePhaseChange = nil
        toasts.onAction = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// What `PillController.update()` decides for the model: whether the mode allows a pill, and whether it's up.
    private func present() {
        let allowed = PillVisibility.isPillAllowed(mode: mode)
        let shows = PillVisibility.showsPill(phase: model.visiblePhase, mode: mode, isHelloActive: model.isHelloActive)
        if model.isPillAllowed != allowed { model.isPillAllowed = allowed }
        if model.isPresented != shows { model.isPresented = shows }
    }

    private func track() {
        withObservationTracking {
            _ = model.visiblePhase
            _ = model.isHelloActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.present()
                self?.track()
            }
        }
    }

    // MARK: What DictationController does

    /// `refreshPill()` while recording: the phase, the dictation's model, Polish (Gemini's only), then the recording's
    /// start, which stays the same through a hold that turns hands-free.
    func record(_ phase: PillPhase, on choice: ModelChoice, startedAgo: TimeInterval? = nil) {
        let start = startedAgo.map { Date().addingTimeInterval(-$0) }
            ?? (model.visiblePhase.isRecording ? model.recordingStartedAt : nil) ?? Date()
        apply(phase, session: choice, polishes: model.polishes && choice == .gemini, start: start)
    }

    /// `refreshPill()` with a job in flight on `choice`.
    func process(on choice: ModelChoice) {
        apply(.processing, session: choice, polishes: false, start: nil)
    }

    /// `refreshPill()` with a polish in flight on `choice`: a dictation's, or Polish Selection's (`selection`).
    func polish(on choice: ModelChoice, selection: Bool = false) {
        apply(.processing, session: choice, polishes: true, selection: selection, start: nil)
    }

    /// `refreshPill()` with nothing left to do.
    func rest() {
        apply(.rest, session: nil, polishes: false, start: nil)
    }

    /// `reportNoSpeech(model:)` → `showErrorFlash`: rest first, then the words and their model, then the shake that
    /// turns the idle pill into the flash.
    func noSpeech(on choice: ModelChoice) {
        rest()
        model.errorMessage = PillMetrics.noSpeechText
        model.errorModel = choice
        model.shakeTrigger += 1
    }

    /// `flashError()` without words: the glyph and the shake.
    func errorFlash() {
        rest()
        model.errorMessage = nil
        model.errorModel = nil
        model.shakeTrigger += 1
    }

    /// `switchModel(to:)`: the chip's pulse, then `refreshPill()` with the dictation's new model.
    func switchModel(to choice: ModelChoice) {
        model.engineChipPulse &+= 1
        if model.sessionModel != choice { model.sessionModel = choice }
        if model.polishes, choice != .gemini { model.polishes = false }
    }

    private func apply(_ phase: PillPhase, session: ModelChoice?, polishes: Bool, selection: Bool = false,
                       start: Date?) {
        if model.phase != phase { model.phase = phase }
        if model.sessionModel != session { model.sessionModel = session }
        if model.polishes != polishes { model.polishes = polishes }
        if model.selectionPolishing != selection { model.selectionPolishing = selection }
        // A job's count only comes later, from its stream (the scripts set it themselves).
        if model.tokenCount != nil { model.tokenCount = nil }
        if let start {
            if model.recordingStartedAt.map({ abs($0.timeIntervalSince(start)) > 0.5 }) ?? true {
                model.recordingStartedAt = start
            }
        } else if model.recordingStartedAt != nil {
            model.recordingStartedAt = nil
        }
    }

    // MARK: Camera

    /// Lets the set run unfilmed.
    func wait(_ seconds: TimeInterval) {
        pump(until: CACurrentMediaTime() + seconds)
    }

    /// Films `change`: the frame just before it, then a frame every 1/60 s for `duration`.
    func film(_ label: String, for duration: TimeInterval = 0.6, _ change: () -> Void) {
        var frames: [FilmFrame] = []
        if let image = capture() { frames.append(FilmFrame(ms: nil, image: image)) }
        let start = CACurrentMediaTime()
        change()
        frames += roll(from: start, for: duration)
        takes.append(FilmTake(label: label, frames: frames))
    }

    /// Films a change the model or the toasts make by themselves (a hold or a lifetime running out), from the moment
    /// `condition` holds.
    func film(_ label: String, when condition: () -> Bool, timeout: TimeInterval = 5,
              for duration: TimeInterval = 0.6) {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        guard condition() else {
            missed.append(label)
            PillFilm.printError("“\(label)” didn’t happen within \(timeout) s.")
            return
        }
        let start = CACurrentMediaTime()
        var frames: [FilmFrame] = []
        if let image = capture() { frames.append(FilmFrame(ms: 0, image: image)) }
        frames += roll(from: start, for: duration)
        takes.append(FilmTake(label: label, frames: frames))
    }

    private func roll(from start: CFTimeInterval, for duration: TimeInterval) -> [FilmFrame] {
        var frames: [FilmFrame] = []
        var next = start + Self.frameInterval
        while next <= start + duration + 0.001 {
            pump(until: next)
            let now = CACurrentMediaTime()
            if let image = capture() { frames.append(FilmFrame(ms: (now - start) * 1000, image: image)) }
            // A capture that overran skips the slots it took.
            repeat { next += Self.frameInterval } while next < CACurrentMediaTime()
        }
        return frames
    }

    private func pump(until deadline: CFTimeInterval) {
        while true {
            let left = deadline - CACurrentMediaTime()
            guard left > 0 else { return }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: left))
        }
    }

    /// `region` at 2x, from the presentation layers: the animation as it stands at this instant.
    private func capture() -> CGImage? {
        guard let layer = host.layer,
              let context = CGContext(data: nil, width: Int(region.width * Self.scale),
                                      height: Int(region.height * Self.scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: Self.scale, y: Self.scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        // The hosting view's layer lays its sublayers out from the top; the context counts from the bottom.
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: layer.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        (layer.presentation() ?? layer).render(in: context)
        return context.makeImage()
    }
}

// MARK: - Reel

/// A scenario's frames, cropped to what any of them draws, written as a contact sheet and one PNG per frame.
@MainActor
private struct FilmReel {
    let takes: [FilmTake]
    let region: CGRect
    /// In pixels of the captured region (top-left origin).
    private let crop: CGRect
    private let pixels: [[FilmPixels]]

    init(takes: [FilmTake], region: CGRect) {
        self.takes = takes
        self.region = region
        pixels = takes.map { $0.frames.map { FilmPixels($0.image) } }
        let margin = 6 * FilmSet.scale
        let full = CGRect(x: 0, y: 0, width: region.width * FilmSet.scale, height: region.height * FilmSet.scale)
        let drawn = pixels.joined().compactMap(\.drawnBounds).reduce(CGRect.null) { $0.union($1) }
        crop = drawn.isNull ? full : drawn.insetBy(dx: -margin, dy: -margin).intersection(full).integral
    }

    /// The opaque extent of the pill's row (canvas y 24-52 pt), in points: the capsule, or a toast in its slot.
    private func rowWidth(_ pixels: FilmPixels) -> Double? {
        let top = Int((region.maxY - PillCanvasMetrics.pillBottomInset - PillMetrics.maxHeight) * FilmSet.scale)
        let bottom = Int((region.maxY - PillCanvasMetrics.pillBottomInset) * FilmSet.scale)
        return pixels.opaqueWidth(rows: top..<bottom).map { Double($0) / FilmSet.scale }
    }

    var summary: [String] {
        zip(takes, pixels).map { take, pixels in
            let distinct = Set(pixels.map(\.digest)).count
            let times = take.frames.compactMap(\.ms)
            let gap = zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? 0
            let widths = pixels.map { rowWidth($0).map { String(format: "%.0f", $0) } ?? "-" }
            return "\(take.label): \(take.frames.count) frames, \(distinct) distinct, gaps ≤ \(Int(gap.rounded())) ms; "
                + "pill row width " + widths.joined(separator: " ")
        }
    }

    func write(title: String, note: String, dark: Bool, sheet: URL, frames dir: URL) throws {
        let backdrop = dark ? CGColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1)
                            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cells: [[FilmCell]] = []
        for (t, take) in takes.enumerated() {
            var row: [FilmCell] = []
            for (f, frame) in take.frames.enumerated() {
                guard let image = Self.composite(frame.image, crop: crop, over: backdrop) else { continue }
                let file = frame.ms.map { String(format: "%03.0fms", $0) } ?? "before"
                try Self.writePNG(image, to: dir.appendingPathComponent(String(format: "%d-%02d-%@.png", t + 1, f, file)))
                row.append(FilmCell(image: image, caption: frame.ms.map { String(format: "%.0f ms", $0) } ?? "before",
                                    detail: rowWidth(pixels[t][f]).map { String(format: "%.0f pt", $0) } ?? ""))
            }
            cells.append(row)
        }
        let size = CGSize(width: crop.width / FilmSet.scale, height: crop.height / FilmSet.scale)
        let renderer = ImageRenderer(content: FilmContactSheet(title: title, note: note, labels: takes.map(\.label),
                                                               cells: cells, cell: size, dark: dark))
        renderer.scale = FilmSet.scale
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        try Self.writePNG(image, to: sheet)
    }

    private static func composite(_ image: CGImage, crop: CGRect, over backdrop: CGColor) -> CGImage? {
        guard let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        context.setFillColor(backdrop)
        context.fill(rect)
        context.draw(cropped, in: rect)
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// A frame's RGBA bytes (premultiplied, rows from the top), for measuring and comparing.
private struct FilmPixels {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let data: Data

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        bytesPerRow = image.bytesPerRow
        data = (image.dataProvider?.data as Data?) ?? Data()
    }

    /// Of every byte (`Data`'s own hash only looks at the first few).
    var digest: Int {
        var hasher = Hasher()
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    private func alpha(_ x: Int, _ y: Int) -> UInt8 {
        data[y * bytesPerRow + x * 4 + 3]
    }

    /// Everything not quite transparent (a shadow's faint edge included).
    var drawnBounds: CGRect? {
        guard !data.isEmpty else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 2 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Pixels across what is nearly opaque in `rows` (the capsule's fill, not its shadow).
    func opaqueWidth(rows: Range<Int>) -> Int? {
        guard !data.isEmpty else { return nil }
        var minX = width, maxX = -1
        for y in rows.clamped(to: 0..<height) {
            for x in 0..<width where alpha(x, y) > 230 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        return maxX >= 0 ? maxX - minX + 1 : nil
    }
}

private struct FilmCell {
    let image: CGImage
    let caption: String
    let detail: String
}

/// Every take of a scenario: its label, then its frames in rows, each under its time and the pill row's width.
private struct FilmContactSheet: View {
    let title: String
    let note: String
    let labels: [String]
    let cells: [[FilmCell]]
    let cell: CGSize
    let dark: Bool

    private var columns: Int { max(1, min(10, Int(1500 / (cell.width + 4)))) }
    private var ink: Color { dark ? .white : .black }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(note).font(.system(size: 12)).foregroundStyle(ink.opacity(0.6))
            ForEach(labels.indices, id: \.self) { t in
                Text("\(t + 1). \(labels[t])")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(stride(from: 0, to: cells[t].count, by: columns)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 4) {
                            ForEach(start..<min(start + columns, cells[t].count), id: \.self) { i in
                                frame(cells[t][i])
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(ink)
        .padding(16)
        .background(dark ? Color(white: 0.04) : Color(white: 0.86))
    }

    private func frame(_ cell: FilmCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(cell.caption)
                Spacer(minLength: 4)
                Text(cell.detail).foregroundStyle(ink.opacity(0.4))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(ink.opacity(0.7))
            Image(decorative: cell.image, scale: FilmSet.scale)
        }
        .frame(width: self.cell.width)
    }
}

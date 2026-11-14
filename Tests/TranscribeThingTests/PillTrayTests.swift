import Foundation
import Testing
@testable import TranscribeThing

/// The tray beside the pill and the pills stacked above it, as the model keeps them.
@MainActor
@Suite(.serialized) struct PillTrayModelTests {
    static func model(_ phase: PillPhase) -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: .preview(level: 0.5))
        model.timing.hoverIn = 0.01
        model.timing.controlTooltipDelay = 0.01
        model.phase = phase
        return model
    }

    /// The pointer on a pill with a dictation opens its tray after the short dwell; leaving, it goes at once.
    @Test func theTrayOpensOnHoverAndGoesAtOnce() async throws {
        let model = Self.model(.listening)
        model.tray = PillTrayState(dictation: .recording)
        #expect(!model.showsTray(.bottom))
        model.setPointerOverTray(.bottom)
        try await waitUntil { model.showsTray(.bottom) }
        model.setPointerOverTray(nil)
        #expect(!model.showsTray(.bottom), "gone the moment the pointer left")
        model.setPointerOverTray(.bottom)
        #expect(!model.showsTray(.bottom), "back: the dwell again")
        try await waitUntil { model.showsTray(.bottom) }
    }

    /// No tray at rest or without a dictation's state, and none with the pill not on screen (Never).
    @Test func noTrayWithoutADictation() {
        let rest = Self.model(.rest)
        rest.tray = PillTrayState(dictation: .recording)
        rest.showTray(.bottom)
        #expect(!rest.showsTray(.bottom))
        let none = Self.model(.processing)
        none.showTray(.bottom)
        #expect(!none.showsTray(.bottom))
        let hidden = Self.model(.listening)
        hidden.tray = PillTrayState(dictation: .recording)
        hidden.isPresented = false
        hidden.showTray(.bottom)
        #expect(!hidden.showsTray(.bottom))
    }

    /// A hovered button's shortcut shows over it after a short dwell, and goes with the pointer; Polish and Translate
    /// dimmed say why to VoiceOver.
    @Test func aButtonsHint() async throws {
        let model = Self.model(.processing)
        let button = PillTrayButton(owner: .bottom, toggle: .translate)
        model.setHoveredTrayButton(button)
        #expect(model.hoveredTrayButton == button && model.trayHint == nil, "not at once")
        try await waitUntil { model.trayHint == button }
        #expect(!model.trayHintCarriesOver)
        // Up already: the next button's comes at once, even across the gap between them.
        model.setHoveredTrayButton(nil)
        let next = PillTrayButton(owner: .bottom, toggle: .polish)
        model.setHoveredTrayButton(next)
        #expect(model.trayHint == next && model.trayHintCarriesOver, "straight over, no dwell")
        model.setHoveredTrayButton(nil)
        try await waitUntil { model.trayHint == nil }
        model.setHoveredTrayButton(button)
        #expect(model.trayHint == nil, "after a while off the buttons, the dwell again")
        #expect(PillTrayState.reason(.translate) == "Gemini only")
        let parakeet = PillTrayState(dictation: .processing(UUID()), rewrites: false)
        #expect(!parakeet.isEnabled(.polish) && !parakeet.isEnabled(.translate) && parakeet.isEnabled(.send))
    }

    /// Each stacked dictation gets a pill model of its own, drawing it processing with its own glyphs, edge and
    /// count; one that leaves the stack drops its model, and its open tray closes.
    @Test func eachStackedPillHasItsOwnModel() {
        let model = Self.model(.listening)
        let a = UUID(), b = UUID()
        model.setStack([
            PillStackItem(key: a, choice: .gemini, tray: PillTrayState(dictation: .processing(a), polishes: true)),
            PillStackItem(key: b, choice: .parakeet, tray: PillTrayState(dictation: .processing(b), rewrites: false),
                          holdsPaste: true),
        ])
        let first = try? #require(model.stackModels[a]), second = try? #require(model.stackModels[b])
        #expect(first?.visiblePhase == .processing && first?.polishes == true && first?.sessionModel == .gemini)
        #expect(second?.holdsPaste == true && second?.sessionModel == .parakeet)
        model.showTray(.stacked(b))
        #expect(model.showsTray(.stacked(b)) && model.trayState(.stacked(b))?.rewrites == false)
        model.setStack([model.stack[0]])
        #expect(model.stackModels[b] == nil && model.openTray == nil)
        #expect(model.stackModels[a] === first, "the same model as it was")
    }

    /// Clicks on tray buttons go to the controller with the pill's dictation.
    @Test func aClickNamesItsDictation() {
        let model = Self.model(.processing)
        let key = UUID()
        model.tray = PillTrayState(dictation: .processing(key))
        var clicked: [(PillToggle, PillDictation)] = []
        model.onToggle = { clicked.append(($0, $1)) }
        model.clickTray(.send)
        #expect(clicked.count == 1 && clicked[0].0 == .send && clicked[0].1 == .processing(key))
    }

    /// The stack's height for the toasts: three pills, then "+N".
    @Test func theStacksHeight() {
        #expect(PillStackMetrics.height(for: 0) == 0)
        #expect(PillStackMetrics.height(for: 1) == PillStackMetrics.pillHeight + PillStackMetrics.gap)
        #expect(PillStackMetrics.height(for: 3) == PillStackMetrics.height(for: 9)
                - PillStackMetrics.moreHeight - PillStackMetrics.gap)
        #expect(PillCanvasView.toastBottomPadding(pillOnScreen: true, showsChip: false, stackHeight: 32)
                == PillCanvasMetrics.toastLift + 32)
    }

    /// The tray fits the canvas beside the widest pill.
    @Test func theTrayFitsBesideTheWidestPill() {
        let widest = PillVisual.locked(hours: true, polishes: true, sends: true).size.width
        #expect(widest / 2 + PillTrayMetrics.gap + PillTrayMetrics.width + 8 < PillCanvasMetrics.size.width / 2)
        #expect(PillTrayMetrics.height <= PillMetrics.maxHeight)
    }
}

/// Polish, Translate and Send are on the Shortcuts page and the pill both: fn P, fn T and fn ↩ by default.
@Suite struct ShortcutsPageRowsTests {
    @Test func theThreeRowsAreBack() {
        let actions = ShortcutAction.allCases.map(\.rawValue)
        #expect(actions == ["pushToTalk", "handsFree", "pasteLast", "switchModel", "polish", "addToDictionary",
                            "translate", "send"])
        #expect(ShortcutBindings.defaults[.polish] == .fnP && ShortcutBindings.defaults[.translate] == .fnT)
        #expect(ShortcutBindings.defaults[.send] == .fnReturn)
    }
}

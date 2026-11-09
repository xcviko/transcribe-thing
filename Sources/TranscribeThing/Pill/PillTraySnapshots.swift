import SwiftUI

/// The pill's tray and the stacked pills, in the real panel canvas (`--snapshots <dir> --only pill-tray`, `pill-stack`):
/// each row on a document (light) and on a dark editor, the canvas cut to its bottom.
enum PillTraySnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [
            SnapshotEntry("pill-tray-recording", width: PillTraySheet.width, height: PillTraySheet.height(recordingRows)) { _ in
                PillTraySheet(title: "Tray while recording", rows: recordingRows)
            },
            SnapshotEntry("pill-tray-processing", width: PillTraySheet.width, height: PillTraySheet.height(processingRows)) { _ in
                PillTraySheet(title: "Tray while processing", rows: processingRows)
            },
            SnapshotEntry("pill-stack", width: PillTraySheet.width, height: PillTraySheet.height(stackRows)) { _ in
                PillTraySheet(title: "Dictations on their way", rows: stackRows)
            },
        ]
    }

    // MARK: Rows

    @MainActor static var recordingRows: [PillTraySheet.Row] {
        [
            .init(id: "rec-off", caption: "Push-to-talk · Gemini · all off · Polish’s tooltip") {
                recording(.listening, tooltip: .polish)
            },
            .init(id: "rec-polish", caption: "Polish on") { recording(.listening, polishes: true) },
            .init(id: "rec-translate", caption: "Translate on") { recording(.listening, translates: true) },
            .init(id: "rec-send", caption: "Send on · its tooltip") {
                recording(.listening, sends: true, tooltip: .send)
            },
            .init(id: "rec-all", caption: "Hands-free · all three on") {
                recording(.locked, polishes: true, translates: true, sends: true)
            },
            .init(id: "rec-parakeet", caption: "Push-to-talk · Parakeet · Polish works on selected text") {
                recording(.listening, choice: .parakeet)
            },
            .init(id: "rec-closed", caption: "Pointer elsewhere: no tray") { recording(.listening, open: false) },
        ]
    }

    @MainActor static var processingRows: [PillTraySheet.Row] {
        [
            .init(id: "proc-gemini", caption: "Gemini · thinking · all off") {
                processing(choice: .gemini, count: PillTokenCount(phase: .thinking, tokens: 480))
            },
            .init(id: "proc-polish", caption: "Polish clicked · sent again") {
                processing(choice: .gemini, polishes: true, tooltip: .polish)
            },
            .init(id: "proc-send", caption: "Send on · writing") {
                processing(choice: .gemini, sends: true, count: PillTokenCount(phase: .writing, tokens: 36))
            },
            .init(id: "proc-parakeet", caption: "Parakeet · Polish and Translate dimmed") {
                processing(choice: .parakeet, rewrites: false, tooltip: .translate)
            },
            .init(id: "proc-held", caption: "Clicked away · Send dimmed") {
                processing(choice: .gemini, held: true, tooltip: .send)
            },
        ]
    }

    @MainActor static var stackRows: [PillTraySheet.Row] {
        [
            .init(id: "stack-two", caption: "Two: recording under one on its way", height: 150) {
                stacked(bottom: .listening, items: [item(.gemini, count: PillTokenCount(phase: .thinking, tokens: 820))])
            },
            .init(id: "stack-four", caption: "Four: one dashed (clicked away)", height: 220) {
                stacked(bottom: .processing, items: [
                    item(.gemini, polishes: true),
                    item(.parakeet, held: true),
                    item(.gemini, sends: true, count: PillTokenCount(phase: .writing, tokens: 140)),
                ])
            },
            .init(id: "stack-tray", caption: "A stacked pill’s tray", height: 180) {
                let items = [item(.gemini, translates: true), item(.gemini)]
                let model = stacked(bottom: .locked, items: items)
                model.showTray(.stacked(items[1].key),
                               tooltip: PillTrayButton(owner: .stacked(items[1].key), toggle: .polish))
                return model
            },
            .init(id: "stack-more", caption: "Six: the oldest fold into +2", height: 230) {
                stacked(bottom: .listening, items: [
                    item(.gemini), item(.gemini, polishes: true), item(.parakeet),
                    item(.gemini), item(.gemini),
                ])
            },
        ]
    }

    // MARK: Models

    @MainActor private static func recording(_ phase: PillPhase, choice: ModelChoice = .gemini, polishes: Bool = false,
                                             translates: Bool = false, sends: Bool = false, open: Bool = true,
                                             tooltip: PillToggle? = nil) -> PillModel {
        let model = PillModel.preview(phase: phase, level: 0.6)
        model.sessionModel = choice
        model.polishes = polishes && choice.isGemini
        model.translates = translates && choice.isGemini
        model.sends = sends
        model.tray = PillTrayState(dictation: .recording, polishes: model.polishes, translates: model.translates,
                                   sends: sends)
        if open { model.showTray(.bottom, tooltip: tooltip.map { PillTrayButton(owner: .bottom, toggle: $0) }) }
        return model
    }

    @MainActor private static func processing(choice: ModelChoice, polishes: Bool = false, sends: Bool = false,
                                              rewrites: Bool = true, held: Bool = false,
                                              count: PillTokenCount? = nil, tooltip: PillToggle? = nil) -> PillModel {
        let model = PillModel.preview(phase: .processing)
        model.sessionModel = choice
        model.polishes = polishes
        model.sends = sends && !held
        model.holdsPaste = held
        let key = UUID()
        model.tray = PillTrayState(dictation: .processing(key), polishes: polishes, sends: sends && !held,
                                   rewrites: rewrites && choice.isGemini, canSend: !held)
        if let count { _ = model.previewCounter(count) }
        model.showTray(.bottom, tooltip: tooltip.map { PillTrayButton(owner: .bottom, toggle: $0) })
        return model
    }

    private static func item(_ choice: ModelChoice, polishes: Bool = false, translates: Bool = false,
                             sends: Bool = false, held: Bool = false, count: PillTokenCount? = nil) -> PillStackItem {
        let key = UUID()
        return PillStackItem(key: key, choice: choice,
                             tray: PillTrayState(dictation: .processing(key), polishes: polishes,
                                                 translates: translates, sends: sends && !held,
                                                 rewrites: choice.isGemini, canSend: !held),
                             holdsPaste: held, count: count)
    }

    /// `items`, the nearest first, above a bottom pill in `bottom`.
    @MainActor private static func stacked(bottom: PillPhase, items: [PillStackItem]) -> PillModel {
        let model = PillModel.preview(phase: bottom, level: 0.6)
        model.sessionModel = .gemini
        model.tray = PillTrayState(dictation: bottom == .processing ? .processing(UUID()) : .recording)
        model.setStack(items)
        for item in items {
            if let count = item.count { _ = model.stackModels[item.key]?.previewCounter(count) }
        }
        return model
    }
}

/// Rows of the panel canvas, cut to its bottom, on a document and on a dark editor.
struct PillTraySheet: View {
    struct Row: Identifiable {
        let id: String
        let caption: String
        var height: CGFloat = 110
        let make: @MainActor () -> PillModel
    }

    static let captionWidth: CGFloat = 220
    static let header: CGFloat = 44
    static let width: CGFloat = captionWidth + 2 * PillCanvasMetrics.size.width

    static func height(_ rows: [Row]) -> CGFloat {
        header + rows.reduce(0) { $0 + $1.height }
    }

    let title: String
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title).frame(width: Self.captionWidth, alignment: .leading)
                Text("On a document").frame(maxWidth: .infinity)
                Text("On a dark editor").frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.inkTertiary)
            .padding(.leading, 24)
            .frame(height: Self.header)

            ForEach(rows) { row in
                HStack(spacing: 0) {
                    Text(row.caption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                        .frame(width: Self.captionWidth - 24, alignment: .leading)
                        .padding(.leading, 24)
                    ForEach([false, true], id: \.self) { dark in
                        PillCanvasView(model: row.make(), toasts: .preview([]))
                            .frame(width: PillCanvasMetrics.size.width, height: row.height)
                            .background(alignment: .top) { TraySheetPage(dark: dark) }
                        .clipped()
                    }
                }
                .frame(height: row.height)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.stroke).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgCanvas)
        .environment(\.pillStaticRendering, true)
    }
}

/// A page of text lines behind the pill: white in light, an editor's gray in dark.
private struct TraySheetPage: View {
    var dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<16, id: \.self) { i in
                Capsule()
                    .fill(dark ? Color.white.opacity(0.09) : Color.black.opacity(0.075))
                    .frame(width: 400 * [0.82, 0.64, 0.9, 0.48, 0.76, 0.58, 0.86, 0.7][i % 8], height: 5)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(nsColor: .hex(0x1E1E21)) : .white)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

import AppKit
import SwiftUI

/// Visual QA for the shell's own artwork: the menu bar glyph in its three states on light and dark bars.
enum ShellSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [SnapshotEntry("shell-menubar", width: 420, height: 150) { _ in MenuBarPreview() }]
    }
}

private struct MenuBarPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            bar(dark: false)
            bar(dark: true)
        }
        .background(Color.bgCanvas)
    }

    private func bar(dark: Bool) -> some View {
        HStack(spacing: 18) {
            Spacer()
            glyph(state: "idle", dark: dark)
            glyph(state: "recording", dark: dark)
            glyph(state: "processing", dark: dark)
            Image(systemName: "wifi").foregroundStyle(dark ? .white : .black)
            Text("Wed 3:41 PM").font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? .white : .black)
        }
        .padding(.horizontal, 16)
        .frame(height: 75)
        .background(dark ? Color(white: 0.12) : Color(white: 0.93))
    }

    private func glyph(state: String, dark: Bool) -> some View {
        let tint: Color = dark ? .white : .black
        let size = MenuBarIcon.size
        return ZStack(alignment: .topLeading) {
            Image(nsImage: MenuBarIcon.template(badgeHole: state == "recording"))
                .renderingMode(.template)
                .foregroundStyle(tint)
                .opacity(state == "processing" ? 0.45 : 1)
            if state == "recording" {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: MenuBarIcon.badgeDiameter, height: MenuBarIcon.badgeDiameter)
                    .offset(x: MenuBarIcon.badgeCenter.x - MenuBarIcon.badgeDiameter / 2,
                            y: size.height - MenuBarIcon.badgeCenter.y - MenuBarIcon.badgeDiameter / 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(.horizontal, 3)
    }
}

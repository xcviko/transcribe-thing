import AppKit
import SwiftUI

/// Visual QA for the shell's own artwork: the menu bar glyph, idle and pulsing (transcribing), on light and dark bars.
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
            glyph(processing: false, dark: dark)
            glyph(processing: true, dark: dark)
            Image(systemName: "wifi").foregroundStyle(dark ? .white : .black)
            Text("Wed 3:41 PM").font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? .white : .black)
        }
        .padding(.horizontal, 16)
        .frame(height: 75)
        .background(dark ? Color(white: 0.12) : Color(white: 0.93))
    }

    private func glyph(processing: Bool, dark: Bool) -> some View {
        let tint: Color = dark ? .white : .black
        let size = MenuBarIcon.size
        return Image(nsImage: MenuBarIcon.template())
            .renderingMode(.template)
            .foregroundStyle(tint)
            .opacity(processing ? 0.45 : 1)
            .frame(width: size.width, height: size.height)
            .padding(.horizontal, 3)
    }
}

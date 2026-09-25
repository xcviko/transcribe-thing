import SwiftUI

// STUB (FOUNDATION): SYSTEM replaces this with the capturing recorder (local monitor, validation, Swap).
struct ShortcutRecorderView: View {
    @Binding var shortcut: Shortcut?
    let action: ShortcutAction

    init(shortcut: Binding<Shortcut?>, action: ShortcutAction) {
        self._shortcut = shortcut
        self.action = action
    }

    var body: some View {
        HStack(spacing: 8) {
            ShortcutChips(shortcut: shortcut)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 140, minHeight: 32)
        .background(.bgSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(.stroke, lineWidth: 1)
        }
        .accessibilityLabel("\(action.title) shortcut")
    }
}

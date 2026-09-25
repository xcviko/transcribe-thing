import SwiftUI

// STUB (FOUNDATION): HUB replaces this with the real sidebar and pages.
struct HubView: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var windows = env.windows
        NavigationSplitView {
            List(HubSection.allCases, selection: Binding<HubSection?>(
                get: { windows.hubSection },
                set: { if let s = $0 { windows.hubSection = s } }
            )) { section in
                Label(section.title, systemImage: section.symbolName).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(windows.hubSection.title).typeface(.title).foregroundStyle(.ink)
                Card { Text("Coming soon.").typeface(.body).foregroundStyle(.inkSecondary) }
                Spacer()
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.bgCanvas)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

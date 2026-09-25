import SwiftUI

/// One PNG to render: `name` becomes `<name>-<appearance>.png`.
struct SnapshotEntry {
    let name: String
    let size: CGSize
    let make: @MainActor (AppEnvironment) -> AnyView

    init(name: String, size: CGSize, make: @escaping @MainActor (AppEnvironment) -> AnyView) {
        self.name = name
        self.size = size
        self.make = make
    }

    /// Convenience for `SnapshotEntry("hub-home", width: 980, height: 680) { env in HubView(env: env) }`.
    init<V: View>(_ name: String, width: CGFloat, height: CGFloat,
                  @ViewBuilder content: @escaping @MainActor (AppEnvironment) -> V) {
        self.init(name: name, size: CGSize(width: width, height: height)) { env in AnyView(content(env)) }
    }
}

enum SnapshotCatalog {
    @MainActor static var all: [SnapshotEntry] {
        PillSnapshots.entries + OnboardingSnapshots.entries + HubSnapshots.entries + DesignSnapshots.entries
    }
}

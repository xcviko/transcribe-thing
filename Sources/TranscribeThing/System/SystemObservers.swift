import AppKit

/// A notification observation that ends when the token is released. The handler runs on the main actor.
final class MainNotificationObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    @MainActor
    init(center: NotificationCenter, name: Notification.Name, object: AnyObject? = nil,
         handler: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main, using: mainQueueHandler(handler))
    }

    deinit {
        center.removeObserver(token)
    }
}

/// A distributed (cross-process) notification observation; the handler runs on the main actor.
final class MainDistributedObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    @MainActor
    init(name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        token = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main, using: mainQueueHandler(handler))
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}

/// Main-actor closures registered with `queue: .main` only ever run on the main queue; the box carries
/// them across the Sendable parameter.
private struct HandlerBox: @unchecked Sendable {
    let handler: @MainActor () -> Void
}

/// Built outside the main actor so the stored Sendable closure isn't inferred as main-actor isolated.
private func mainQueueHandler(_ handler: @escaping @MainActor () -> Void) -> @Sendable (Notification) -> Void {
    let box = HandlerBox(handler: handler)
    return { _ in MainActor.assumeIsolated { box.handler() } }
}

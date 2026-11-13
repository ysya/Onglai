import Foundation

enum AppLoadCoordinator {
    @MainActor
    static func start(
        clear: () -> Void,
        load: @escaping @Sendable () -> Void
    ) {
        clear()
        DispatchQueue.global(qos: .userInitiated).async(execute: load)
    }
}

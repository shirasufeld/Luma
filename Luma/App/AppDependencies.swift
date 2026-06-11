import Foundation

/// Composition root. Creates production service implementations and hands
/// them to the UI as protocols so views and view models never touch system
/// frameworks directly.
@MainActor
final class AppDependencies {
    let capabilities: any CapabilityChecking

    init(capabilities: any CapabilityChecking = CapabilityService()) {
        self.capabilities = capabilities
    }
}

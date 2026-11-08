import CoreGraphics
import Foundation

enum PopoverRoute: Equatable {
    case main
    case detail(ModuleID)
}

/// Navigation inside the popover: the main view or one module's detail view.
/// Keeps `ModuleRegistry` informed so detail-only sampling runs exactly while
/// a detail view is on screen.
@MainActor
final class PopoverRouter: ObservableObject {
    @Published private(set) var route: PopoverRoute = .main

    /// Tallest the popover content may get before detail views scroll.
    /// `MenuBarController` updates it from the status item's screen.
    @Published var maxContentHeight: CGFloat = 640

    /// True while the panel is off screen. The popover then renders nothing,
    /// so status changes do not re-render a view nobody can see.
    @Published private(set) var isPanelHidden = false

    private let registry: ModuleRegistry

    init(registry: ModuleRegistry) {
        self.registry = registry
        registry.onModuleDeactivated = { [weak self] id in
            guard let self, self.route == .detail(id) else { return }
            self.route = .main
        }
    }

    func open(_ id: ModuleID) {
        guard registry.visibleModules.contains(id), route != .detail(id) else { return }
        if case .detail(let current) = route {
            registry.detailDidClose(current)
        }
        route = .detail(id)
        registry.detailDidOpen(id)
    }

    func back() {
        guard case .detail(let id) = route else { return }
        registry.detailDidClose(id)
        route = .main
    }

    /// Escape goes back from a detail view before it closes the popover.
    /// Returns true when it was handled here.
    func handleCancel() -> Bool {
        guard route != .main else { return false }
        back()
        return true
    }

    /// The popover always reopens on the main view. Called before the panel is
    /// measured and shown, while it is still hidden.
    func popoverWillOpen() {
        route = .main
        isPanelHidden = false
    }

    /// Called once the panel has been ordered out (after the fade-out).
    func panelDidHide() {
        isPanelHidden = true
    }

    /// Detail work stops as soon as the popover starts closing. The route is
    /// left in place so the content does not change during the fade-out.
    func popoverDidClose() {
        if case .detail(let id) = route {
            registry.detailDidClose(id)
        }
    }
}

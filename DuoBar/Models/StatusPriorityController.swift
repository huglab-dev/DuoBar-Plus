import Combine
import Foundation

@MainActor
final class StatusPriorityController: ObservableObject {
    @Published private(set) var presentation: StatusPresentation = .normal

    private var pendingEvents: [StatusEvent] = []
    private var dismissalTask: Task<Void, Never>?

    func present(_ event: StatusEvent) {
        guard presentation.event?.kind != event.kind else { return }

        if let active = presentation.event {
            if event.priority > active.priority {
                pendingEvents.append(active)
                begin(event)
            } else {
                pendingEvents.append(event)
                pendingEvents.sort { $0.priority > $1.priority }
            }
        } else {
            begin(event)
        }
    }

    func returnToNormal() {
        dismissalTask?.cancel()
        dismissalTask = nil
        pendingEvents.removeAll()
        presentation = .normal
    }

    private func begin(_ event: StatusEvent) {
        dismissalTask?.cancel()
        presentation = .event(event)

        dismissalTask = Task { [weak self] in
            let nanoseconds = UInt64(event.duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finish(eventID: event.id)
        }
    }

    private func finish(eventID: UUID) {
        guard presentation.event?.id == eventID else { return }

        if pendingEvents.isEmpty {
            presentation = .normal
            dismissalTask = nil
        } else {
            let next = pendingEvents.removeFirst()
            begin(next)
        }
    }
}

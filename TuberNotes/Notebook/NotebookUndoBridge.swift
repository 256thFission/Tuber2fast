import Combine
import Foundation

/// Owns the undo manager used by the active notebook drawing layer.
///
/// `NotebookView` rebuilds the canvas when the active drawing layer changes, so
/// the bridge lives on `NotebookViewModel` and is handed to both the canvas and
/// the controls that expose undo/redo.
@MainActor
final class NotebookUndoBridge: ObservableObject {
    let manager = UndoManager()

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var observers: [NSObjectProtocol] = []

    init() {
        manager.groupsByEvent = true
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerCheckpoint,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: manager,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func refresh() {
        if canUndo != manager.canUndo { canUndo = manager.canUndo }
        if canRedo != manager.canRedo { canRedo = manager.canRedo }
    }

    func undo() {
        guard manager.canUndo else { return }
        manager.undo()
        refresh()
    }

    func redo() {
        guard manager.canRedo else { return }
        manager.redo()
        refresh()
    }

    /// Undo history belongs to one active drawing layer and is reset whenever
    /// the canvas loads a different layer or an external drawing replacement.
    func reset() {
        manager.removeAllActions()
        refresh()
    }

    func withoutRegistration(_ body: () -> Void) {
        manager.disableUndoRegistration()
        defer { manager.enableUndoRegistration() }
        body()
    }
}

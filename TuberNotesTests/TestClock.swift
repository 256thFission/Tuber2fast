import Foundation
import Testing

/// A clock whose time only moves when a test moves it.
///
/// The suite used to prove things about the debounce by sleeping past it —
/// "wait 250 ms, nothing may have saved yet" — which makes the machine's load
/// part of the assertion. Under a busy machine the wait overran the interval
/// it was meant to sit inside and the test failed for a reason that had
/// nothing to do with the code. Widening the margin only moves the load at
/// which it happens.
///
/// With this clock the interval cannot elapse at all unless the test elapses
/// it, so "nothing saved before the floor" is a fact about the code rather
/// than about the machine. It is injected at the one seam that sleeps —
/// `EditorSession`'s debounce — and the app's default stays `ContinuousClock`.
///
/// Waiting on a *condition* is a different thing and stays real: `waitUntil`
/// polls until something is true, so it is already load-immune. What this
/// replaces is only the sleeps that were standing in for a deadline.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        static func == (lhs: Instant, rhs: Instant) -> Bool { lhs.offset == rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: UnsafeContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0

    var now: Instant { lock.withLock { current } }

    /// Zero, because this clock has no tick: it is exactly as fine-grained as
    /// the test asks it to be.
    var minimumResolution: Duration { .zero }

    /// How many sleeps are outstanding. `waitUntilSleeping` is how a test uses
    /// it; it is exposed because "the debounce is armed" is otherwise not
    /// observable, and advancing before it is armed would prove nothing.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }

        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in
                enum Immediate { case cancelled, due, waiting }
                let outcome: Immediate = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancelled }
                    if current >= deadline { return .due }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .waiting
                }
                switch outcome {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .waiting: break
                }
            }
        } onCancel: {
            let waiter: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    // Cancelled before the continuation was installed; the
                    // installation resumes it instead.
                    cancelled.insert(id)
                    return nil
                }
                return sleepers.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes everything that was waiting for it, in
    /// deadline order, then hands the executor around enough times for the
    /// woken work to run. A test that advances and asserts immediately is
    /// asserting about work that has not happened yet.
    func advance(by duration: Duration) async {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return ready.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
        for _ in 0..<20 { await Task.yield() }
    }

    /// Waits until something is sleeping on this clock.
    ///
    /// The wait is on a condition, not a duration: it returns as soon as the
    /// sleep is registered, however long the machine took to get there, and
    /// records an issue rather than hanging if it never is. A timer that was
    /// never armed is a real failure — it is what "the debounce did not fire"
    /// looks like from here.
    func waitUntilSleeping(
        _ what: String = "a sleep to be registered",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for attempt in 0..<2_000 {
            if sleeperCount > 0 { return }
            if attempt % 20 == 19 {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return  // the test itself was cancelled; nothing to report
                }
            } else {
                await Task.yield()
            }
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }
}

// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Runs at most one operation at a time and shares the first success with
/// every later caller.
///
/// Built for the loopback HTTP server's `initialize`: the SDK server accepts
/// one `initialize`, so the first must be forwarded and its result handed to
/// every other client, including clients that arrive while it is in flight.
///
/// A caller either forwarded the operation itself (`.own`, with whatever came
/// back, success or failure) or received the shared success (`.shared`). A
/// caller that waited on an attempt that failed takes over as the next
/// forwarder, so nothing ever runs the operation outside this actor.
public actor SharedFirstSuccess<Outcome: Sendable, Shared: Sendable> {
    public enum Result: Sendable {
        case shared(Shared)
        case own(Outcome)
    }

    private let success: @Sendable (Outcome) -> Shared?
    private var shared: Shared?
    private var pending: Task<Outcome, Never>?

    /// - Parameter success: the value to share when an outcome succeeded, or
    ///   nil when it failed.
    public init(success: @escaping @Sendable (Outcome) -> Shared?) {
        self.success = success
    }

    public func run(_ operation: @escaping @Sendable () async -> Outcome) async -> Result {
        while true {
            if let shared { return .shared(shared) }
            if let inFlight = pending {
                // Read the outcome from the task itself: the forwarder may not
                // have resumed yet, so `shared` and `pending` can still be stale
                // here. Re-checking them instead spins on the actor and starves
                // the forwarder.
                let outcome = await inFlight.value
                if let value = success(outcome) {
                    shared = value
                    return .shared(value)
                }
                if pending == inFlight { pending = nil }
                continue
            }
            let task = Task { await operation() }
            pending = task
            let outcome = await task.value
            if pending == task { pending = nil }
            if let value = success(outcome) { shared = value }
            return .own(outcome)
        }
    }
}

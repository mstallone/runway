import Foundation

/// Thrown by `withDeadline` when the operation is still running at the deadline.
struct DeadlineExceeded: Error, Equatable {}

/// Race `operation` against a wall-clock deadline. `URLRequest`'s timeout only fires on an idle
/// connection, so a response that keeps streaming has no upper bound without this. The loser is
/// cancelled, which cancels an in-flight `URLSession` request.
///
/// Only a bound for operations that honor cancellation: the group waits for the cancelled operation
/// to exit before this returns, so work that ignores cancellation still runs to its end.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw DeadlineExceeded() }
        return result
    }
}

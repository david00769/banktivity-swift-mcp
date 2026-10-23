// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityMCPLib

/// Counts how many times an operation actually ran.
private actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

@Suite("Shared first success", .timeLimit(.minutes(1)))
struct SharedFirstSuccessTests {

    private func results(
        _ gate: SharedFirstSuccess<Int, Int>, callers: Int,
        operation: @escaping @Sendable () async -> Int
    ) async -> [SharedFirstSuccess<Int, Int>.Result] {
        await withTaskGroup(of: SharedFirstSuccess<Int, Int>.Result.self) { group in
            for _ in 0..<callers {
                group.addTask { await gate.run(operation) }
            }
            var all: [SharedFirstSuccess<Int, Int>.Result] = []
            for await result in group { all.append(result) }
            return all
        }
    }

    @Test("Concurrent callers run the operation once and share its success")
    func concurrentCallersShareOneRun() async {
        let runs = Counter()
        let gate = SharedFirstSuccess<Int, Int>(success: { $0 > 0 ? $0 : nil })
        let all = await results(gate, callers: 8) {
            let n = await runs.next()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return n * 10
        }

        #expect(await runs.value == 1)
        let own = all.filter { if case .own = $0 { return true } else { return false } }
        let shared = all.compactMap { if case .shared(let v) = $0 { return v } else { return nil } }
        #expect(own.count == 1)
        #expect(shared == Array(repeating: 10, count: 7))
    }

    @Test("A failed attempt is not shared: one waiter becomes the next forwarder")
    func failedAttemptHandsOver() async {
        let runs = Counter()
        // The first run fails (0); every later run succeeds.
        let gate = SharedFirstSuccess<Int, Int>(success: { $0 > 0 ? $0 : nil })
        let all = await results(gate, callers: 6) {
            let n = await runs.next()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return n == 1 ? 0 : n
        }

        #expect(await runs.value == 2)
        let owns = all.compactMap { if case .own(let v) = $0 { return v } else { return nil } }
        #expect(owns.sorted() == [0, 2])
        let shared = all.compactMap { if case .shared(let v) = $0 { return v } else { return nil } }
        #expect(shared == Array(repeating: 2, count: 4))
    }

    @Test("After a success, later callers get it without running again")
    func laterCallersReuseSuccess() async {
        let runs = Counter()
        let gate = SharedFirstSuccess<Int, Int>(success: { $0 })
        _ = await gate.run { await runs.next() }
        let later = await gate.run { await runs.next() }
        guard case .shared(1) = later else {
            Issue.record("Expected the shared first result, got \(later)"); return
        }
        #expect(await runs.value == 1)
    }
}

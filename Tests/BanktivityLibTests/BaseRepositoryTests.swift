// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("BaseRepository")
struct BaseRepositoryTests {

    @Test("Repository writes are serialized across concurrent callers")
    func performWriteSerializesConcurrentCallers() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let repository = BaseRepository(container: vault.container)
        let recorder = WriteOverlapRecorder()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let writeCount = 8

        for _ in 0..<writeCount {
            group.enter()
            queue.async {
                start.wait()
                do {
                    try repository.performWrite { _ in
                        recorder.enter()
                        Thread.sleep(forTimeInterval: 0.03)
                        recorder.leave()
                    }
                } catch {
                    recorder.record(error)
                }
                group.leave()
            }
        }

        for _ in 0..<writeCount {
            start.signal()
        }

        let result = group.wait(timeout: .now() + 5)
        #expect(result == .success)
        #expect(recorder.errors.isEmpty)
        #expect(recorder.maximumConcurrentWrites == 1)
    }

    // Added 2026-09-02. setDate is the shared writer for every date-only field --
    // transaction pDate, statement periods, scheduled dates. It must anchor the
    // stored instant so the calendar date does not move with the reader's location.
    // Asserted through the real write path: a DateConversion-only test passes even
    // when the anchor is removed from this function.
    @Test("setDate anchors a date-only value to 10:00 UTC, not host-local midnight")
    func setDateAnchorsDateOnlyValues() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let context = vault.container.viewContext
        let transaction = BaseRepository.createObject(entityName: "Transaction", in: context)
        BaseRepository.setDate(transaction, "pDate", isoString: "2026-06-08")

        let stored = try #require(transaction.value(forKey: "pDate") as? Date)
        let utc = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: stored)

        #expect(parts.year == 2026)
        #expect(parts.month == 6)
        #expect(parts.day == 8)
        #expect(parts.hour == 10)

        // The property that matters operationally: same calendar day at both
        // extremes of where this vault gets read.
        let ts = DateConversion.fromDate(stored)
        let denver = try #require(TimeZone(identifier: "America/Denver"))
        let melbourne = try #require(TimeZone(identifier: "Australia/Melbourne"))
        #expect(DateConversion.toISO(ts, timeZone: denver) == "2026-06-08")
        #expect(DateConversion.toISO(ts, timeZone: melbourne) == "2026-06-08")
    }

    // A full ISO timestamp is an audit stamp, not a calendar label, and must pass
    // through untouched -- the anchor applies only to the 10-character branch.
    @Test("setDate leaves a full ISO timestamp untouched")
    func setDatePreservesFullTimestamps() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let context = vault.container.viewContext
        let statement = BaseRepository.createObject(entityName: "Statement", in: context)
        BaseRepository.setDate(statement, "pCreationTime", isoString: "2026-06-08T13:45:07Z")

        let stored = try #require(statement.value(forKey: "pCreationTime") as? Date)
        #expect(DateConversion.toISODateTime(DateConversion.fromDate(stored)) == "2026-06-08T13:45:07Z")
    }
}

private final class WriteOverlapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWrites = 0
    private var maxActiveWrites = 0
    private var recordedErrors: [Error] = []

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxActiveWrites
    }

    func enter() {
        lock.lock()
        activeWrites += 1
        maxActiveWrites = max(maxActiveWrites, activeWrites)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        activeWrites -= 1
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }

}

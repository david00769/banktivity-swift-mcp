// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Compression

/// The CLI's only contact with Banktivity 10's CloudKit sync bookkeeping
/// (`SyncedHostedEntity`, Core Data's `ZSYNCEDENTITY`): deletion marks made
/// inside the caller's context (never saving on their own), and read-only
/// inspection for diagnostics.
///
/// The model, measured against Banktivity 10 on 2026-09-30:
///
/// - **Upload detection is by modification date.** `IGGSyncServices` finds
///   local changes to upload by comparing each entity's `pModificationDate`
///   and `pCreationTime` with the sync document's last sync date
///   (`fetchSyncEntityIDsOfType:modifiedAfterDate:`, predicate
///   `pModificationDate>%@ && pCreationTime<=%@`).
/// - **`pRemoteEntityData` is the merge base.** The gzipped XML blob is
///   Banktivity's record of what the server holds, used as the base of a
///   three-way merge (`mergedFieldFromBase:remote:local:`). Banktivity inserts
///   the `SyncedHostedEntity` itself when it uploads a new row
///   (`insertNewSyncedHostedEntityOfType:`), and only its sync writes the blob.
/// - **`pSyncedState` is only for deletion** (3 = pending delete).
///
/// The write model that follows:
///
/// - **Inserts and updates:** the modification date is the only upload
///   signal. A repository sets `pCreationTime` / `pModificationDate` to now
///   inside the same context and save as the edit; an edit to a line item
///   stamps its parent Transaction, because line items travel inside the
///   Transaction's record. Nothing here takes part.
/// - **Deletes** use Banktivity's own pending-delete mark (what
///   `markSyncedHostedEntitiesOfType:forDeletionWithLocalIDs:` does):
///   `markDeletedIfPresent` sets `pSyncedState = 3` and
///   `pSyncedModificationDate` to now, in the same context and save as the
///   entity delete. A row with no record never synced, so it is just deleted.
/// - **The CLI never writes `pRemoteEntityData`.**
///
/// This replaces `SyncBlobUpdater`. Earlier versions hand-built the blob on
/// create and patched it to match each update (on the theory, from upstream commit a15315d, that Banktivity
/// would not push a change its blob did not reflect). That was wrong:
/// patching the base told Banktivity the server already held the edit, so
/// when the server re-served its stale copy the stale version won the merge,
/// and nearly every CLI trade repair on ten accounts was reverted. A UI note
/// edit, which leaves the base alone, survived the same sync round trip.
public enum SyncRecords {
    // MARK: - In-context marks
    //
    // Every write helper here runs inside the caller's own context and never
    // saves: the sync mark commits or rolls back with the edit it describes.

    /// Refuse to modify an entity whose sync record is already pending
    /// deletion (`pSyncedState == 3`). An absent record is fine: the entity
    /// has simply never synced.
    public static func requireNotPendingDelete(
        entityUUID: String,
        in context: NSManagedObjectContext
    ) throws {
        guard let record = try fetchSyncRecord(entityUUID: entityUUID, in: context) else { return }
        if (record.value(forKey: "pSyncedState") as? NSNumber)?.intValue == 3 {
            throw ToolError.invalidInput("Sync record for \(entityUUID) is pending deletion; refusing to modify it")
        }
    }

    /// Mark an entity's sync record as pending deletion, as Banktivity's own
    /// `markSyncedHostedEntitiesOfType:forDeletionWithLocalIDs:` does: keep the
    /// record (Banktivity needs it to know what to delete), set
    /// `pSyncedState = 3` and `pSyncedModificationDate` to now. Call it in the
    /// same context as the entity delete.
    ///
    /// Returns `false` when there is no record: the entity never synced, so
    /// deleting the row is the whole job. Idempotent: a record already
    /// pending deletion is left exactly as it is (state and date) and the
    /// delete proceeds. Paths that must refuse such a record -- modify,
    /// restore, the atomic statement replace -- call `requireNotPendingDelete`
    /// first.
    @discardableResult
    public static func markDeletedIfPresent(
        entityUUID: String,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        guard !entityUUID.isEmpty,
              let record = try fetchSyncRecord(entityUUID: entityUUID, in: context) else {
            return false
        }
        if (record.value(forKey: "pSyncedState") as? NSNumber)?.intValue == 3 {
            return true
        }
        record.setValue(Int16(3), forKey: "pSyncedState")
        record.setValue(Date(), forKey: "pSyncedModificationDate")
        return true
    }

    /// The record's `pSyncedModificationDate`, for a preimage that must be
    /// able to put it back exactly. `nil` when there is no record or no date.
    public static func syncedModificationDate(
        entityUUID: String,
        in context: NSManagedObjectContext
    ) throws -> Date? {
        try fetchSyncRecord(entityUUID: entityUUID, in: context)?
            .value(forKey: "pSyncedModificationDate") as? Date
    }

    /// Undo `markDeletedIfPresent` for a hash-bound statement-row
    /// restore: put the record back to `pSyncedState = 0` with exactly the
    /// `pSyncedModificationDate` the inspected preimage recorded. Returns
    /// `false` when there is no record (historical vaults can legitimately have
    /// no separate Statement record; membership travels with the affected
    /// transactions). A present record must be the one the forward operation
    /// marked deleted.
    public static func restoreDeletedStatementRecordIfPresent(
        entityUUID: String,
        priorSyncedModificationDate: Date?,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        guard let record = try fetchSyncRecord(entityUUID: entityUUID, in: context) else {
            return false
        }
        guard (record.value(forKey: "pSyncedState") as? NSNumber)?.intValue == 3 else {
            throw ToolError.invalidInput("Statement sync record was not deleted by the forward operation")
        }
        record.setValue(Int16(0), forKey: "pSyncedState")
        record.setValue(priorSyncedModificationDate, forKey: "pSyncedModificationDate")
        return true
    }

    // MARK: - Gzip (diagnostic reads)

    static func decompressGzip(_ data: Data) -> Data? {
        guard data.count >= 10 else { return nil }
        // Verify gzip magic number
        guard data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }

        // Strip gzip header (minimum 10 bytes) and trailer (8 bytes) to get raw deflate
        // Parse header to handle optional fields
        var offset = 10
        let flags = data[data.startIndex + 3]
        if flags & 0x04 != 0 { // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME - null terminated
            while offset < data.count && data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT - null terminated
            while offset < data.count && data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC

        guard data.count > offset + 8 else { return nil }
        let deflateData = data[data.startIndex + offset ..< data.endIndex - 8]

        // Read uncompressed size from last 4 bytes of trailer
        let sizeOffset = data.endIndex - 4
        let uncompressedSize = Int(data[sizeOffset]) |
            (Int(data[sizeOffset + 1]) << 8) |
            (Int(data[sizeOffset + 2]) << 16) |
            (Int(data[sizeOffset + 3]) << 24)

        // Allocate buffer with some headroom (size field is mod 2^32)
        let bufferSize = max(uncompressedSize, deflateData.count * 4)
        var destination = Data(count: bufferSize)
        let decompressedSize = deflateData.withUnsafeBytes { srcPtr -> Int in
            destination.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress, let dst = dstPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), bufferSize,
                    src.assumingMemoryBound(to: UInt8.self), deflateData.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decompressedSize > 0 else { return nil }
        return destination.prefix(decompressedSize)
    }

    // MARK: - Diagnostics

    /// Inspect a sync record for diagnostic purposes (read-only).
    /// Returns a dictionary of key fields, or nil if no record found.
    public static func inspect(entityUUID: String, fullBlob: Bool = false, in container: NSPersistentContainer) -> [String: Any]? {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var result: [String: Any]?
        ctx.performAndWait {
            result = inspect(entityUUID: entityUUID, fullBlob: fullBlob, in: ctx)
        }
        return result
    }

    private static func inspect(entityUUID: String, fullBlob: Bool, in ctx: NSManagedObjectContext) -> [String: Any]? {
        guard let record = try? fetchSyncRecord(entityUUID: entityUUID, in: ctx) else { return nil }

        let blobData = record.value(forKey: "pRemoteEntityData") as? Data
        let modDate = record.value(forKey: "pSyncedModificationDate") as? Date
        let syncedState = record.value(forKey: "pSyncedState") as? Int16

        var result: [String: Any] = [
            "pLocalID": record.value(forKey: "pLocalID") as? String ?? "(nil)",
            "pRemoteID": record.value(forKey: "pRemoteID") as? String ?? "(nil)",
            "pHostedEntityType": record.value(forKey: "pHostedEntityType") as? String ?? "(nil)",
            "pSyncedState": syncedState as Any,
            "pSyncedModificationDate": modDate?.description ?? "(nil)",
            "pRemoteEntityDataSize": blobData?.count ?? 0,
            "hasBlobData": blobData != nil
        ]

        // Try to decompress and show first 200 chars of XML
        if let data = blobData, let decompressed = decompressGzip(data),
           let xml = String(data: decompressed, encoding: .utf8) {
            let preview = String(xml.prefix(300))
            result["blobPreview"] = preview
            // The whole record, for comparing a row the CLI wrote with one
            // Banktivity wrote: the 300-character preview stops before the
            // line items, which is where they differ.
            if fullBlob { result["blobXML"] = xml }
        }

        return result
    }

    private static func fetchSyncRecord(entityUUID: String, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", entityUUID)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }
}

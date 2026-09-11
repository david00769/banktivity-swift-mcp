// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public enum BanktivityError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case noModelsFound(String)
    case modelMergeFailed
    case storeLoadFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .noModelsFound(let path):
            return "No .momd model bundles found in: \(path)"
        case .modelMergeFailed:
            return "Failed to merge Core Data models"
        case .storeLoadFailed(let error):
            return "Failed to load persistent store: \(error)"
        }
    }
}

/// Loads and configures an NSPersistentContainer from a .bank8 bundle's compiled Core Data models.
public enum PersistentContainerFactory {

    /// Read the wrapper-supplied read-only intent.
    ///
    /// `scripts/mcp/run-banktivity-swift-cli.sh` already classifies every
    /// invocation as read or write and exports this; the binary only honours it.
    public static var readOnlyFromEnvironment: Bool {
        let raw = ProcessInfo.processInfo.environment["BANKTIVITY_STORE_READ_ONLY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    /// Load all .momd model bundles from the StoreContent directory and merge them.
    public static func loadMergedModel(from storeContentURL: URL) throws -> NSManagedObjectModel {
        let contents = try FileManager.default.contentsOfDirectory(
            at: storeContentURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        // Sort by filename so the merge order is deterministic. `contentsOfDirectory`
        // returns entries in arbitrary order, and `NSManagedObjectModel(byMerging:)` can
        // produce different entity version hashes depending on the order it sees them in.
        // A model whose hashes drift between runs is what triggers Core Data to decide a
        // migration is needed — see the migration flags in `create` below.
        let momdURLs = contents
            .filter { $0.pathExtension == "momd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !momdURLs.isEmpty else {
            throw BanktivityError.noModelsFound(storeContentURL.path)
        }

        let models = momdURLs.compactMap { NSManagedObjectModel(contentsOf: $0) }

        guard !models.isEmpty else {
            throw BanktivityError.noModelsFound(storeContentURL.path)
        }

        guard let merged = NSManagedObjectModel(byMerging: models) else {
            throw BanktivityError.modelMergeFailed
        }

        return merged
    }

    /// Create a configured NSPersistentContainer for the given .bank8 file path.
    ///
    /// - Parameters:
    ///   - bankFilePath: Path to the .bank8 bundle
    ///   - readOnly: Open the SQLite store read-only. A read-write handle can
    ///     checkpoint the WAL and recover a hot journal, so it mutates the vault
    ///     even when no write command runs. Callers that know an invocation only
    ///     reads should pass true to remove the write vector rather than rely on
    ///     the command to behave.
    /// - Returns: A loaded NSPersistentContainer
    public static func create(
        bankFilePath: String,
        readOnly: Bool = false
    ) throws -> NSPersistentContainer {
        let storeContentURL = URL(fileURLWithPath: bankFilePath)
            .appendingPathComponent("StoreContent")

        guard FileManager.default.fileExists(atPath: storeContentURL.path) else {
            throw BanktivityError.fileNotFound(storeContentURL.path)
        }

        let sqlURL = storeContentURL.appendingPathComponent("core.sql")
        guard FileManager.default.fileExists(atPath: sqlURL.path) else {
            throw BanktivityError.fileNotFound(sqlURL.path)
        }

        let mergedModel = try loadMergedModel(from: storeContentURL)
        registerOpaqueTransformers(for: mergedModel)

        let container = NSPersistentContainer(
            name: "Banktivity",
            managedObjectModel: mergedModel
        )

        let description = NSPersistentStoreDescription(url: sqlURL)
        description.type = NSSQLiteStoreType
        description.isReadOnly = readOnly

        // NEVER migrate this store. Both of these default to `true`, which is catastrophic
        // here: the model is reconstructed by merging a dozen .momd bundles shipped inside
        // someone else's app bundle (core.momd alone carries seven versions). If the merged
        // model's entity hashes don't match what Banktivity itself wrote, Core Data silently
        // performs a lightweight migration — which DROPS AND RECREATES the tables of entities
        // it thinks changed, discarding every row. Observed 2026-07-28: a single
        // `line-items update` emptied ZSECURITYPRICE (40,459 rows -> 0) while leaving all
        // other tables intact, and reported success.
        //
        // With migration disabled a model mismatch fails loudly at store-load time instead,
        // which is always the correct outcome: this tool is a guest in Banktivity's store and
        // has no business rewriting its schema.
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false

        // Do NOT enable persistent history tracking — Banktivity uses its own sync
        // mechanism (ZSYNCEDENTITY) rather than Core Data's built-in persistent history.
        // Enabling history tracking populates the ATRANSACTION/ACHANGE tables and adds
        // Z_PRIMARYKEY entries (entity IDs 16001-16003) that Banktivity doesn't recognize,
        // causing it to refuse to open the vault.

        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }

        if let error = loadError {
            throw BanktivityError.storeLoadFailed(error.localizedDescription)
        }

        container.viewContext.automaticallyMergesChangesFromParent = true

        return container
    }

    /// Register a byte-preserving transformer for every transformer name the model
    /// uses that this process cannot resolve.
    ///
    /// Banktivity's model names value transformers that live inside Banktivity.app
    /// (`IGGCAccountingUnarchiveFromData`, `IGGCAccountingSecureUnarchiveFromDataTransformer`).
    /// Without them Core Data logs a warning per attribute on every store load. These
    /// attributes hold Banktivity's own archives, which this package never decodes,
    /// so the correct stand-in keeps them opaque: `Data` in, the same `Data` out,
    /// and any other value is a programming error rather than something to store.
    /// Names that are already registered, including the system's
    /// `NSSecureUnarchiveFromData`, are left alone.
    ///
    /// - Returns: The names this call registered.
    @discardableResult
    static func registerOpaqueTransformers(for model: NSManagedObjectModel) -> [String] {
        var registered: [String] = []
        for entity in model.entities {
            for case let attribute as NSAttributeDescription in entity.properties
            where attribute.attributeType == .transformableAttributeType {
                guard let name = attribute.valueTransformerName,
                      ValueTransformer(forName: NSValueTransformerName(name)) == nil else { continue }
                ValueTransformer.setValueTransformer(
                    OpaqueDataTransformer(), forName: NSValueTransformerName(name))
                registered.append(name)
            }
        }
        return registered
    }

    /// Dump all entity names, attributes, and relationships from a merged model.
    /// Used as a diagnostic tool to discover property names.
    public static func dumpModelSchema(from storeContentURL: URL) throws -> [[String: Any]] {
        let mergedModel = try loadMergedModel(from: storeContentURL)
        var result: [[String: Any]] = []

        let sortedEntities = mergedModel.entities.sorted { ($0.name ?? "") < ($1.name ?? "") }

        for entity in sortedEntities {
            var entityInfo: [String: Any] = [
                "name": entity.name ?? "unknown",
                "managedObjectClassName": entity.managedObjectClassName ?? "NSManagedObject",
            ]

            // Attributes
            var attributes: [[String: String]] = []
            let sortedAttrs = entity.attributesByName.sorted { $0.key < $1.key }
            for (name, attr) in sortedAttrs {
                attributes.append([
                    "name": name,
                    "type": attr.attributeType.description,
                ])
            }
            entityInfo["attributes"] = attributes

            // Relationships
            var relationships: [[String: String]] = []
            let sortedRels = entity.relationshipsByName.sorted { $0.key < $1.key }
            for (name, rel) in sortedRels {
                var relInfo: [String: String] = [
                    "name": name,
                    "destination": rel.destinationEntity?.name ?? "unknown",
                    "toMany": rel.isToMany ? "true" : "false",
                ]
                if let inverse = rel.inverseRelationship {
                    relInfo["inverse"] = inverse.name
                }
                relationships.append(relInfo)
            }
            entityInfo["relationships"] = relationships

            result.append(entityInfo)
        }

        return result
    }
}

extension NSAttributeType: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .undefinedAttributeType: return "undefined"
        case .integer16AttributeType: return "int16"
        case .integer32AttributeType: return "int32"
        case .integer64AttributeType: return "int64"
        case .decimalAttributeType: return "decimal"
        case .doubleAttributeType: return "double"
        case .floatAttributeType: return "float"
        case .stringAttributeType: return "string"
        case .booleanAttributeType: return "boolean"
        case .dateAttributeType: return "date"
        case .binaryDataAttributeType: return "binaryData"
        case .UUIDAttributeType: return "uuid"
        case .URIAttributeType: return "uri"
        case .transformableAttributeType: return "transformable"
        case .objectIDAttributeType: return "objectID"
        case .compositeAttributeType: return "composite"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

/// Stands in for a Banktivity.app transformer this package does not link: it
/// passes the stored archive through untouched in both directions, so a save
/// writes back exactly the bytes that were read.
///
/// Anything other than `Data` or nil stops the process. Returning nil instead
/// would make Core Data store NULL, silently erasing Banktivity's archive, and
/// the only way to hand this a decoded object is new code that assumed a real
/// Banktivity transformer was present.
final class OpaqueDataTransformer: ValueTransformer {
    override class func transformedValueClass() -> AnyClass { NSData.self }
    override class func allowsReverseTransformation() -> Bool { true }
    override func transformedValue(_ value: Any?) -> Any? { Self.opaque(value) }
    override func reverseTransformedValue(_ value: Any?) -> Any? { Self.opaque(value) }

    private static func opaque(_ value: Any?) -> Data? {
        guard let value else { return nil }
        guard let data = value as? Data else {
            preconditionFailure(
                "Banktivity archive attribute given \(type(of: value)); only its stored Data may pass through")
        }
        return data
    }
}

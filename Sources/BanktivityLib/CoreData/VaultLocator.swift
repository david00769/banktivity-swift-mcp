// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Turns the vault setting (`BANKTIVITY_FILE_PATH` or `--vault`) into the path
/// of a `.bank8` vault.
///
/// Banktivity 10 keeps a synced vault in its own library, not in Documents:
/// `<group container>/IGGFinance/production/Documents/<vault id>/<n>.bank8`.
/// The parent folder is the same on every Mac; the vault id is not. So when
/// the setting is empty, the vault is looked up there, and used only if it is
/// the one vault found. A Claude Desktop extension passes an empty string (or,
/// in some hosts, the unsubstituted `${user_config...}`) for a setting left
/// blank, so both count as unset.
public enum VaultLocator {

    public static let banktivity10LibraryPath =
        "~/Library/Group Containers/group.com.iggsoftware.banktivity.library/IGGFinance/production/Documents"

    public enum Failure: Error, LocalizedError, Equatable {
        case notFound(String)
        case notAVault(String, candidates: [String])
        case noneDiscovered(library: String)
        case libraryUnreadable(library: String)
        case severalDiscovered([String])

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "File not found: \(path)"
            case .notAVault(let path, let candidates):
                let hint = candidates.isEmpty
                    ? "Set the path of a .bank8 vault."
                    : "Vaults inside it:\n" + candidates.map { "  \($0)" }.joined(separator: "\n")
                return "Not a .bank8 vault: \(path)\n\(hint)"
            case .libraryUnreadable(let library):
                return "macOS blocked access to Banktivity's library (\(library)). "
                    + "Allow it in System Settings > Privacy & Security > Full Disk Access for "
                    + "\(CommandLine.arguments.first ?? "banktivity-mcp") (or the app that runs it), "
                    + "then restart it. Or set BANKTIVITY_FILE_PATH to a .bank8 vault elsewhere."
            case .noneDiscovered(let library):
                return "No vault set and no Banktivity 10 vault found in \(library). "
                    + "Set BANKTIVITY_FILE_PATH (or --vault) to your .bank8 vault."
            case .severalDiscovered(let paths):
                return "No vault set and several Banktivity 10 vaults found. "
                    + "Set BANKTIVITY_FILE_PATH (or --vault) to one of:\n"
                    + paths.map { "  \($0)" }.joined(separator: "\n")
            }
        }
    }

    /// - Parameters:
    ///   - setting: the configured path; nil, empty or blank means "find it".
    ///   - library: where Banktivity 10 keeps synced vaults (tests pass a temp dir).
    public static func resolve(
        _ setting: String?,
        library: String = banktivity10LibraryPath,
        fileManager: FileManager = .default
    ) throws -> String {
        var raw = setting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An extension host that leaves `${user_config.x}` unsubstituted means unset.
        if raw.hasPrefix("${") && raw.hasSuffix("}") { raw = "" }
        if raw.isEmpty {
            let lib = expand(library)
            // A library that exists but cannot be listed is macOS app-data
            // protection (TCC), not an empty library; say so.
            var libIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: lib, isDirectory: &libIsDir), libIsDir.boolValue,
               (try? fileManager.contentsOfDirectory(atPath: lib)) == nil {
                throw Failure.libraryUnreadable(library: lib)
            }
            let found = vaults(in: lib, fileManager: fileManager)
            switch found.count {
            case 1: return found[0]
            case 0: throw Failure.noneDiscovered(library: lib)
            default: throw Failure.severalDiscovered(found)
            }
        }

        let path = expand(raw)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw Failure.notFound(path)
        }
        if path.lowercased().hasSuffix(".bank8") {
            return path
        }
        let candidates = isDir.boolValue ? vaults(in: path, fileManager: fileManager) : []
        throw Failure.notAVault(path, candidates: candidates)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// `.bank8` bundles at most two levels below `root` (Banktivity 10 nests one
    /// under a vault-id folder), sorted. A `.bank8` is not searched inside.
    static func vaults(in root: String, fileManager: FileManager) -> [String] {
        var found: [String] = []
        func scan(_ dir: String, depth: Int) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") {
                let child = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                if name.lowercased().hasSuffix(".bank8") {
                    found.append(child)
                } else if depth < 2 {
                    scan(child, depth: depth + 1)
                }
            }
        }
        scan(root, depth: 1)
        return found.sorted()
    }
}

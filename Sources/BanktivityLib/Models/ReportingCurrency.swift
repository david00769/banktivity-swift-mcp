// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// The currency aggregate values such as net worth are converted into.
///
/// Set with the `BANKTIVITY_REPORTING_CURRENCY` environment variable (an
/// ISO 4217 code such as `USD`). Unset, empty or unknown values fall back to
/// EUR, which is what aggregate amounts were always labelled with.
public enum ReportingCurrency {
    public static let defaultCode = "EUR"
    public static let environmentKey = "BANKTIVITY_REPORTING_CURRENCY"

    /// Normalize and validate an optional ISO 4217 currency code.
    /// Unknown or empty values fall back to the default, EUR.
    public static func resolve(_ rawValue: String?) -> String {
        guard let code = normalized(rawValue) else { return defaultCode }
        return Locale.commonISOCurrencyCodes.contains(code) ? code : defaultCode
    }

    /// The configured code, plus a warning when a value was set but not recognised.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (code: String, warning: String?) {
        let raw = environment[environmentKey]
        let code = resolve(raw)
        if let given = normalized(raw), given != code {
            return (code, "Unknown \(environmentKey) '\(raw ?? "")'; using \(code)")
        }
        return (code, nil)
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let code = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.isEmpty ? nil : code
    }
}

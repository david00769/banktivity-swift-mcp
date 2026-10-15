// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// One row of Banktivity's ExchangeRate table: 1 `source` = `rate` `destination`.
public struct ExchangeRateRecord: Sendable, Equatable {
    public let source: String
    public let destination: String
    public let rate: Decimal
    public let effectiveDate: Date?

    public init(source: String, destination: String, rate: Decimal, effectiveDate: Date?) {
        self.source = source.uppercased()
        self.destination = destination.uppercased()
        self.rate = rate
        self.effectiveDate = effectiveDate
    }
}

public struct ExchangeRateLookupResult: Sendable, Equatable {
    public let rate: Decimal
    public let effectiveDate: Date?
    /// 0 for the same currency, 1 for a direct or reverse rate, 2 through USD.
    public let hops: Int
    public let path: [String]

    public init(rate: Decimal, effectiveDate: Date?, hops: Int, path: [String]) {
        self.rate = rate
        self.effectiveDate = effectiveDate
        self.hops = hops
        self.path = path
    }
}

/// Reads Banktivity's stored exchange rates and resolves a conversion rate.
///
/// Ported from upstream #20. Resolution order: same currency (rate 1), the
/// latest direct rate, the inverse of the latest reverse rate, then a
/// two-step route through USD. A zero rate is never used.
public final class ExchangeRateRepository: BaseRepository, @unchecked Sendable {
    private static let pivotCurrency = "USD"

    /// Every usable rate in the vault.
    public func allRates() throws -> [ExchangeRateRecord] {
        try performRead { ctx in try Self.fetchRates(in: ctx) }
    }

    public func lookupExchangeRate(from: String, to: String) throws -> ExchangeRateLookupResult? {
        Self.resolve(from: from, to: to, rates: try allRates())
    }

    public static func resolve(
        from rawFrom: String,
        to rawTo: String,
        rates: [ExchangeRateRecord]
    ) -> ExchangeRateLookupResult? {
        let from = rawFrom.uppercased()
        let to = rawTo.uppercased()
        guard from != to else {
            return ExchangeRateLookupResult(rate: 1, effectiveDate: nil, hops: 0, path: [to])
        }
        if let oneHop = oneHopRate(from: from, to: to, rates: rates) {
            return oneHop
        }
        guard from != pivotCurrency, to != pivotCurrency,
              let first = oneHopRate(from: from, to: pivotCurrency, rates: rates),
              let second = oneHopRate(from: pivotCurrency, to: to, rates: rates)
        else { return nil }
        return ExchangeRateLookupResult(
            rate: first.rate * second.rate,
            effectiveDate: oldest(first.effectiveDate, second.effectiveDate),
            hops: 2,
            path: [from, pivotCurrency, to]
        )
    }

    static func fetchRates(in ctx: NSManagedObjectContext) throws -> [ExchangeRateRecord] {
        let codesById = try currencyCodesByUniqueId(in: ctx)
        func code(_ id: String) -> String? {
            codesById[id] ?? (Locale.commonISOCurrencyCodes.contains(id.uppercased()) ? id.uppercased() : nil)
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "ExchangeRate")
        return try ctx.fetch(request).compactMap { row in
            guard let sourceId = row.value(forKey: "pSourceCurrencyID") as? String,
                  let destinationId = row.value(forKey: "pDestinationCurrencyID") as? String,
                  let source = code(sourceId),
                  let destination = code(destinationId)
            else { return nil }
            return ExchangeRateRecord(
                source: source,
                destination: destination,
                rate: decimalValue(row, "pExchangeRate"),
                effectiveDate: row.value(forKey: "pEffectiveDate") as? Date
            )
        }
    }

    static func currencyCodesByUniqueId(in ctx: NSManagedObjectContext) throws -> [String: String] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Currency")
        var result: [String: String] = [:]
        for currency in try ctx.fetch(request) {
            guard let uniqueId = currency.value(forKey: "pUniqueID") as? String,
                  let code = currency.value(forKey: "pCode") as? String
            else { continue }
            result[uniqueId] = code.uppercased()
        }
        return result
    }

    private static func oneHopRate(from: String, to: String, rates: [ExchangeRateRecord]) -> ExchangeRateLookupResult? {
        if let direct = latestRate(source: from, destination: to, rates: rates) {
            return ExchangeRateLookupResult(rate: direct.rate, effectiveDate: direct.effectiveDate, hops: 1, path: [from, to])
        }
        if let reverse = latestRate(source: to, destination: from, rates: rates) {
            return ExchangeRateLookupResult(rate: 1 / reverse.rate, effectiveDate: reverse.effectiveDate, hops: 1, path: [from, to])
        }
        return nil
    }

    private static func latestRate(source: String, destination: String, rates: [ExchangeRateRecord]) -> ExchangeRateRecord? {
        rates
            .filter { $0.source == source && $0.destination == destination && $0.rate != 0 }
            .max { lhs, rhs in
                // A dated rate beats an undated one; otherwise the later date wins.
                switch (lhs.effectiveDate, rhs.effectiveDate) {
                case let (l?, r?): return l < r
                case (nil, _?): return true
                default: return false
                }
            }
    }

    private static func oldest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }
}

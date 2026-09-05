// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

/// What `--transaction-type` accepts, and what it says it accepts.
///
/// The accepted set lived in a `switch` and was restated by hand in the
/// caller's error message. The two drifted in BOTH directions: the message
/// omitted `split-shares`, `transfer-shares`, `dividend` and `transfer`, all of
/// which worked, while advertising `short-sell` and `buy-to-cover`, which were
/// never accepted at all.
///
/// The cost was not cosmetic. A consumer read the advertised list, concluded
/// that retyping some fifty corporate-action rows required changing this
/// package, and planned around a limitation that did not exist. A capability
/// nobody can discover is indistinguishable from one that is missing.
@Suite("Transaction type vocabulary")
struct TransactionTypeVocabularyTests {

    @Test("every advertised slug is actually accepted")
    func advertisedSlugsAreAccepted() {
        for slug in TransactionRepository.transactionTypeNames.split(separator: ", ") {
            #expect(
                TransactionRepository.transactionTypeBaseTypeCode(String(slug)) != nil,
                "advertised \(slug) but it is not accepted")
        }
    }

    @Test("every accepted slug is advertised")
    func acceptedSlugsAreAdvertised() {
        let advertised = Set(TransactionRepository.transactionTypeNames
            .split(separator: ", ").map(String.init))
        for slug in TransactionRepository.transactionTypeBaseTypes.keys {
            #expect(advertised.contains(slug), "accepted \(slug) but it is not advertised")
        }
    }

    @Test(
        "the corporate-action types a repair needs are accepted",
        arguments: [
            ("split-shares", 250),
            ("transfer-shares", 212),
            ("move-shares-in", 210),
            ("move-shares-out", 211),
            // A spin-off apportions basis by releasing it through Return of
            // Capital and spending it on the child. Without this the second leg
            // cannot be written, so the apportionment cannot be recorded at all.
            ("return-of-capital", 310),
        ])
    func corporateActionTypesAreAccepted(slug: String, expected: Int) {
        #expect(TransactionRepository.transactionTypeBaseTypeCode(slug) == expected)
    }

    @Test("a slug round-trips through the name the vault reads back")
    func slugsRoundTrip() {
        for (slug, code) in TransactionRepository.transactionTypeBaseTypes {
            let name = TransactionRepository.transactionTypeBaseTypeName(code)
            #expect(
                TransactionRepository.transactionTypeBaseTypeCode(name) == code,
                "\(slug) -> \(code) -> \(name), which does not map back to \(code)")
        }
    }

    @Test("an unknown slug is refused rather than defaulted")
    func unknownSlugIsRefused() {
        // Defaulting would write a plausible-looking transaction of the wrong
        // kind, which is not a visible error.
        #expect(TransactionRepository.transactionTypeBaseTypeCode("nonsense") == nil)
        #expect(TransactionRepository.transactionTypeBaseTypeCode("") == nil)
    }

    @Test("slugs are matched case-insensitively")
    func slugsAreCaseInsensitive() {
        #expect(TransactionRepository.transactionTypeBaseTypeCode("Split-Shares") == 250)
    }
}

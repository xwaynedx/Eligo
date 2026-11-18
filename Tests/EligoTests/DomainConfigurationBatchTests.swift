import XCTest
@testable import Eligo

final class DomainConfigurationBatchTests: XCTestCase {
    func testMergeMatchersPreservesOrderAndSkipsDuplicates() throws {
        let existing = try DomainMatcher(host: "existing.com", includesSubdomains: true)
        let added = try DomainMatcher(host: "added.com", includesSubdomains: false)

        XCTAssertEqual(
            DomainConfigurationBatch().mergeMatchers([existing, added, added], into: [existing]),
            [existing, added]
        )
    }

    func testMergeRulesSkipsOrReplacesExistingMatchers() throws {
        let matcher = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let existingID = UUID()
        let existing = [DomainRule(id: existingID, matcher: matcher, destinationID: safariOpenDestination)]

        XCTAssertEqual(
            DomainConfigurationBatch().mergeRules(
                matchers: [matcher], destinationID: chromeOpenDestination, replacingExisting: false, into: existing
            ),
            existing
        )
        XCTAssertEqual(
            DomainConfigurationBatch().mergeRules(
                matchers: [matcher], destinationID: chromeOpenDestination, replacingExisting: true, into: existing
            ),
            [DomainRule(id: existingID, matcher: matcher, destinationID: chromeOpenDestination)]
        )
    }

    func testMergeRulesKeepsExistingIdentityAndOrderWhenAppendingMixedInputs() throws {
        let a = try DomainMatcher(host: "a.example", includesSubdomains: false)
        let b = try DomainMatcher(host: "b.example", includesSubdomains: true)
        let c = try DomainMatcher(host: "c.example", includesSubdomains: false)
        let d = try DomainMatcher(host: "d.example", includesSubdomains: true)
        let idA = UUID()
        let idB = UUID()
        let existing = [
            DomainRule(id: idA, matcher: a, destinationID: safariOpenDestination),
            DomainRule(id: idB, matcher: b, destinationID: chromeOpenDestination)
        ]

        let result = DomainConfigurationBatch().mergeRules(
            matchers: [c, a, d, c],
            destinationID: safariOpenDestination,
            replacingExisting: false,
            into: existing
        )

        XCTAssertEqual(result.map(\.matcher), [a, b, c, d])
        XCTAssertEqual(Array(result.map(\.id).prefix(2)), [idA, idB])
        XCTAssertEqual(result[0].destinationID, safariOpenDestination)
        XCTAssertEqual(result[1].destinationID, chromeOpenDestination)
        XCTAssertEqual(result[2].destinationID, safariOpenDestination)
        XCTAssertEqual(result[3].destinationID, safariOpenDestination)
        XCTAssertNotEqual(result[2].id, result[3].id)
        XCTAssertFalse([idA, idB].contains(result[2].id))
        XCTAssertFalse([idA, idB].contains(result[3].id))
    }

    func testMergeRulesReplacesMatchingRulesInPlaceAndKeepsTheirIdentifiers() throws {
        let a = try DomainMatcher(host: "a.example", includesSubdomains: false)
        let b = try DomainMatcher(host: "b.example", includesSubdomains: true)
        let c = try DomainMatcher(host: "c.example", includesSubdomains: false)
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let existing = [
            DomainRule(id: idA, matcher: a, destinationID: safariOpenDestination),
            DomainRule(id: idB, matcher: b, destinationID: safariOpenDestination),
            DomainRule(id: idC, matcher: c, destinationID: safariOpenDestination)
        ]

        let result = DomainConfigurationBatch().mergeRules(
            matchers: [c, a],
            destinationID: chromeOpenDestination,
            replacingExisting: true,
            into: existing
        )

        XCTAssertEqual(
            result,
            [
                DomainRule(id: idA, matcher: a, destinationID: chromeOpenDestination),
                existing[1],
                DomainRule(id: idC, matcher: c, destinationID: chromeOpenDestination)
            ]
        )
    }

    func testMergeRulesTreatsSameHostWithDifferentSubdomainFlagsAsDistinct() throws {
        let exact = try DomainMatcher(host: "example.com", includesSubdomains: false)
        let subdomains = try DomainMatcher(host: "example.com", includesSubdomains: true)
        let existingID = UUID()
        let existing = [
            DomainRule(id: existingID, matcher: exact, destinationID: safariOpenDestination)
        ]

        let replaced = DomainConfigurationBatch().mergeRules(
            matchers: [subdomains, exact],
            destinationID: chromeOpenDestination,
            replacingExisting: true,
            into: existing
        )

        XCTAssertEqual(replaced.map(\.matcher), [exact, subdomains])
        XCTAssertEqual(replaced[0].id, existingID)
        XCTAssertNotEqual(replaced[1].id, existingID)
        XCTAssertEqual(replaced.map(\.destinationID), [chromeOpenDestination, chromeOpenDestination])

        let skipped = DomainConfigurationBatch().mergeRules(
            matchers: [subdomains, exact],
            destinationID: chromeOpenDestination,
            replacingExisting: false,
            into: existing
        )

        XCTAssertEqual(skipped.map(\.matcher), [exact, subdomains])
        XCTAssertEqual(skipped[0], existing[0])
        XCTAssertEqual(skipped[1].destinationID, chromeOpenDestination)
    }

    func testMergeRulesKeepsOneRuleForRepeatedNewMatchers() throws {
        let repeated = try DomainMatcher(host: "repeated.example", includesSubdomains: true)

        for replacingExisting in [false, true] {
            let result = DomainConfigurationBatch().mergeRules(
                matchers: [repeated, repeated, repeated],
                destinationID: chromeOpenDestination,
                replacingExisting: replacingExisting,
                into: []
            )

            XCTAssertEqual(result.count, 1, "replacingExisting: \(replacingExisting)")
            XCTAssertEqual(result.first?.matcher, repeated)
            XCTAssertEqual(result.first?.destinationID, chromeOpenDestination)
        }
    }

    func testRemoveRulesRemovesSelectedIDsAndPreservesOrder() throws {
        let first = DomainRule(
            id: UUID(),
            matcher: try DomainMatcher(host: "first.example", includesSubdomains: false),
            destinationID: safariOpenDestination
        )
        let second = DomainRule(
            id: UUID(),
            matcher: try DomainMatcher(host: "second.example", includesSubdomains: false),
            destinationID: safariOpenDestination
        )
        let third = DomainRule(
            id: UUID(),
            matcher: try DomainMatcher(host: "third.example", includesSubdomains: false),
            destinationID: safariOpenDestination
        )

        XCTAssertEqual(
            DomainConfigurationBatch().removeRules(
                withIDs: Set([second.id]),
                from: [first, second, third]
            ),
            [first, third]
        )
    }

    private var safariOpenDestination: OpenDestinationID {
        OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
    }

    private var chromeOpenDestination: OpenDestinationID {
        OpenDestinationID(browserID: "com.google.Chrome", mode: .normal)
    }
}

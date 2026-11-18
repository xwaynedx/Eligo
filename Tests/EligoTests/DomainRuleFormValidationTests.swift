import XCTest
@testable import Eligo

final class DomainRuleFormValidationTests: XCTestCase {
    func testRejectsEmptyAndInvalidDomainsBeforeSaving() {
        let destination = OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)

        XCTAssertEqual(
            DomainRuleFormValidation.validate(host: "", includesSubdomains: false, destinationID: destination),
            .missingDomain
        )
        XCTAssertEqual(
            DomainRuleFormValidation.validate(host: "not a domain", includesSubdomains: false, destinationID: destination),
            .invalidDomain
        )
        XCTAssertEqual(
            DomainRuleFormValidation.validate(host: "127.0.0.1", includesSubdomains: true, destinationID: destination),
            .ipAddressesCannotIncludeSubdomains
        )
    }

    func testRequiresDestinationAndAcceptsValidDomain() {
        XCTAssertEqual(
            DomainRuleFormValidation.validate(host: "example.com", includesSubdomains: true, destinationID: nil),
            .missingDestination
        )
        XCTAssertEqual(
            DomainRuleFormValidation.validate(
                host: "example.com",
                includesSubdomains: true,
                destinationID: OpenDestinationID(browserID: "com.apple.Safari", mode: .normal)
            ),
            .valid
        )
    }
}

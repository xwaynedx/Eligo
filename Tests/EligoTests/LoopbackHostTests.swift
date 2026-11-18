import XCTest
@testable import Eligo

final class LoopbackHostTests: XCTestCase {
    func testRecognizesLoopbackHosts() {
        for host in ["127.0.0.1", "127.0.0.2", "::1", "localhost", "foo.localhost", "LOCALHOST"] {
            XCTAssertTrue(LoopbackHost.isLoopback(host: host), "Expected \(host) to be loopback")
        }
    }

    func testRecognizesEquivalentLoopbackSpellings() {
        for host in ["[::1]", "0:0:0:0:0:0:0:1", "localhost.", "foo.LOCALHOST"] {
            XCTAssertTrue(LoopbackHost.isLoopback(host: host), "Expected \(host) to be loopback")
        }
    }

    func testRejectsNonLoopbackHosts() {
        for host in ["192.168.1.1", "10.0.0.1", "example.com", "128.0.0.1", "::2"] {
            XCTAssertFalse(LoopbackHost.isLoopback(host: host), "Expected \(host) not to be loopback")
        }
    }

    func testRejectsAddressesExplicitlyOutOfScopeAsLoopback() {
        for host in ["172.16.0.1", "printer.local", "0.0.0.0"] {
            XCTAssertFalse(LoopbackHost.isLoopback(host: host), "Expected \(host) not to be loopback")
        }
    }
}

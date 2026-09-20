import Foundation
import XCTest
@testable import DiscordCore

final class SnowflakeTests: XCTestCase {
    func testPreservesLargeDecimalStrings() throws {
        let value = try Snowflake("922337203685477580799999999")
        XCTAssertEqual(value.rawValue, "922337203685477580799999999")

        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"922337203685477580799999999\"")
        XCTAssertEqual(try JSONDecoder().decode(Snowflake.self, from: data), value)
    }

    func testRejectsNonCanonicalValues() {
        XCTAssertThrowsError(try Snowflake("")) { XCTAssertEqual($0 as? SnowflakeError, .empty) }
        XCTAssertThrowsError(try Snowflake("12.5")) { XCTAssertEqual($0 as? SnowflakeError, .notDecimal("12.5")) }
        XCTAssertThrowsError(try Snowflake("0012")) { XCTAssertEqual($0 as? SnowflakeError, .leadingZero("0012")) }
        XCTAssertThrowsError(try JSONDecoder().decode(Snowflake.self, from: Data("123".utf8)))
    }
}

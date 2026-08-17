import XCTest
@testable import OpenYoink

/// IgnoreListService 纯匹配：命中 / 未命中 / 空列表 / 大小写与空白容错。
/// （NSWorkspace 前台应用查询依赖运行中的 WindowServer，不在无头单测覆盖。）
final class IgnoreListServiceTests: XCTestCase {
    func testExactMatch_isIgnored() {
        XCTAssertTrue(IgnoreListService.isIgnored(bundleID: "com.apple.Safari",
                                                  in: ["com.apple.Safari", "com.apple.finder"]))
    }

    func testCaseInsensitiveMatch_isIgnored() {
        XCTAssertTrue(IgnoreListService.isIgnored(bundleID: "COM.Apple.SAFARI",
                                                  in: ["com.apple.safari"]))
    }

    func testWhitespacePaddedListEntry_matches() {
        XCTAssertTrue(IgnoreListService.isIgnored(bundleID: "com.apple.safari",
                                                  in: ["  com.apple.safari  "]))
    }

    func testUnlistedApp_isNotIgnored() {
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "com.apple.finder",
                                                   in: ["com.apple.safari"]))
    }

    func testEmptyList_neverMatches() {
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "com.apple.safari", in: []))
    }

    func testNilOrEmptyBundleID_neverMatches() {
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: nil, in: ["com.apple.safari"]))
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "", in: ["com.apple.safari"]))
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "   ", in: ["com.apple.safari"]))
    }
}

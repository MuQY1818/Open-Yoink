import XCTest
@testable import OpenYoink

/// .ask 拖出策略确认框的裁决逻辑（S8）：本次是否移除 + 勾选
/// 「不再询问」时固化回写的策略。NSAlert 交互本身无法无头测试。
final class DragOutRemovalDecisionTests: XCTestCase {
    func testRemoveWithoutSuppression_removesOnceAndKeepsAskPolicy() {
        let verdict = DragOutRemovalDecision.verdict(removeChosen: true, dontAskAgain: false)
        XCTAssertTrue(verdict.shouldRemove)
        XCTAssertNil(verdict.policyToPersist)
    }

    func testKeepWithoutSuppression_keepsOnceAndKeepsAskPolicy() {
        let verdict = DragOutRemovalDecision.verdict(removeChosen: false, dontAskAgain: false)
        XCTAssertFalse(verdict.shouldRemove)
        XCTAssertNil(verdict.policyToPersist)
    }

    func testRemoveWithSuppression_persistsRemovePolicy() {
        let verdict = DragOutRemovalDecision.verdict(removeChosen: true, dontAskAgain: true)
        XCTAssertTrue(verdict.shouldRemove)
        XCTAssertEqual(verdict.policyToPersist, .remove)
    }

    func testKeepWithSuppression_persistsKeepPolicy() {
        let verdict = DragOutRemovalDecision.verdict(removeChosen: false, dontAskAgain: true)
        XCTAssertFalse(verdict.shouldRemove)
        XCTAssertEqual(verdict.policyToPersist, .keep)
    }
}

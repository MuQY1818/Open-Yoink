import XCTest
@testable import OpenYoink

/// UX6 空架自动隐藏裁决（EmptyShelfAutoHideRule，纯逻辑）：
/// 基于「非空 → 空」迁移触发；手动唤出的空架（无迁移）天然豁免。
final class EmptyShelfAutoHideTests: XCTestCase {
    func testNonEmptyToEmpty_whileVisible_requestsHide() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true)) // 建立基线
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testManuallySummonedEmptyShelf_neverHides() {
        // 用户手动唤出空架：首次评估只建基线，随后的 0→0 变更不触发。
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testTransitionWhileHidden_doesNotFire_andKeepsBaselineFresh() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 3, isVisible: true, isEnabled: true))
        // 隐藏状态下被清空（如菜单栏清空）：不触发（无架可隐），基线照常更新。
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: false, isEnabled: true))
        // 之后用户唤出空架：0→0 不触发。
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testSettingDisabled_neverFires() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: false))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: false))
    }

    func testPartialRemoval_doesNotFire() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 3, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true))
    }

    func testEmptyThenRefilledThenEmptied_firesOnEachTransition() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    // MARK: - 任务二：拖拽进行中不自动隐藏（不变式门控）

    /// 拖拽进行中 items 从 >0 变 0（如另一只手按 Delete 清空）→ 不得隐藏，
    /// 否则悬在 shelf 上的跨应用拖放会落空（真机验收怀疑的竞态）。
    func testDragInProgress_transitionToEmpty_isSuppressed() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true)) // 建立基线
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
    }

    /// 被抑制的隐藏不补发：拖拽结束时基线已是 0，之后的 0→0 变更不触发 ——
    /// 空架保持可见，由用户显式收起（安全方向）。
    func testDragInProgress_suppressedHide_isNotReplayedAfterDragEnds() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true)) // 抑制，基线更新为 0
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false)) // 拖拽结束，0→0 不触发
    }

    /// 门控只挡「拖拽中」：拖拽结束后 refill → 再清空，照常触发。
    func testAfterDragEnds_ruleFiresNormally() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                    isDragInProgress: false))
    }
}

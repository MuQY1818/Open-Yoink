import CoreGraphics
import XCTest
@testable import OpenYoink

/// ShakeDetector 轨迹识别：典型摇动命中、直线/缓慢晃动/微抖不命中、
/// 阈值边界、时间窗裁剪、三档灵敏度参数差异、命中后复位。
final class MouseShakeMonitorTests: XCTestCase {
    // MARK: - Helpers

    /// 以固定步长喂入一组 x 坐标（y 恒定），返回发生命中的样本下标。
    private func hitIndices(xs: [CGFloat],
                            step: TimeInterval,
                            parameters: ShakeDetector.Parameters) -> [Int] {
        var detector = ShakeDetector(parameters: parameters)
        var hits: [Int] = []
        for (index, x) in xs.enumerated() {
            if detector.addSample(CGPoint(x: x, y: 500), at: TimeInterval(index) * step) {
                hits.append(index)
            }
        }
        return hits
    }

    /// 在两个 x 值之间来回的轨迹（典型摇动手势）。
    private func alternating(_ a: CGFloat, _ b: CGFloat, count: Int) -> [CGFloat] {
        (0..<count).map { $0.isMultiple(of: 2) ? a : b }
    }

    // MARK: - Hits

    func testTypicalShake_triggers() {
        // 中档：段长 40pt（≥18）、每 60ms 一步。确认方向后每步一次反转，
        // 第 5 次反转（t=0.36s，在 1.2s 窗内）即命中。
        let hits = hitIndices(xs: alternating(0, 40, count: 12),
                              step: 0.06,
                              parameters: TriggerSensitivity.medium.shakeParameters)
        XCTAssertEqual(hits, [6])
    }

    // MARK: - Non-gestures

    func testStraightLine_doesNotTrigger() {
        // 匀速直线：方向从不反转。
        let xs = (0..<200).map { CGFloat($0) * 8 }
        XCTAssertTrue(hitIndices(xs: xs, step: 0.016,
                                 parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
    }

    func testSlowWobble_doesNotTrigger() {
        // 缓慢晃动：段长足够，但反转间隔 0.6s —— 任意 1.5s 窗内最多 3 次
        // 反转（4 次反转至少跨 1.8s），凑不够高档要求的 4 次。
        XCTAssertTrue(hitIndices(xs: alternating(0, 50, count: 12),
                                 step: 0.6,
                                 parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
    }

    func testSmallJitter_doesNotTrigger() {
        // 微抖：3pt 远低于最小段长，方向永远无法确认。
        XCTAssertTrue(hitIndices(xs: alternating(0, 3, count: 150),
                                 step: 0.02,
                                 parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
    }

    func testVerticalMovement_doesNotTrigger() {
        // 仅垂直移动：x 无位移，不参与判定。
        var detector = ShakeDetector(parameters: TriggerSensitivity.high.shakeParameters)
        var fired = false
        for index in 0..<50 {
            let y: CGFloat = index.isMultiple(of: 2) ? 0 : 200
            fired = detector.addSample(CGPoint(x: 100, y: y),
                                       at: TimeInterval(index) * 0.05) || fired
        }
        XCTAssertFalse(fired)
    }

    // MARK: - Thresholds

    func testSegmentBelowMinDistance_doesNotTrigger() {
        // 段长 19 < 阈值 20：每次换向都重置累积器，方向永不确认。
        let parameters = ShakeDetector.Parameters(window: 2.0, requiredReversals: 3,
                                                  minSegmentDistance: 20)
        XCTAssertTrue(hitIndices(xs: alternating(0, 19, count: 40),
                                 step: 0.05, parameters: parameters).isEmpty)
    }

    func testSegmentExactlyAtMinDistance_triggers() {
        // 段长恰等于阈值（>= 判定）：确认后每步一次反转，第 3 次反转命中；
        // 命中复位后继续交替会重新凑满反转，再次命中（i=4 与 i=8）。
        let parameters = ShakeDetector.Parameters(window: 2.0, requiredReversals: 3,
                                                  minSegmentDistance: 20)
        XCTAssertEqual(hitIndices(xs: alternating(0, 20, count: 10),
                                  step: 0.05, parameters: parameters), [4, 8])
    }

    func testReversalsSpreadBeyondWindow_doNotAccumulate() {
        // 窗口 1.0s、需 4 次反转：先来 3 次快速反转，停顿 2s，再来 3 次。
        // 停顿前的反转被窗口裁剪，永远不能凑够 4 次。
        let parameters = ShakeDetector.Parameters(window: 1.0, requiredReversals: 4,
                                                  minSegmentDistance: 10)
        var detector = ShakeDetector(parameters: parameters)
        var fired = false
        var time: TimeInterval = 0
        var x: CGFloat = 0

        func feed(_ steps: Int) {
            for _ in 0..<steps {
                time += 0.05
                x = (x == 0) ? 20 : 0
                fired = detector.addSample(CGPoint(x: x, y: 500), at: time) || fired
            }
        }

        feed(4) // 确认方向 + 3 次反转（t=0.05...0.20）
        time += 2.0 // 停顿（不动即无样本意义，直接推进时钟）
        feed(3) // 又一批 3 次反转：旧反转全部过期，窗内最多 3 次 < 4 次
        XCTAssertFalse(fired)
    }

    // MARK: - Sensitivity tiers

    func testSensitivityTiers_shortSegmentsTriggerHighOnly() {
        // 14pt 段长、每 70ms 一次换向：
        // 高档（12pt/4 次/1.5s）命中；中档（18pt）方向都无法确认；低档同理。
        let xs = alternating(0, 14, count: 20)
        XCTAssertFalse(hitIndices(xs: xs, step: 0.07,
                                  parameters: TriggerSensitivity.high.shakeParameters).isEmpty)
        XCTAssertTrue(hitIndices(xs: xs, step: 0.07,
                                 parameters: TriggerSensitivity.medium.shakeParameters).isEmpty)
        XCTAssertTrue(hitIndices(xs: xs, step: 0.07,
                                 parameters: TriggerSensitivity.low.shakeParameters).isEmpty)
    }

    func testSensitivityTiers_fiveReversalsTriggerMediumButNotLow() {
        // 30pt 段长、每 110ms 一步，共 5 次反转（t≤0.66s）：
        // 中档需 5 次（1.2s 窗）命中；低档需 6 次，凑不够。
        let xs = alternating(0, 30, count: 7)
        XCTAssertEqual(hitIndices(xs: xs, step: 0.11,
                                  parameters: TriggerSensitivity.medium.shakeParameters), [6])
        XCTAssertTrue(hitIndices(xs: xs, step: 0.11,
                                 parameters: TriggerSensitivity.low.shakeParameters).isEmpty)
    }

    // MARK: - State reset after hit

    func testHitResetsState_nextGestureMustRequalify() {
        // 命中后识别器自复位：持续摇动会再次命中，但必须重新凑满反转次数
        // （两次命中间隔 6 个样本，而不是连续触发）。
        let hits = hitIndices(xs: alternating(0, 40, count: 14),
                              step: 0.06,
                              parameters: TriggerSensitivity.medium.shakeParameters)
        XCTAssertEqual(hits, [6, 12])
    }
}

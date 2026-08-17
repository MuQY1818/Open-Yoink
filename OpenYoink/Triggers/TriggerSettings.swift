import Foundation

/// Shared three-tier sensitivity for the shake and edge triggers
/// (plan §6: 「全局摇动误触」 calls for tunable sensitivity).
///
/// Persisted by `SettingsStore` as the raw value string under the existing
/// `OpenYoink.*Sensitivity` keys — no separate persistence lives here.
/// `CaseIterable` so the S8 settings page can drive a picker directly.
enum TriggerSensitivity: String, CaseIterable, Sendable, Codable {
    /// Hardest to trigger (longest dwell / most reversals, widest margins).
    case low
    case medium
    /// Easiest to trigger.
    case high
}

extension TriggerSensitivity {
    /// Shake heuristic parameters per tier (see `ShakeDetector`):
    ///
    /// | tier   | window | reversals | min segment |
    /// |--------|--------|-----------|-------------|
    /// | low    | 1.0 s  | 6         | 25 pt       |
    /// | medium | 1.2 s  | 5         | 18 pt       |
    /// | high   | 1.5 s  | 4         | 12 pt       |
    var shakeParameters: ShakeDetector.Parameters {
        switch self {
        case .low:
            return ShakeDetector.Parameters(window: 1.0, requiredReversals: 6, minSegmentDistance: 25)
        case .medium:
            return ShakeDetector.Parameters(window: 1.2, requiredReversals: 5, minSegmentDistance: 18)
        case .high:
            return ShakeDetector.Parameters(window: 1.5, requiredReversals: 4, minSegmentDistance: 12)
        }
    }

    /// Dwell time before the drag edge trigger fires (UX2 — fed by
    /// `leftMouseDragged` samples while the left button is held, so the dwell
    /// is much shorter than the pre-UX hover version): low 0.4 s, medium
    /// 0.2 s, high 0.1 s (higher sensitivity = shorter dwell).
    var edgeDwellTime: TimeInterval {
        switch self {
        case .low: return 0.4
        case .medium: return 0.2
        case .high: return 0.1
        }
    }

    /// Width of the edge band in points (UX2: mid-drag aiming is coarser than
    /// a parked cursor, so the band is wider than the pre-UX 3/4/6):
    /// low 6, medium 10, high 16.
    var edgeBandWidth: CGFloat {
        switch self {
        case .low: return 6
        case .medium: return 10
        case .high: return 16
        }
    }
}

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

    /// Dwell time before the edge trigger fires: low 1.0 s, medium 0.6 s,
    /// high 0.3 s (higher sensitivity = shorter dwell).
    var edgeDwellTime: TimeInterval {
        switch self {
        case .low: return 1.0
        case .medium: return 0.6
        case .high: return 0.3
        }
    }

    /// Width of the edge band in points: low 3, medium 4, high 6.
    var edgeBandWidth: CGFloat {
        switch self {
        case .low: return 3
        case .medium: return 4
        case .high: return 6
        }
    }
}

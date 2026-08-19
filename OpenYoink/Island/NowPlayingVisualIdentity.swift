import AppKit
import SwiftUI

/// Metadata that identifies a visible track change without treating playback
/// ticks, seeking, or play/pause updates as a new song. Keeping this identity
/// separate lets the Island cross-fade content only when the track changes.
struct NowPlayingTrackVisualIdentity: Hashable, Sendable {
    let title: String
    let artist: String?
    let album: String?
    let sourceName: String?

    init(snapshot: NowPlayingSnapshot) {
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        sourceName = snapshot.sourceName
    }
}

/// A display-safe accent distilled from album artwork. The extracted color is
/// normalized for use on an OLED-black surface so very dark or washed-out
/// covers still produce a visible ring and visualizer.
struct ArtworkAccent: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = ArtworkAccent(red: 0.18, green: 0.52, blue: 1.0)

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

@MainActor
enum ArtworkAccentExtractor {
    static func accent(from data: Data?) -> ArtworkAccent {
        guard let data,
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            return .fallback
        }

        let binCount = 24
        var bins = Array(repeating: ColorBin(), count: binCount)
        let xSamples = min(bitmap.pixelsWide, 24)
        let ySamples = min(bitmap.pixelsHigh, 24)

        for sampleY in 0..<ySamples {
            let y = min(bitmap.pixelsHigh - 1,
                        sampleY * bitmap.pixelsHigh / ySamples)
            for sampleX in 0..<xSamples {
                let x = min(bitmap.pixelsWide - 1,
                            sampleX * bitmap.pixelsWide / xSamples)
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.45 else { continue }

                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue,
                             saturation: &saturation,
                             brightness: &brightness,
                             alpha: &alpha)
                guard saturation >= 0.16,
                      brightness >= 0.10,
                      brightness <= 0.96 else { continue }

                let index = min(binCount - 1, Int(hue * CGFloat(binCount)))
                let luminancePreference = 1 - abs(Double(brightness) - 0.58) * 0.7
                let weight = pow(Double(saturation), 1.35)
                    * max(0.25, luminancePreference)
                    * (0.55 + Double(brightness) * 0.45)
                bins[index].add(color: color, weight: weight)
            }
        }

        guard let winner = bins.max(by: { $0.weight < $1.weight }),
              winner.weight > 0 else { return .fallback }
        let average = NSColor(
            calibratedRed: winner.red / winner.weight,
            green: winner.green / winner.weight,
            blue: winner.blue / winner.weight,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        average.getHue(&hue,
                       saturation: &saturation,
                       brightness: &brightness,
                       alpha: &alpha)

        let displayColor = NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation, 0.48), 0.86),
            brightness: min(max(brightness, 0.68), 0.94),
            alpha: 1
        )
        return ArtworkAccent(red: Double(displayColor.redComponent),
                             green: Double(displayColor.greenComponent),
                             blue: Double(displayColor.blueComponent))
    }

    private struct ColorBin {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0

        mutating func add(color: NSColor, weight: Double) {
            red += Double(color.redComponent) * weight
            green += Double(color.greenComponent) * weight
            blue += Double(color.blueComponent) * weight
            self.weight += weight
        }
    }
}

/// Creates a stable, per-track visual rhythm without capturing system audio.
/// Playback state starts and stops the animation, while track metadata changes
/// the apparent tempo, phase, and response of every bar.
enum MusicVisualizerRhythm {
    static func seed(title: String, artist: String?, album: String?) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in [title, artist ?? "", album ?? ""].joined(separator: "\u{1F}").utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }

    static func level(bar index: Int, time: TimeInterval, seed: UInt64) -> Double {
        let barSeed = mixed(seed &+ UInt64(index &+ 1) &* 0x9E37_79B9_7F4A_7C15)
        let speed = 3.1 + unit(barSeed) * 2.8
        let phase = unit(mixed(barSeed &+ 1)) * .pi * 2
        let secondarySpeed = 7.0 + unit(mixed(barSeed &+ 2)) * 3.8
        let secondaryPhase = unit(mixed(barSeed &+ 3)) * .pi * 2

        let primary = sin(time * speed + phase) * 0.5 + 0.5
        let secondary = sin(time * secondarySpeed + secondaryPhase) * 0.5 + 0.5

        let beatsPerSecond = 1.25 + unit(mixed(seed &+ 4)) * 1.05
        let beatOffset = unit(mixed(barSeed &+ 5)) * 0.18
        let beatPhase = (time * beatsPerSecond + beatOffset)
            .truncatingRemainder(dividingBy: 1)
        let pulse = pow(max(0, 1 - beatPhase / 0.24), 2.2)
        let response = 0.45 + unit(mixed(barSeed &+ 6)) * 0.55

        return min(max(0.10 + primary * 0.43 + secondary * 0.19
                       + pulse * response * 0.34, 0), 1)
    }

    private static func mixed(_ input: UInt64) -> UInt64 {
        var value = input
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func unit(_ value: UInt64) -> Double {
        Double(value & 0xFFFF) / Double(0xFFFF)
    }
}

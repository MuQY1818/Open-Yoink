import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class NowPlayingVisualIdentityTests: XCTestCase {
    func testTrackVisualIdentityIgnoresPlaybackTicksAndTransportState() {
        let first = NowPlayingSnapshot(
            title: "Track",
            artist: "Artist",
            album: "Album",
            isPlaying: true,
            sourceName: "com.example.player",
            artworkData: Data([0x01]),
            duration: 180,
            elapsedTime: 12,
            playbackRate: 1
        )
        var updatedPlayback = first
        updatedPlayback.isPlaying = false
        updatedPlayback.artworkData = Data([0x02])
        updatedPlayback.elapsedTime = 48
        updatedPlayback.playbackRate = 0

        XCTAssertEqual(NowPlayingTrackVisualIdentity(snapshot: first),
                       NowPlayingTrackVisualIdentity(snapshot: updatedPlayback))
    }

    func testTrackVisualIdentityChangesWithVisibleMetadata() {
        let first = NowPlayingSnapshot(
            title: "Track A",
            artist: "Artist",
            album: "Album",
            isPlaying: true,
            sourceName: "com.example.player"
        )
        var nextTrack = first
        nextTrack.title = "Track B"
        var nextSource = first
        nextSource.sourceName = "com.example.other-player"

        XCTAssertNotEqual(NowPlayingTrackVisualIdentity(snapshot: first),
                          NowPlayingTrackVisualIdentity(snapshot: nextTrack))
        XCTAssertNotEqual(NowPlayingTrackVisualIdentity(snapshot: first),
                          NowPlayingTrackVisualIdentity(snapshot: nextSource))
    }

    func testArtworkAccentFollowsDominantCoverColor() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 6,
            pixelsHigh: 6,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for y in 0..<6 {
            for x in 0..<6 {
                bitmap.setColor(NSColor(calibratedRed: 0.82,
                                        green: 0.12,
                                        blue: 0.20,
                                        alpha: 1),
                                atX: x,
                                y: y)
            }
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let accent = ArtworkAccentExtractor.accent(from: data)
        XCTAssertGreaterThan(accent.red, accent.green * 2)
        XCTAssertGreaterThan(accent.red, accent.blue * 2)
    }

    func testRhythmSeedIsStableAndTrackSpecific() {
        let first = MusicVisualizerRhythm.seed(title: "Track A",
                                                artist: "Artist",
                                                album: "Album")
        XCTAssertEqual(first,
                       MusicVisualizerRhythm.seed(title: "Track A",
                                                  artist: "Artist",
                                                  album: "Album"))
        XCTAssertNotEqual(first,
                          MusicVisualizerRhythm.seed(title: "Track B",
                                                     artist: "Artist",
                                                     album: "Album"))
    }

    func testRhythmLevelsStayNormalizedAndDifferAcrossTracks() {
        let first = MusicVisualizerRhythm.seed(title: "Track A", artist: nil, album: nil)
        let second = MusicVisualizerRhythm.seed(title: "Track B", artist: nil, album: nil)
        let firstLevels = (0..<5).map {
            MusicVisualizerRhythm.level(bar: $0, time: 12.34, seed: first)
        }
        let secondLevels = (0..<5).map {
            MusicVisualizerRhythm.level(bar: $0, time: 12.34, seed: second)
        }
        XCTAssertTrue(firstLevels.allSatisfy { (0...1).contains($0) })
        XCTAssertNotEqual(firstLevels, secondLevels)
    }
}

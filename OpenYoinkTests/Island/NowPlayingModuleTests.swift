import XCTest
@testable import OpenYoink

@MainActor
final class NowPlayingModuleTests: XCTestCase {
    func testAdapterPayloadParsesWrappedJSON() throws {
        let data = try XCTUnwrap("""
        {"type":"data","payload":{"title":"Track","artist":"Artist","album":"Album","playbackRate":1,"bundleIdentifier":"com.apple.Music"}}
        """.data(using: .utf8))
        XCTAssertEqual(NowPlayingSnapshot.decodeAdapterPayload(data),
                       .init(title: "Track", artist: "Artist", album: "Album",
                             isPlaying: true, sourceName: "com.apple.Music",
                             playbackRate: 1))
    }

    func testAdapterPlayingFieldTakesPrecedence() throws {
        let data = try XCTUnwrap("""
        {"type":"data","payload":{"title":"Paused Track","playing":false,"playbackRate":1}}
        """.data(using: .utf8))
        XCTAssertEqual(NowPlayingSnapshot.decodeAdapterPayload(data)?.isPlaying, false)
    }

    func testMissingOrBlankTitleIsRejected() throws {
        let missing = try XCTUnwrap("{\"artist\":\"A\"}".data(using: .utf8))
        let blank = try XCTUnwrap("{\"title\":\"  \"}".data(using: .utf8))
        XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(missing))
        XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(blank))
    }

    func testMalformedOutputIsIsolated() {
        XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(Data([0xFF, 0x00])))
    }

    func testScrubMathSupportsClickAndDragClamping() {
        XCTAssertEqual(MediaScrubMath.seconds(at: 0, width: 200, duration: 240), 0)
        XCTAssertEqual(MediaScrubMath.seconds(at: 50, width: 200, duration: 240), 60)
        XCTAssertEqual(MediaScrubMath.seconds(at: 250, width: 200, duration: 240), 240)
        XCTAssertEqual(MediaScrubMath.seconds(at: -10, width: 200, duration: 240), 0)
        XCTAssertEqual(MediaScrubMath.seconds(at: 20, width: 0, duration: 240), 0)
    }

    func testScrubMathKeepsThumbCenteredUnderPointer() {
        let width = 532.0
        let inset = 5.0
        let pointerLocation = 329.5
        let seconds = MediaScrubMath.seconds(at: pointerLocation,
                                             width: width,
                                             duration: 223,
                                             horizontalInset: inset)
        XCTAssertEqual(MediaScrubMath.location(for: seconds,
                                               width: width,
                                               duration: 223,
                                               horizontalInset: inset),
                       pointerLocation,
                       accuracy: 0.001)
        XCTAssertEqual(MediaScrubMath.location(for: 0,
                                               width: width,
                                               duration: 223,
                                               horizontalInset: inset), inset)
        XCTAssertEqual(MediaScrubMath.location(for: 223,
                                               width: width,
                                               duration: 223,
                                               horizontalInset: inset), width - inset)
    }

    func testAdapterPayloadParsesArtworkAndTimeline() throws {
        let artwork = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = artwork.base64EncodedString()
        let data = try XCTUnwrap("""
        {"type":"data","payload":{"title":"Track","artworkData":"\(encoded)","duration":245.5,"elapsedTime":61.25,"playbackRate":1}}
        """.data(using: .utf8))
        let snapshot = try XCTUnwrap(NowPlayingSnapshot.decodeAdapterPayload(data))
        XCTAssertEqual(snapshot.artworkData, artwork)
        XCTAssertEqual(snapshot.duration, 245.5)
        XCTAssertEqual(snapshot.elapsedTime, 61.25)
        XCTAssertEqual(snapshot.playbackRate, 1)
    }

    func testProjectedElapsedAdvancesOnlyWhilePlayingAndClamps() throws {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: true, sourceName: nil,
                               duration: 100, elapsedTime: 90, playbackRate: 1))
        XCTAssertEqual(store.projectedElapsed(
            at: store.snapshotReceivedAt.addingTimeInterval(20)
        ), 100)

        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: false, sourceName: nil,
                               duration: 100, elapsedTime: 42, playbackRate: 0))
        XCTAssertEqual(store.projectedElapsed(
            at: store.snapshotReceivedAt.addingTimeInterval(20)
        ), 42)
    }

    func testSeekClampsTargetAndUpdatesProjectedPosition() async throws {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: false, sourceName: "Player",
                               duration: 100, elapsedTime: 10))

        let succeeded = await store.seek(to: 140)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(source.commands.last, .seek(to: 100))
        XCTAssertEqual(store.projectedElapsed(), 100)
    }

    func testRepeatedSeekFailureDisablesSeekingForCurrentSource() async {
        let source = FakeSource()
        source.sendResult = false
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 100, elapsedTime: 10, playbackRate: 1))

        let firstAttempt = await store.seek(to: 20)
        XCTAssertFalse(firstAttempt)
        XCTAssertTrue(store.supportsSeeking)
        let secondAttempt = await store.seek(to: 30)
        XCTAssertFalse(secondAttempt)
        XCTAssertFalse(store.supportsSeeking)
    }

    func testPendingSeekIgnoresStaleTimelineUntilSourceConverges() async throws {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 200, elapsedTime: 10, playbackRate: 1))
        let succeeded = await store.seek(to: 80)
        XCTAssertTrue(succeeded)

        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 200, elapsedTime: 11, playbackRate: 1))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.projectedElapsed()), 79)

        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 200, elapsedTime: 80.5, playbackRate: 1))
        XCTAssertEqual(try XCTUnwrap(store.snapshot?.elapsedTime), 80.5, accuracy: 0.01)
    }

    func testJSONLineBufferHandlesSplitAndMultipleLines() {
        var buffer = JSONLineBuffer()
        XCTAssertTrue(buffer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = buffer.append(Data("1}\n{\"b\":2}\npartial".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(buffer.append(Data("-end\n".utf8))
            .map { String(decoding: $0, as: UTF8.self) }, ["partial-end"])
    }

    func testRetryPolicyStopsAfterOneTwoFourSeconds() {
        XCTAssertEqual(AdapterRetryPolicy.delay(afterFailure: 1), .seconds(1))
        XCTAssertEqual(AdapterRetryPolicy.delay(afterFailure: 2), .seconds(2))
        XCTAssertEqual(AdapterRetryPolicy.delay(afterFailure: 3), .seconds(4))
        XCTAssertNil(AdapterRetryPolicy.delay(afterFailure: 4))
    }

    func testPrimaryFailureStartsFallbackWithoutFailingWholeModule() {
        let primary = FakeSource()
        let fallback = FakeSource()
        let source = FallbackNowPlayingSource(primary: primary, fallback: fallback)
        var failed = false
        source.start(onSnapshot: { _ in }, onFailure: { failed = true })
        XCTAssertEqual(primary.startCount, 1)
        primary.fail?()
        XCTAssertEqual(primary.stopCount, 1)
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertFalse(failed)
    }

    func testModuleStopReleasesSourceAndClearsActivity() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        var activities: [IslandActivity?] = []
        store.onActivity = { activities.append($0) }
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: true, sourceName: nil))
        XCTAssertEqual(store.availability, .available)
        XCTAssertNotNil(store.snapshot)
        store.stop()
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(store.availability, .disabled)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(activities.last ?? nil)
    }

    func testModuleStartIsIdempotent() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        store.start()
        XCTAssertEqual(source.startCount, 1)
        store.stop()
    }

    private final class FakeSource: NowPlayingSource {
        var supportsTransportControls = true
        var supportsSeeking = true
        var sendResult = true
        var commands: [NowPlayingCommand] = []
        var startCount = 0
        var stopCount = 0
        var snapshot: ((NowPlayingSnapshot?) -> Void)?
        var fail: (() -> Void)?

        func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
                   onFailure: @escaping @MainActor () -> Void) {
            startCount += 1
            snapshot = onSnapshot
            fail = onFailure
        }

        func stop() { stopCount += 1 }
        func send(_ command: NowPlayingCommand) async -> Bool {
            commands.append(command)
            return sendResult
        }
    }
}

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
                             isPlaying: true, sourceName: "com.apple.Music"))
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
        func send(_ command: NowPlayingCommand) async -> Bool { true }
    }
}

import Foundation
import Observation

enum NowPlayingCommand: Sendable, Equatable {
    case togglePlayPause
    case previousTrack
    case nextTrack
    case seek(to: TimeInterval)
}

struct NowPlayingSnapshot: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var isPlaying: Bool
    var sourceName: String?
    var artworkData: Data? = nil
    var duration: TimeInterval? = nil
    var elapsedTime: TimeInterval? = nil
    var playbackRate: Double = 0

    static func decodeAdapterPayload(_ data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let payload: [String: Any]
        if let wrapper = object as? [String: Any],
           let nested = wrapper["payload"] as? [String: Any] {
            payload = nested
        } else if let dictionary = object as? [String: Any] {
            payload = dictionary
        } else {
            return nil
        }
        guard let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let rate = finiteNumber(payload["playbackRate"]) ?? 0
        let playing = (payload["playing"] as? Bool)
            ?? (payload["isPlaying"] as? Bool)
            ?? (rate > 0)
        let artworkData: Data?
        if let encodedArtwork = payload["artworkData"] as? String,
           encodedArtwork.utf8.count <= 12_000_000 {
            artworkData = Data(base64Encoded: encodedArtwork,
                               options: .ignoreUnknownCharacters)
        } else {
            artworkData = nil
        }
        return .init(title: title,
                     artist: payload["artist"] as? String,
                     album: payload["album"] as? String,
                     isPlaying: playing,
                     sourceName: payload["bundleIdentifier"] as? String,
                     artworkData: artworkData,
                     duration: seconds(in: payload,
                                       regularKey: "duration",
                                       microsecondsKey: "durationMicros"),
                     elapsedTime: seconds(in: payload,
                                          regularKey: "elapsedTime",
                                          microsecondsKey: "elapsedTimeMicros"),
                     playbackRate: rate)
    }

    private static func seconds(
        in payload: [String: Any],
        regularKey: String,
        microsecondsKey: String
    ) -> TimeInterval? {
        if let seconds = finiteNumber(payload[regularKey]), seconds >= 0 {
            return seconds
        }
        if let micros = finiteNumber(payload[microsecondsKey]), micros >= 0 {
            return micros / 1_000_000
        }
        return nil
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

enum MediaScrubMath {
    static func seconds(
        at location: Double,
        width: Double,
        duration: TimeInterval,
        horizontalInset: Double = 0
    ) -> TimeInterval {
        guard location.isFinite,
              width.isFinite,
              width > 0,
              duration.isFinite,
              duration > 0 else { return 0 }
        let inset = min(max(horizontalInset, 0), width / 2)
        let trackWidth = width - inset * 2
        guard trackWidth > 0 else { return 0 }
        return min(max((location - inset) / trackWidth, 0), 1) * duration
    }

    static func location(
        for seconds: TimeInterval,
        width: Double,
        duration: TimeInterval,
        horizontalInset: Double = 0
    ) -> Double {
        guard seconds.isFinite,
              width.isFinite,
              width > 0,
              duration.isFinite,
              duration > 0 else { return 0 }
        let inset = min(max(horizontalInset, 0), width / 2)
        let trackWidth = width - inset * 2
        let progress = min(max(seconds / duration, 0), 1)
        return inset + trackWidth * progress
    }
}

@MainActor
protocol NowPlayingSource: AnyObject {
    var supportsTransportControls: Bool { get }
    var supportsSeeking: Bool { get }
    func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
               onFailure: @escaping @MainActor () -> Void)
    func stop()
    func send(_ command: NowPlayingCommand) async -> Bool
}

/// The formal Island media module remains locally processed and opt-in. Its
/// OS-sensitive source is isolated so an unavailable player never affects the
/// shelf, timer, battery, or transfer modules.
@MainActor
@Observable
final class NowPlayingModuleStore: IslandModule {
    enum Availability: Equatable, Sendable {
        case disabled
        case probing
        case available
        case unavailable
    }

    let descriptor = IslandModuleDescriptor(
        id: .media,
        title: String(localized: "Now Playing"),
        systemImage: "music.note",
        order: 1,
        isCore: false
    )

    private let sourceFactory: @MainActor () -> NowPlayingSource?
    private var source: NowPlayingSource?
    private var pendingSeek: PendingSeek?
    private var seekFailureCounts: [String: Int] = [:]
    private var seekUnsupportedSources: Set<String> = []
    private(set) var availability: Availability = .disabled
    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var snapshotReceivedAt = Date()
    var onActivity: (@MainActor (IslandActivity?) -> Void)?

    init(sourceFactory: @escaping @MainActor () -> NowPlayingSource? = { nil }) {
        self.sourceFactory = sourceFactory
    }

    func start() {
        guard source == nil else { return }
        availability = .probing
        guard let source = sourceFactory() else {
            availability = .unavailable
            return
        }
        self.source = source
        source.start(onSnapshot: { [weak self] incomingSnapshot in
            guard let self else { return }
            var nextSnapshot = incomingSnapshot
            if var next = nextSnapshot,
               let previous = self.snapshot,
               next.title == previous.title,
               next.artist == previous.artist {
                if next.artworkData == nil { next.artworkData = previous.artworkData }
                if next.duration == nil { next.duration = previous.duration }
                nextSnapshot = next
            }
            nextSnapshot = self.snapshotApplyingPendingSeek(to: nextSnapshot, at: Date())
            self.snapshot = nextSnapshot
            self.snapshotReceivedAt = Date()
            self.availability = .available
            self.publishActivity()
        }, onFailure: { [weak self] in
            guard let self else { return }
            self.source?.stop()
            self.source = nil
            self.snapshot = nil
            self.availability = .unavailable
            self.onActivity?(nil)
        })
    }

    func stop() {
        source?.stop()
        source = nil
        snapshot = nil
        pendingSeek = nil
        seekFailureCounts.removeAll()
        seekUnsupportedSources.removeAll()
        availability = .disabled
        onActivity?(nil)
    }

    var supportsTransportControls: Bool {
        source?.supportsTransportControls == true
    }

    var supportsSeeking: Bool {
        guard let source,
              source.supportsSeeking,
              let duration = snapshot?.duration,
              duration.isFinite,
              duration > 0 else { return false }
        return !seekUnsupportedSources.contains(seekCapabilityKey)
    }

    func send(_ command: NowPlayingCommand) async -> Bool {
        guard let source, supportsTransportControls else { return false }
        return await source.send(command)
    }

    func seek(to requestedSeconds: TimeInterval) async -> Bool {
        guard let source,
              supportsSeeking,
              requestedSeconds.isFinite,
              let duration = snapshot?.duration else { return false }
        let target = min(max(0, requestedSeconds), duration)
        let capabilityKey = seekCapabilityKey
        let succeeded = await source.send(.seek(to: target))
        guard succeeded else {
            let failures = seekFailureCounts[capabilityKey, default: 0] + 1
            seekFailureCounts[capabilityKey] = failures
            if failures >= 2 {
                seekUnsupportedSources.insert(capabilityKey)
            }
            return false
        }

        seekFailureCounts[capabilityKey] = 0
        seekUnsupportedSources.remove(capabilityKey)
        let now = Date()
        pendingSeek = PendingSeek(identity: trackIdentity,
                                  target: target,
                                  requestedAt: now)
        snapshot?.elapsedTime = target
        snapshotReceivedAt = now
        return true
    }

    func projectedElapsed(at date: Date = Date()) -> TimeInterval? {
        guard let snapshot,
              let duration = snapshot.duration,
              duration > 0,
              let reportedElapsed = snapshot.elapsedTime else { return nil }
        let rate = snapshot.playbackRate > 0 ? snapshot.playbackRate : 1
        let drift = snapshot.isPlaying
            ? max(0, date.timeIntervalSince(snapshotReceivedAt)) * rate
            : 0
        return min(max(0, reportedElapsed + drift), duration)
    }

    private func publishActivity() {
        guard let snapshot else {
            onActivity?(nil)
            return
        }
        onActivity?(.init(id: "media.now-playing", moduleID: .media,
                          priority: .nowPlaying,
                          title: snapshot.title, detail: snapshot.artist,
                          systemImage: snapshot.isPlaying ? "waveform" : "pause.fill",
                          expiresAt: nil))
    }

    private var seekCapabilityKey: String {
        snapshot?.sourceName ?? "active-player"
    }

    private var trackIdentity: TrackIdentity? {
        snapshot.map { TrackIdentity(title: $0.title, artist: $0.artist) }
    }

    private func snapshotApplyingPendingSeek(
        to incoming: NowPlayingSnapshot?,
        at date: Date
    ) -> NowPlayingSnapshot? {
        guard var incoming, let pendingSeek else { return incoming }
        let identity = TrackIdentity(title: incoming.title, artist: incoming.artist)
        guard identity == pendingSeek.identity else {
            self.pendingSeek = nil
            return incoming
        }
        let rate = incoming.isPlaying ? max(incoming.playbackRate, 1) : 0
        let expected = pendingSeek.target
            + max(0, date.timeIntervalSince(pendingSeek.requestedAt)) * rate
        if let reported = incoming.elapsedTime,
           abs(reported - expected) <= 1.5 {
            self.pendingSeek = nil
            return incoming
        }
        guard date.timeIntervalSince(pendingSeek.requestedAt) < 2.5 else {
            self.pendingSeek = nil
            return incoming
        }
        if let duration = incoming.duration {
            incoming.elapsedTime = min(max(0, expected), duration)
        } else {
            incoming.elapsedTime = max(0, expected)
        }
        return incoming
    }

    private struct PendingSeek {
        let identity: TrackIdentity?
        let target: TimeInterval
        let requestedAt: Date
    }

    private struct TrackIdentity: Equatable {
        let title: String
        let artist: String?
    }
}

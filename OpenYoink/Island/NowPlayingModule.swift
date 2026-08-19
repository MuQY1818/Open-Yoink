import Foundation
import Observation

enum NowPlayingCommand: Sendable {
    case togglePlayPause
    case previousTrack
    case nextTrack
}

struct NowPlayingSnapshot: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var isPlaying: Bool
    var sourceName: String?

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
        let rate = (payload["playbackRate"] as? NSNumber)?.doubleValue ?? 0
        let playing = (payload["playing"] as? Bool)
            ?? (payload["isPlaying"] as? Bool)
            ?? (rate > 0)
        return .init(title: title,
                     artist: payload["artist"] as? String,
                     album: payload["album"] as? String,
                     isPlaying: playing,
                     sourceName: payload["bundleIdentifier"] as? String)
    }
}

@MainActor
protocol NowPlayingSource: AnyObject {
    var supportsTransportControls: Bool { get }
    func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
               onFailure: @escaping @MainActor () -> Void)
    func stop()
    func send(_ command: NowPlayingCommand) async -> Bool
}

/// v1.4.0 ships the stable abstraction while keeping the module hidden.
/// v1.4.1 injects the bundled adapter/fallback source when the opt-in setting
/// is enabled; an unavailable source never affects the other Island modules.
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
        systemImage: "play.circle",
        order: 4,
        isCore: false
    )

    private let sourceFactory: @MainActor () -> NowPlayingSource?
    private var source: NowPlayingSource?
    private(set) var availability: Availability = .disabled
    private(set) var snapshot: NowPlayingSnapshot?
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
        source.start(onSnapshot: { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
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
        availability = .disabled
        onActivity?(nil)
    }

    var supportsTransportControls: Bool {
        source?.supportsTransportControls == true
    }

    func send(_ command: NowPlayingCommand) async -> Bool {
        guard let source, supportsTransportControls else { return false }
        return await source.send(command)
    }

    private func publishActivity() {
        guard let snapshot else {
            onActivity?(nil)
            return
        }
        onActivity?(.init(id: "media.now-playing", moduleID: .media,
                          priority: .selectedModule,
                          title: snapshot.title, detail: snapshot.artist,
                          systemImage: snapshot.isPlaying ? "play.fill" : "pause.fill",
                          expiresAt: nil))
    }
}

import AppKit
import Foundation

struct MediaRemoteAdapterAssets: Equatable, Sendable {
    let scriptURL: URL
    let frameworkURL: URL
    let testClientURL: URL

    static func bundled(in bundle: Bundle = .main) -> Self? {
        guard let resourceBundleURL = bundle.url(
            forResource: "MediaRemoteAdapterResources", withExtension: "bundle"
        ), let resourceBundle = Bundle(url: resourceBundleURL),
        let scriptURL = resourceBundle.url(forResource: "mediaremote-adapter",
                                            withExtension: "pl"),
        let frameworkURL = resourceBundle.url(forResource: "MediaRemoteAdapter",
                                               withExtension: "framework"),
        let testClientURL = resourceBundle.url(forResource: "MediaRemoteAdapterTestClient",
                                                withExtension: nil)
        else { return nil }
        return .init(scriptURL: scriptURL,
                     frameworkURL: frameworkURL,
                     testClientURL: testClientURL)
    }
}

enum AdapterRetryPolicy {
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    static func delay(afterFailure failureCount: Int) -> Duration? {
        guard failureCount > 0, failureCount <= delays.count else { return nil }
        return delays[failureCount - 1]
    }
}

struct JSONLineBuffer: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}

@MainActor
final class MediaRemoteAdapterSource: NowPlayingSource {
    private let assets: MediaRemoteAdapterAssets
    private var probeProcess: Process?
    private var streamProcess: Process?
    private var retryTask: Task<Void, Never>?
    private var stdoutBuffer = JSONLineBuffer()
    private var failureCount = 0
    private var invalidPayloadCount = 0
    private var stopped = true
    private var isReady = false
    private var onSnapshot: (@MainActor (NowPlayingSnapshot?) -> Void)?
    private var onFailure: (@MainActor () -> Void)?

    var supportsTransportControls: Bool { isReady && !stopped }
    var supportsSeeking: Bool { isReady && !stopped }

    init(assets: MediaRemoteAdapterAssets) {
        self.assets = assets
    }

    func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
               onFailure: @escaping @MainActor () -> Void) {
        guard stopped else { return }
        stopped = false
        isReady = false
        failureCount = 0
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
        launchAfterCapabilityProbe()
    }

    func stop() {
        stopped = true
        isReady = false
        retryTask?.cancel()
        retryTask = nil
        if let process = probeProcess {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
        probeProcess = nil
        if let process = streamProcess {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        streamProcess = nil
        stdoutBuffer = JSONLineBuffer()
        invalidPayloadCount = 0
        onSnapshot = nil
        onFailure = nil
    }

    func send(_ command: NowPlayingCommand) async -> Bool {
        guard supportsTransportControls else { return false }
        switch command {
        case .seek(let seconds):
            guard seconds.isFinite else { return false }
            let microseconds = Int64((max(0, seconds) * 1_000_000).rounded())
            return await Self.runAndWait(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: commonArguments + ["seek", String(microseconds)]
            ) == 0
        case .togglePlayPause, .nextTrack, .previousTrack:
            let id: String
            switch command {
            case .togglePlayPause: id = "2"
            case .nextTrack: id = "4"
            case .previousTrack: id = "5"
            case .seek: return false
            }
            return await Self.runAndWait(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: commonArguments + ["send", id]
            ) == 0
        }
    }

    private var commonArguments: [String] {
        [assets.scriptURL.path, assets.frameworkURL.path, assets.testClientURL.path]
    }

    private func launchAfterCapabilityProbe() {
        retryTask?.cancel()
        retryTask = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = commonArguments + ["test"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self, weak process] finished in
            Task { @MainActor in
                guard let self, let process else { return }
                self.probeDidFinish(process, status: finished.terminationStatus)
            }
        }
        do {
            try process.run()
            probeProcess = process
        } catch {
            scheduleRetryOrFail()
        }
    }

    private func probeDidFinish(_ process: Process, status: Int32) {
        guard !stopped else { return }
        if probeProcess === process { probeProcess = nil }
        if status == 0 {
            launchStream()
        } else {
            scheduleRetryOrFail()
        }
    }

    private func launchStream() {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = commonArguments + [
            "stream", "--no-diff", "--debounce=250",
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.streamDidTerminate() }
        }
        do {
            try process.run()
            streamProcess = process
            isReady = true
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            scheduleRetryOrFail()
        }
    }

    private func consume(_ data: Data) {
        for line in stdoutBuffer.append(data) {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let wrapper = object as? [String: Any],
                  wrapper["type"] as? String == "data",
                  let payload = wrapper["payload"] as? [String: Any] else {
                invalidPayloadCount += 1
                if invalidPayloadCount >= 3, let streamProcess, streamProcess.isRunning {
                    streamProcess.terminate()
                    return
                }
                continue
            }
            invalidPayloadCount = 0
            failureCount = 0
            if payload.isEmpty {
                onSnapshot?(nil)
            } else if let snapshot = NowPlayingSnapshot.decodeAdapterPayload(line) {
                onSnapshot?(snapshot)
            } else {
                invalidPayloadCount += 1
                if invalidPayloadCount >= 3, let streamProcess, streamProcess.isRunning {
                    streamProcess.terminate()
                    return
                }
            }
        }
    }

    private func streamDidTerminate() {
        guard !stopped else { return }
        isReady = false
        if let pipe = streamProcess?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        streamProcess = nil
        scheduleRetryOrFail()
    }

    private func scheduleRetryOrFail() {
        guard !stopped else { return }
        failureCount += 1
        guard let delay = AdapterRetryPolicy.delay(afterFailure: failureCount) else {
            let callback = onFailure
            stop()
            callback?()
            return
        }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.launchAfterCapabilityProbe()
        }
    }

    nonisolated private static func runAndWait(executable: URL,
                                               arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}

@MainActor
final class AppleScriptNowPlayingSource: NowPlayingSource {
    private var pollingTask: Task<Void, Never>?
    private var currentBundleID: String?
    private var onSnapshot: (@MainActor (NowPlayingSnapshot?) -> Void)?
    private var onFailure: (@MainActor () -> Void)?
    private var executionFailureCount = 0

    var supportsTransportControls: Bool { currentBundleID != nil }
    var supportsSeeking: Bool { currentBundleID != nil }

    func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
               onFailure: @escaping @MainActor () -> Void) {
        guard pollingTask == nil else { return }
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentBundleID = nil
        executionFailureCount = 0
        onSnapshot = nil
        onFailure = nil
    }

    func send(_ command: NowPlayingCommand) async -> Bool {
        guard let bundleID = currentBundleID else { return false }
        let app = bundleID == "com.apple.Music" ? "Music" : "Spotify"
        switch command {
        case .seek(let seconds):
            guard seconds.isFinite else { return false }
            return await Self.execute(
                "tell application \"\(app)\" to set player position to \(max(0, seconds))"
            ) != nil
        case .togglePlayPause, .previousTrack, .nextTrack:
            let verb: String
            switch command {
            case .togglePlayPause: verb = "playpause"
            case .previousTrack: verb = "previous track"
            case .nextTrack: verb = "next track"
            case .seek: return false
            }
            return await Self.execute("tell application \"\(app)\" to \(verb)") != nil
        }
    }

    private func refresh() async {
        let candidates = [
            ("com.apple.Music", "Music"),
            ("com.spotify.client", "Spotify"),
        ].filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.0).isEmpty }

        var executedSuccessfully = false
        for (bundleID, app) in candidates {
            let durationExpression = bundleID == "com.spotify.client"
                ? "((duration of current track) / 1000)"
                : "(duration of current track)"
            let script = """
            tell application "\(app)"
                if player state is stopped then return ""
                return (name of current track) & linefeed & ¬
                    (artist of current track) & linefeed & ¬
                    (album of current track) & linefeed & ¬
                    (player state as text) & linefeed & ¬
                    (\(durationExpression) as text) & linefeed & ¬
                    (player position as text)
            end tell
            """
            guard let output = await Self.execute(script) else { continue }
            executedSuccessfully = true
            guard !output.isEmpty else { continue }
            let parts = output.components(separatedBy: .newlines)
            guard let title = parts.first, !title.isEmpty else { continue }
            currentBundleID = bundleID
            executionFailureCount = 0
            onSnapshot?(.init(title: title,
                              artist: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
                              album: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil,
                              isPlaying: parts.count > 3 && parts[3] == "playing",
                              sourceName: app,
                              duration: parts.count > 4 ? Double(parts[4]) : nil,
                              elapsedTime: parts.count > 5 ? Double(parts[5]) : nil,
                              playbackRate: parts.count > 3 && parts[3] == "playing" ? 1 : 0))
            return
        }
        currentBundleID = nil
        onSnapshot?(nil)
        guard !candidates.isEmpty, !executedSuccessfully else {
            executionFailureCount = 0
            return
        }
        executionFailureCount += 1
        guard executionFailureCount >= 3 else { return }
        let callback = onFailure
        stop()
        callback?()
    }

    nonisolated private static func execute(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
    }
}

@MainActor
final class FallbackNowPlayingSource: NowPlayingSource {
    private let primary: NowPlayingSource
    private let fallback: NowPlayingSource
    private var active: NowPlayingSource?
    private var stopped = true
    private var snapshotHandler: (@MainActor (NowPlayingSnapshot?) -> Void)?
    private var failureHandler: (@MainActor () -> Void)?

    init(primary: NowPlayingSource, fallback: NowPlayingSource) {
        self.primary = primary
        self.fallback = fallback
    }

    var supportsTransportControls: Bool {
        active?.supportsTransportControls == true
    }

    var supportsSeeking: Bool {
        active?.supportsSeeking == true
    }

    func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
               onFailure: @escaping @MainActor () -> Void) {
        guard stopped else { return }
        stopped = false
        snapshotHandler = onSnapshot
        failureHandler = onFailure
        active = primary
        primary.start(onSnapshot: onSnapshot, onFailure: { [weak self] in
            self?.startFallback()
        })
    }

    func stop() {
        stopped = true
        primary.stop()
        fallback.stop()
        active = nil
        snapshotHandler = nil
        failureHandler = nil
    }

    func send(_ command: NowPlayingCommand) async -> Bool {
        guard let active else { return false }
        return await active.send(command)
    }

    private func startFallback() {
        guard !stopped, let snapshotHandler, let failureHandler else { return }
        primary.stop()
        active = fallback
        fallback.start(onSnapshot: snapshotHandler, onFailure: failureHandler)
    }
}

@MainActor
enum NowPlayingSourceFactory {
    static func bundled() -> NowPlayingSource? {
        let fallback = AppleScriptNowPlayingSource()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"),
              let assets = MediaRemoteAdapterAssets.bundled() else { return fallback }
        return FallbackNowPlayingSource(primary: MediaRemoteAdapterSource(assets: assets),
                                        fallback: fallback)
    }
}

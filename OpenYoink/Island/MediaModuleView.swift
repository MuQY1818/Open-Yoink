import AppKit
import SwiftUI

struct IslandNowPlayingView: View {
    @Environment(NowPlayingModuleStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork: NSImage?
    @State private var artworkAccent = ArtworkAccent.fallback
    @State private var artworkRevision = 0
    @State private var isSendingCommand = false

    var body: some View {
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Now Playing",
                subtitle: nowPlayingSubtitle,
                systemImage: "music.note"
            )
            if store.availability == .disabled {
                VStack(spacing: 12) {
                    IslandEmptyState(
                        title: "Enable Now Playing",
                        message: "Show album artwork, playback progress, and media controls in the Island.",
                        systemImage: "music.note"
                    )
                    Button { settings.islandMediaEnabled = true } label: {
                        Label("Enable", systemImage: "waveform")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                }
            } else if store.availability == .probing {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking media access…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = store.snapshot {
                playerCard(snapshot)
            } else if store.availability == .available {
                IslandEmptyState(
                    title: "Nothing playing",
                    message: "Start media in a supported player.",
                    systemImage: "music.note"
                )
            } else {
                IslandEmptyState(
                    title: "Now Playing unavailable",
                    message: "OpenYoink could not read the current player. Other Island features still work normally.",
                    systemImage: "play.slash"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.snapshot?.artworkData, initial: true) { _, data in
            updateArtwork(with: data)
        }
    }

    private var nowPlayingSubtitle: String {
        guard let snapshot = store.snapshot else {
            return store.availability == .disabled
                ? String(localized: "Off")
                : String(localized: "Music and media controls")
        }
        if let sourceName = snapshot.sourceName {
            return sourceDisplayName(sourceName)
        }
        return snapshot.isPlaying ? String(localized: "Playing") : String(localized: "Paused")
    }

    private func playerCard(_ snapshot: NowPlayingSnapshot) -> some View {
        let trackIdentity = NowPlayingTrackVisualIdentity(snapshot: snapshot)

        return ZStack {
            artworkBackdrop
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.black.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .center, spacing: 14) {
                artworkView(isPlaying: snapshot.isPlaying)

                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        trackMetadata(snapshot)
                            .id(trackIdentity)
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, minHeight: 51,
                           maxHeight: 51, alignment: .topLeading)
                    .animation(trackCrossfadeAnimation, value: trackIdentity)

                    ZStack {
                        playbackProgress(snapshot)
                            .id(trackIdentity)
                            .transition(.opacity)
                    }
                    .animation(trackCrossfadeAnimation, value: trackIdentity)
                        .padding(.top, 10)

                    HStack(spacing: 14) {
                        mediaButton("backward.fill", command: .previousTrack,
                                    label: String(localized: "Previous track"))
                        mediaButton(snapshot.isPlaying ? "pause.fill" : "play.fill",
                                    command: .togglePlayPause,
                                    label: snapshot.isPlaying
                                    ? String(localized: "Pause") : String(localized: "Play"),
                                    emphasized: true)
                        mediaButton("forward.fill", command: .nextTrack,
                                    label: String(localized: "Next track"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
        }
    }

    private var artworkBackdrop: some View {
        ZStack {
            artworkBackdropLayer
                .id(artworkRevision)
                .transition(.opacity)
        }
        .animation(trackCrossfadeAnimation, value: artworkRevision)
    }

    private func artworkView(isPlaying: Bool) -> some View {
        ZStack {
            artworkLayer
                .id(artworkRevision)
                .transition(.opacity)
        }
        // Video thumbnails are often much wider than album covers. Constrain
        // the rendering surface before applying the rounded mask so
        // `.scaledToFill()` crops inside this square instead of retaining the
        // source image's wide intrinsic width and spilling into metadata.
        .frame(width: 104, height: 104)
        .clipped()
        .animation(trackCrossfadeAnimation, value: artworkRevision)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            IslandEqualizerView(
                isPlaying: isPlaying,
                reduceMotion: reduceMotion,
                tint: artworkAccent.color,
                rhythmSeed: visualizerSeed
            )
                .padding(7)
        }
        .shadow(color: .black.opacity(0.42), radius: 10, y: 4)
        .accessibilityLabel(Text("Album artwork"))
    }

    private func trackMetadata(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snapshot.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(snapshot.title)

            Text(snapshot.artist ?? String(localized: "Unknown artist"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .lineLimit(1)
                .padding(.top, 3)

            Text(visibleAlbum(snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandVisualStyle.tertiaryText)
                .lineLimit(1)
                .padding(.top, 2)
                .accessibilityHidden(snapshot.album?.isEmpty != false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func visibleAlbum(_ snapshot: NowPlayingSnapshot) -> String {
        guard let album = snapshot.album, !album.isEmpty else { return " " }
        return album
    }

    @ViewBuilder
    private var artworkBackdropLayer: some View {
        if let artwork {
            GeometryReader { proxy in
                Image(nsImage: artwork)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 32)
                    .scaleEffect(1.22)
                    .opacity(0.42)
            }
            .clipped()
        } else {
            LinearGradient(
                colors: [Color.indigo.opacity(0.58),
                         Color.accentColor.opacity(0.34),
                         Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var artworkLayer: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color.accentColor, Color.indigo, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var trackCrossfadeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .easeInOut(duration: 0.28)
    }

    private func updateArtwork(with data: Data?) {
        let nextArtwork = data.flatMap(NSImage.init(data:))
        let nextAccent = ArtworkAccentExtractor.accent(from: data)
        let update = {
            artwork = nextArtwork
            artworkAccent = nextAccent
            artworkRevision &+= 1
        }

        if artworkRevision == 0 {
            update()
        } else {
            withAnimation(trackCrossfadeAnimation, update)
        }
    }

    private func playbackProgress(_ snapshot: NowPlayingSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = snapshot.duration ?? 0
            let elapsed = store.projectedElapsed(at: context.date) ?? 0
            IslandMediaScrubber(
                duration: duration,
                elapsed: elapsed,
                tint: artworkAccent.color,
                isEnabled: store.supportsSeeking,
                onSeek: { await store.seek(to: $0) }
            )
        }
    }

    private func sourceDisplayName(_ source: String) -> String {
        source.split(separator: ".").last.map(String.init) ?? source
    }

    private func mediaButton(
        _ symbol: String,
        command: NowPlayingCommand,
        label: String,
        emphasized: Bool = false
    ) -> some View {
        Button {
            Task {
                isSendingCommand = true
                _ = await store.send(command)
                isSendingCommand = false
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: emphasized ? 16 : 12, weight: .bold))
                .foregroundStyle(emphasized ? Color.black : Color.white)
                .frame(width: emphasized ? 42 : 34,
                       height: emphasized ? 42 : 34)
                .background {
                    Circle().fill(emphasized ? Color.white : IslandVisualStyle.controlFill)
                }
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .disabled(!store.supportsTransportControls || isSendingCommand)
        .opacity(store.supportsTransportControls && !isSendingCommand ? 1 : 0.38)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }

    private var visualizerSeed: UInt64 {
        guard let snapshot = store.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }
}
private struct IslandMediaScrubber: View {
    let duration: TimeInterval
    let elapsed: TimeInterval
    let tint: Color
    let isEnabled: Bool
    let onSeek: @MainActor (TimeInterval) async -> Bool

    @State private var scrubbedSeconds: TimeInterval?
    @State private var isScrubbing = false
    @State private var isSeeking = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 0)
                let thumbSize = 10.0
                let trackInset = thumbSize / 2
                let trackWidth = max(0, width - trackInset * 2)
                let thumbCenter = MediaScrubMath.location(
                    for: displayedSeconds,
                    width: Double(width),
                    duration: duration,
                    horizontalInset: trackInset
                )
                let fillWidth = max(0, thumbCenter - trackInset)

                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.white.opacity(isEnabled ? 0.17 : 0.10))
                        .frame(width: trackWidth, height: 4)
                        .position(x: width / 2, y: 9)
                    if fillWidth > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: fillWidth, height: 4)
                            .position(x: trackInset + fillWidth / 2, y: 9)
                    }
                    Circle()
                        .fill(Color.white)
                        .overlay {
                            Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                        }
                        .shadow(color: tint.opacity(0.52), radius: 4)
                        .frame(width: thumbSize, height: thumbSize)
                        .position(x: thumbCenter, y: 9)
                        .opacity(showsThumb ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard isEnabled, !isSeeking else { return }
                            isScrubbing = true
                            scrubbedSeconds = MediaScrubMath.seconds(
                                at: Double(value.location.x),
                                width: Double(width),
                                duration: duration,
                                horizontalInset: trackInset
                            )
                        }
                        .onEnded { value in
                            guard isEnabled, !isSeeking else { return }
                            isScrubbing = false
                            let target = MediaScrubMath.seconds(
                                at: Double(value.location.x),
                                width: Double(width),
                                duration: duration,
                                horizontalInset: trackInset
                            )
                            commitSeek(target)
                        }
                )
            }
            .frame(height: 18)

            HStack {
                Text(formatTime(displayedSeconds))
                Spacer()
                Text(duration > 0 ? formatTime(duration) : "–:––")
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(IslandVisualStyle.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(formatTime(displayedSeconds)) / \(formatTime(duration))"))
        .accessibilityHint(Text(isEnabled
                                ? "Drag or click to seek"
                                : "Seeking is unavailable for this player"))
        .accessibilityAdjustableAction { direction in
            guard isEnabled, !isSeeking else { return }
            let step = max(5, duration * 0.02)
            switch direction {
            case .increment:
                commitSeek(min(duration, displayedSeconds + step))
            case .decrement:
                commitSeek(max(0, displayedSeconds - step))
            @unknown default:
                break
            }
        }
        .help(Text(isEnabled
                   ? "Drag or click to seek"
                   : "Seeking is unavailable for this player"))
    }

    private var displayedSeconds: TimeInterval {
        min(max(scrubbedSeconds ?? elapsed, 0), max(0, duration))
    }

    private var showsThumb: Bool {
        isEnabled && (isHovering || isScrubbing || isSeeking)
    }

    private func commitSeek(_ target: TimeInterval) {
        guard isEnabled, !isSeeking else { return }
        scrubbedSeconds = target
        isSeeking = true
        Task { @MainActor in
            _ = await onSeek(target)
            isSeeking = false
            scrubbedSeconds = nil
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let finiteSeconds = seconds.isFinite ? seconds : 0
        let total = max(0, Int(finiteSeconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Reveals the expanded surface with a moving bottom edge rather than scaling
/// its contents. Text, artwork, and controls keep their natural geometry while
/// the island visibly grows out of the notch even if the AppKit window resize
/// is coalesced into a single display update by the window server.

struct IslandEqualizerView: View {
    let isPlaying: Bool
    let reduceMotion: Bool
    var tint: Color = .accentColor
    var rhythmSeed: UInt64 = 0

    var body: some View {
        Group {
            if isPlaying && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    bars(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else if isPlaying {
                bars(time: 0.72)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .frame(width: 30, height: 22)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.72))
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                }
        }
        .shadow(color: isPlaying ? tint.opacity(0.32) : .clear,
                radius: 5)
        .accessibilityHidden(true)
    }

    private func bars(time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 1.8) {
            ForEach(0..<5, id: \.self) { index in
                let level = MusicVisualizerRhythm.level(
                    bar: index,
                    time: time,
                    seed: rhythmSeed
                )
                let height = 4 + CGFloat(level) * 10
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.96), tint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2.2, height: height)
            }
        }
    }
}

struct CompactNowPlayingArtworkView: View {
    @Environment(NowPlayingModuleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: NSImage
    let tint: Color
    let isHovered: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = store.snapshot?.duration ?? 0
            let elapsed = store.projectedElapsed(at: context.date) ?? 0
            let progress = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [.white, tint, .white],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(isHovered ? 0.16 : 0))
                    }
            }
            .frame(width: 23, height: 23)
            .scaleEffect(isHovered ? 1.04 : 1)
            .shadow(color: store.snapshot?.isPlaying == true
                    ? tint.opacity(0.38) : .clear,
                    radius: 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        }
        .accessibilityHidden(true)
    }
}

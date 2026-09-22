import AppKit
import AVFoundation
import AVKit
import Combine
import SwiftUI

enum RepeatMode: String, CaseIterable, Identifiable {
    case off, one, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .one: "Loop track"
        case .all: "Loop folder"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "repeat"
        case .one: "repeat.1"
        case .all: "repeat"
        }
    }
}

struct MediaItem: Identifiable, Equatable {
    var url: URL
    var isVideo: Bool
    var id: String { url.standardizedFileURL.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class MediaPlayback: ObservableObject {
    @Published var item: MediaItem?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.8 {
        didSet { player.volume = volume }
    }
    @Published var queue: [URL] = []
    @Published var queueIndex = 0
    @Published var shuffle = false {
        didSet {
            if shuffle {
                rebuildShuffle(startingAt: queueIndex)
            }
        }
    }
    @Published var autoNext = true
    @Published var repeatMode: RepeatMode = .off
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var playbackNote: String?

    let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var metadataTask: Task<Void, Never>?
    private var videoFallbackTask: Task<Void, Never>?
    private var vlcProcess: Process?
    private var shuffleOrder: [Int] = []

    var hasQueue: Bool { queue.count > 1 }
    var canGoNext: Bool { hasQueue || repeatMode == .all }
    var canGoPrevious: Bool { hasQueue || currentTime > 3 }

    init() {
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let item = self?.player.currentItem {
                    let length = item.duration.seconds
                    self?.duration = length.isFinite ? length : 0
                }
            }
        }
    }

    func play(_ url: URL, queue incoming: [URL] = []) {
        if incoming.count > 1 {
            queue = incoming
            queueIndex = incoming.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) ?? 0
            rebuildShuffle(startingAt: queueIndex)
        } else if queue.isEmpty || !queue.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            queue = incoming.isEmpty ? [url] : incoming
            queueIndex = 0
            rebuildShuffle(startingAt: 0)
        } else {
            queueIndex = queue.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) ?? 0
        }
        startCurrent()
    }

    func setQueue(_ urls: [URL]) {
        queue = urls
        if let item, let index = urls.firstIndex(where: { $0.standardizedFileURL == item.url.standardizedFileURL }) {
            queueIndex = index
        }
        rebuildShuffle(startingAt: queueIndex)
    }

    func toggle() {
        guard item != nil else {
            if let first = queue.first {
                play(first, queue: queue)
            }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        queueIndex = nextIndex()
        startCurrent()
    }

    func playPrevious() {
        if currentTime > 3 {
            seek(0)
            return
        }
        guard !queue.isEmpty else { return }
        queueIndex = previousIndex()
        startCurrent()
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private var fullScreenWindow: NSWindow?

    func toggleFullScreen() {
        if let window = fullScreenWindow {
            window.close()
            fullScreenWindow = nil
            return
        }
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(
            contentRect: screen,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.title = item?.name ?? "Video"
        window.isReleasedWhenClosed = false
        window.toggleFullScreen(nil)
        window.makeKeyAndOrderFront(nil)
        fullScreenWindow = window
    }

    func stop() {
        videoFallbackTask?.cancel()
        stopVLC()
        playbackNote = nil
        fullScreenWindow?.close()
        fullScreenWindow = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearEndObserver()
        metadataTask?.cancel()
        item = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        title = ""
        artist = ""
        album = ""
        artwork = nil
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    var timeLabel: String {
        "\(Self.format(currentTime)) / \(Self.format(duration))"
    }

    var displayTitle: String {
        title.isEmpty ? (item?.name ?? "Not playing") : title
    }

    var displaySubtitle: String {
        let parts = [artist, album].filter { !$0.isEmpty }
        if parts.isEmpty { return item?.url.deletingLastPathComponent().lastPathComponent ?? "" }
        return parts.joined(separator: " · ")
    }

    private func startCurrent() {
        guard queue.indices.contains(queueIndex) else { return }
        let url = queue[queueIndex]
        clearEndObserver()
        metadataTask?.cancel()
        videoFallbackTask?.cancel()
        stopVLC()
        playbackNote = nil
        let media = MediaItem(url: url, isVideo: MediaKind.isVideo(url))
        item = media
        title = media.name
        artist = ""
        album = ""
        artwork = nil
        currentTime = 0
        duration = 0
        loadMetadata(for: url)
        if media.isVideo {
            player.replaceCurrentItem(with: nil)
            playbackNote = "Preparing video…"
            isPlaying = false
            videoFallbackTask = Task { await startVideo(url) }
        } else {
            playURL(url)
        }
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEnded()
            }
        }
    }

    private func startVideo(_ url: URL) async {
        if await assetHasPlayableVideo(url) {
            guard !Task.isCancelled else { return }
            playURL(url)
            playbackNote = nil
            return
        }
        if let cached = cachedVideo(for: url), await assetHasPlayableVideo(cached) {
            guard !Task.isCancelled else { return }
            playURL(cached)
            playbackNote = nil
            return
        }
        playbackNote = "Preparing video…"
        if let local = await transcodeToFile(url), await assetHasPlayableVideo(local) {
            guard !Task.isCancelled else { return }
            playURL(local)
            playbackNote = nil
        } else if FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
            openInVLC(url)
            playbackNote = "Opened in VLC so you can see the picture."
        } else {
            playbackNote = "This video’s picture can’t play here. Install VLC to watch it."
        }
    }

    private func assetHasPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return await videoTrackIsPlayable(tracks.first)
    }

    private func playURL(_ url: URL) {
        clearEndObserver()
        let next = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: next)
        observeEnd(of: next)
        player.play()
        isPlaying = true
    }

    private func videoTrackIsPlayable(_ track: AVAssetTrack?) async -> Bool {
        guard let track else { return false }
        return (try? await track.load(.isPlayable)) ?? false
    }

    private func cachedVideo(for url: URL) -> URL? {
        let dest = transcodeCacheURL(for: url)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 80_000 ? dest : nil
    }

    private func transcodeCacheURL(for url: URL) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("UnZip/video", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var hash: UInt64 = 5381
        for byte in url.standardizedFileURL.path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let stamp = Int((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0)
        return folder.appendingPathComponent(String(format: "%016llx-%d.mp4", hash, stamp))
    }

    private func transcodeToFile(_ url: URL) async -> URL? {
        let vlc = URL(fileURLWithPath: "/Applications/VLC.app/Contents/MacOS/VLC")
        guard FileManager.default.isExecutableFile(atPath: vlc.path) else { return nil }
        let dest = transcodeCacheURL(for: url)
        try? FileManager.default.removeItem(at: dest)
        let process = Process()
        process.executableURL = vlc
        process.arguments = [
            "-I", "dummy",
            "--no-media-library",
            "--no-osd",
            "--play-and-exit",
            url.path,
            "--sout",
            "#transcode{vcodec=h264,venc=x264{preset=ultrafast,tune=fastdecode,keyint=30},vb=1800,width=960,acodec=mp4a,ab=96,channels=2,samplerate=44100}:standard{access=file,mux=mp4,dst=\(dest.path)}"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        vlcProcess = process
        while process.isRunning {
            if Task.isCancelled {
                stopVLC()
                try? FileManager.default.removeItem(at: dest)
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        vlcProcess = nil
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 80_000 ? dest : nil
    }

    private func openInVLC(_ url: URL) {
        let app = URL(fileURLWithPath: "/Applications/VLC.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func stopVLC() {
        if let process = vlcProcess, process.isRunning {
            process.terminate()
        }
        vlcProcess = nil
    }

    private func handleEnded() {
        switch repeatMode {
        case .one:
            seek(0)
            player.play()
            isPlaying = true
        case .all:
            playNext()
        case .off:
            if autoNext, hasQueue, queueIndex < queue.count - 1 || shuffle {
                playNext()
            } else {
                isPlaying = false
                seek(0)
            }
        }
    }

    private func nextIndex() -> Int {
        if shuffle {
            if let current = shuffleOrder.firstIndex(of: queueIndex) {
                return shuffleOrder[(current + 1) % shuffleOrder.count]
            }
            return (queueIndex + 1) % queue.count
        }
        return (queueIndex + 1) % queue.count
    }

    private func previousIndex() -> Int {
        if shuffle {
            if let current = shuffleOrder.firstIndex(of: queueIndex) {
                return shuffleOrder[(current - 1 + shuffleOrder.count) % shuffleOrder.count]
            }
        }
        return (queueIndex - 1 + queue.count) % queue.count
    }

    private func rebuildShuffle(startingAt index: Int) {
        var order = Array(queue.indices)
        if !order.isEmpty {
            order.shuffle()
            if let found = order.firstIndex(of: index) {
                order.swapAt(0, found)
            }
        }
        shuffleOrder = order
    }

    private func loadMetadata(for url: URL) {
        metadataTask = Task {
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata) else { return }
            var nextTitle = ""
            var nextArtist = ""
            var nextAlbum = ""
            var nextArt: NSImage?
            for item in metadata {
                if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue) {
                    nextTitle = value
                } else if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue) {
                    nextArtist = value
                } else if item.commonKey == .commonKeyAlbumName, let value = try? await item.load(.stringValue) {
                    nextAlbum = value
                } else if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.dataValue) {
                    nextArt = NSImage(data: data)
                }
            }
            guard !Task.isCancelled else { return }
            title = nextTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : nextTitle
            artist = nextArtist
            album = nextAlbum
            artwork = nextArt
        }
    }

    private func clearEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MediaBar: View {
    @ObservedObject var playback: MediaPlayback
    var height: CGFloat
    var folderTracks: [URL]
    var onOpenPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(playback.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(playback.displaySubtitle.isEmpty ? queueLabel : playback.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 90, maxWidth: 220, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenPreview)

            transport
            if playback.item?.isVideo != true {
                extras
            }

            if playback.item?.isVideo == true {
                Button {
                    playback.toggleFullScreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Full screen")
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek($0) }
                    ),
                    in: 0...max(playback.duration, 0.1)
                )
                HStack {
                    Text(MediaPlayback.format(playback.currentTime))
                    Spacer()
                    Text(MediaPlayback.format(playback.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 100)

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(playback.volume) },
                        set: { playback.volume = Float($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 72)
            }

            Button {
                playback.stop()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Stop")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenPreview)
        .onAppear {
            if playback.queue.isEmpty, !folderTracks.isEmpty {
                playback.setQueue(folderTracks)
            }
        }
        .onChange(of: folderTracks) { _, tracks in
            if playback.item == nil {
                playback.setQueue(tracks)
            }
        }
    }

    private var artSize: CGFloat {
        max(44, height - 22)
    }

    private var queueLabel: String {
        if folderTracks.count > 1 {
            return "\(folderTracks.count) tracks in this folder"
        }
        if playback.hasQueue {
            return "\(playback.queueIndex + 1) of \(playback.queue.count)"
        }
        return playback.item?.isVideo == true ? "Video" : "Music"
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = playback.artwork {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: playback.item?.isVideo == true ? "film.fill" : "music.note")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button { playback.playPrevious() } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(playback.queue.isEmpty && playback.item == nil)
            .help("Previous")

            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.borderless)
            .help(playback.isPlaying ? "Pause" : "Play")

            Button { playback.playNext() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!playback.canGoNext && playback.item == nil)
            .help("Next")
        }
    }

    private var extras: some View {
        HStack(spacing: 6) {
            Button {
                playback.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.shuffle ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Shuffle")

            Button {
                playback.autoNext.toggle()
            } label: {
                Image(systemName: "forward.end.alt")
                    .foregroundStyle(playback.autoNext ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Auto-play next")

            Button {
                playback.cycleRepeat()
            } label: {
                Image(systemName: playback.repeatMode.systemImage)
                    .foregroundStyle(playback.repeatMode == .off ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(playback.repeatMode.title)
        }
    }
}

struct MusicPlayerPane: View {
    @ObservedObject var playback: MediaPlayback

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(playback.item?.isVideo == true ? "Now Playing" : "Music")
                    .font(.headline)
                Spacer()
                if playback.hasQueue {
                    Text("\(playback.queueIndex + 1) / \(playback.queue.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            artwork
                .frame(maxWidth: 280, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text(playback.displayTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(playback.displaySubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek($0) }
                    ),
                    in: 0...max(playback.duration, 0.1)
                )
                HStack {
                    Text(MediaPlayback.format(playback.currentTime))
                    Spacer()
                    Text(MediaPlayback.format(playback.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            HStack(spacing: 22) {
                Button { playback.shuffle.toggle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(playback.shuffle ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help("Shuffle")

                Button { playback.playPrevious() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                .buttonStyle(.plain)

                Button { playback.playNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Button { playback.cycleRepeat() } label: {
                    Image(systemName: playback.repeatMode.systemImage)
                        .foregroundStyle(playback.repeatMode == .off ? Color.primary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(playback.repeatMode.title)
            }

            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(playback.volume) },
                        set: { playback.volume = Float($0) }
                    ),
                    in: 0...1
                )
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            Toggle("Auto-play next", isOn: $playback.autoNext)
                .toggleStyle(.switch)
                .padding(.horizontal, 24)

            if playback.hasQueue {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(playback.queue, id: \.path) { url in
                            let index = playback.queue.firstIndex(of: url) ?? 0
                            Button {
                                playback.play(url, queue: playback.queue)
                            } label: {
                                HStack {
                                    Image(systemName: index == playback.queueIndex ? "speaker.wave.2.fill" : "music.note")
                                        .foregroundStyle(index == playback.queueIndex ? Color.accentColor : Color.secondary)
                                        .frame(width: 16)
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .lineLimit(1)
                                        .foregroundStyle(index == playback.queueIndex ? Color.accentColor : Color.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(index == playback.queueIndex ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
        if playback.item?.isVideo == true {
            VideoCanvas(player: playback.player)
                .frame(minHeight: 180)
        } else if let image = playback.artwork {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}

struct VideoPlayerPane: View {
    @ObservedObject var playback: MediaPlayback

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(playback.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    playback.toggleFullScreen()
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            ZStack {
                VideoCanvas(player: playback.player)
                if let note = playback.playbackNote {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text(note)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                    }
                    .padding(16)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek($0) }
                    ),
                    in: 0...max(playback.duration, 0.1)
                )
                HStack {
                    Text(MediaPlayback.format(playback.currentTime))
                    Spacer()
                    Button { playback.playPrevious() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.borderless)
                    Button { playback.toggle() } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.borderless)
                    Button { playback.playNext() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.borderless)
                    Button { playback.toggleFullScreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Full screen")
                    Spacer()
                    Text(MediaPlayback.format(playback.duration))
                }
                .font(.caption.monospacedDigit())
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(playback.volume) },
                            set: { playback.volume = Float($0) }
                        ),
                        in: 0...1
                    )
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }
}

struct VideoCanvas: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var sourceURL: URL?
    @Published var error: String?

    private var player: AVPlayer?
    private var positionObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var controlObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var loadID = UUID()

    /// Loading does not start playback or make a paid generation request.
    /// HTTPS URLs support the preview URLs returned by ElevenLabs.
    func load(_ url: URL) {
        clear()
        guard url.isFileURL || url.scheme?.lowercased() == "https" else {
            error = L("Choose a local audio file or a secure voice preview.")
            return
        }
        if url.isFileURL {
            // Generated WAV files can exceed the API input limit; playback is not an upload.
            guard let audio = try? AVAudioFile(forReading: url), audio.length > 0,
                  audio.processingFormat.sampleRate > 0 else {
                error = L("This audio file is empty, damaged, or unsupported by macOS.")
                return
            }
            duration = Double(audio.length) / audio.processingFormat.sampleRate
        }
        sourceURL = url
        isLoading = true
        let identity = loadID
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.loadID == identity else { return }
                switch status {
                case .readyToPlay: self.isLoading = false
                case .failed:
                    self.isLoading = false
                    self.isPlaying = false
                    self.error = L("Audio playback failed. Check the file or preview connection.")
                case .unknown: break
                @unknown default: break
                }
            }
        }
        durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, self.loadID == identity, seconds.isFinite, seconds > 0 else { return }
                self.duration = seconds
            }
        }
        controlObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.loadID == identity else { return }
                self.isPlaying = status != .paused
            }
        }
        positionObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == identity, time.seconds.isFinite else { return }
                self.currentTime = max(0, time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == identity else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == identity else { return }
                self.isPlaying = false
                self.isLoading = false
                self.error = L("Audio playback failed. Check the file or preview connection.")
            }
        }
    }

    func play() {
        guard let player, error == nil else { return }
        if duration > 0 && currentTime >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }
    func pause() { player?.pause(); isPlaying = false }
    func togglePlayback() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stop() { pause(); seek(to: 0) }
    func clear() {
        loadID = UUID()
        player?.pause()
        if let positionObserver { player?.removeTimeObserver(positionObserver) }
        positionObserver = nil
        statusObserver = nil
        durationObserver = nil
        controlObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        sourceURL = nil
        error = nil
    }
    deinit {
        player?.pause()
        if let positionObserver { player?.removeTimeObserver(positionObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

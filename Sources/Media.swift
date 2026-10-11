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

@MainActor
final class MicrophoneRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let durationLimit: Double = 300
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var recordingURL: URL?
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var activeURL: URL?
    private var requestID = UUID()
    private let permissionRequester: () async -> Bool
    private let recordingDirectory: URL?

    init(recordingDirectory: URL? = nil, permissionRequester: (() async -> Bool)? = nil) {
        self.recordingDirectory = recordingDirectory
        self.permissionRequester = permissionRequester ?? {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            case .denied, .restricted: return false
            @unknown default: return false
            }
        }
        super.init()
    }

    /// Call only after the user presses Record. Initialization never requests permission.
    func start() async {
        guard !isRecording, !isRequestingPermission else { return }
        error = nil
        isRequestingPermission = true
        let identity = UUID()
        requestID = identity
        let allowed = await permissionRequester()
        guard requestID == identity else { return }
        isRequestingPermission = false
        guard !Task.isCancelled else { return }
        guard allowed else {
            error = L("Allow microphone access in System Settings → Privacy & Security → Microphone, then try again.")
            return
        }
        do {
            let directory = try recordingDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Voice Desk/Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImportFailure("The recording folder could not be opened.") }
            let url = directory.appendingPathComponent("Recording-\(UUID().uuidString).wav")
            activeURL = url
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let recording = try AVAudioRecorder(url: url, settings: settings)
            recorder = recording
            recording.delegate = self
            recording.isMeteringEnabled = true
            guard recording.prepareToRecord(), recording.record(forDuration: Self.durationLimit) else {
                throw ImportFailure("Recording could not start. Check the selected microphone in System Settings.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            recordingURL = nil
            elapsed = 0
            level = 0
            isRecording = true
            let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMeter() }
            }
            timer = tick
            RunLoop.main.add(tick, forMode: .common)
        } catch {
            discardActiveRecording()
            self.error = (error as? ImportFailure)?.localizedDescription ?? L("Recording could not start. Check the selected microphone in System Settings.")
        }
    }

    @discardableResult
    func stop() -> URL? {
        // A stop during the permission dialog must not record later when it is accepted.
        requestID = UUID()
        isRequestingPermission = false
        guard let recorder, let url = activeURL else { return recordingURL }
        elapsed = min(Self.durationLimit, recorder.currentTime)
        recorder.stop()
        self.recorder = nil
        activeURL = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        level = 0
        do {
            let info = try ImportService.inspectAudio(url, maximumDuration: Self.durationLimit + 0.1)
            elapsed = min(Self.durationLimit, info.duration)
            recordingURL = url
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            self.error = L("The recording is empty or could not be saved. Try recording again.")
            return nil
        }
    }

    /// Deletes only the unfinished file created by this recorder, never imported audio.
    func cancel() {
        requestID = UUID()
        isRequestingPermission = false
        discardActiveRecording()
        elapsed = 0
    }

    private func updateMeter() {
        guard isRecording, let recorder else { return }
        elapsed = min(Self.durationLimit, recorder.currentTime)
        recorder.updateMeters()
        level = max(0, min(1, pow(10, Double(recorder.averagePower(forChannel: 0)) / 20)))
        if let activeURL, let attributes = try? FileManager.default.attributesOfItem(atPath: activeURL.path),
           let count = attributes[.size] as? NSNumber, count.intValue > ImportService.audioByteLimit {
            _ = stop()
            error = L("Recording stopped at the 100 MB file limit.")
        }
    }

    private func discardActiveRecording() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        level = 0
        if let activeURL { try? FileManager.default.removeItem(at: activeURL) }
        activeURL = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            if flag { _ = self.stop() }
            else {
                self.discardActiveRecording()
                self.error = L("The recording is empty or could not be saved. Try recording again.")
            }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.discardActiveRecording()
            self.error = L("The recording is empty or could not be saved. Try recording again.")
        }
    }
    deinit { timer?.invalidate(); recorder?.stop() }
}

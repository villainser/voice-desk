import AVFoundation
import Combine
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

enum AudioInputs {
    static func devices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return discovery.devices.filter { $0.isConnected && $0.hasMediaType(.audio) }
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

protocol MicrophoneCaptureBackend: AnyObject {
    func start(deviceID: String, url: URL, durationLimit: Double,
               started: @escaping () -> Void,
               progress: @escaping (Double, Double) -> Void,
               finished: @escaping (Error?) -> Void)
    func stop()
}

/// A session owns its selected input; it never changes the system's default input.
/// Session work and file finalization are serialized off the main thread.
final class FileMicrophoneCapture: NSObject, MicrophoneCaptureBackend, AVCaptureFileOutputRecordingDelegate {
    private let queue = DispatchQueue(label: "VoiceDesk.microphone")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var timer: DispatchSourceTimer?
    private var started: (() -> Void)?
    private var finished: ((Error?) -> Void)?
    private var runtimeObserver: NSObjectProtocol?
    private var recordingRequested = false

    func start(deviceID: String, url: URL, durationLimit: Double,
               started: @escaping () -> Void,
               progress: @escaping (Double, Double) -> Void,
               finished: @escaping (Error?) -> Void) {
        queue.async { [self] in
            self.started = started; self.finished = finished
            do {
                let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: deviceID)
                guard let device, device.isConnected, device.hasMediaType(.audio) else {
                    throw ImportFailure("The selected microphone is unavailable. Connect it or choose another input.")
                }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioFileOutput()
                guard session.canAddInput(input), session.canAddOutput(output),
                      AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.wav) else {
                    throw ImportFailure("This microphone cannot record WAV audio. Choose another input.")
                }
                session.beginConfiguration()
                session.addInput(input); session.addOutput(output)
                output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                output.maxRecordedDuration = CMTime(seconds: durationLimit, preferredTimescale: 600)
                output.maxRecordedFileSize = Int64(ImportService.audioByteLimit)
                session.commitConfiguration()
                self.session = session; self.output = output
                runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        if self.recordingRequested { self.output?.stopRecording() }
                        else { self.complete(error ?? ImportFailure("The microphone stopped responding. Choose an input and try again.")) }
                    }
                }
                session.startRunning()
                guard session.isRunning else { throw ImportFailure("Recording could not start. Choose another microphone and try again.") }
                recordingRequested = true
                output.startRecording(to: url, outputFileType: .wav, recordingDelegate: self)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 0.1)
                timer.setEventHandler { [weak self] in
                    guard let output = self?.output else { return }
                    let seconds = output.recordedDuration.seconds
                    let power = output.connection(with: .audio)?.audioChannels.map(\.averagePowerLevel).max() ?? -160
                    progress(seconds.isFinite ? max(0, seconds) : 0, max(0, min(1, pow(10, Double(power) / 20))))
                }
                self.timer = timer; timer.resume()
            } catch { complete(error) }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, let output = self.output else { return }
            // didFinishRecording is the only point where a file is ready to use.
            output.stopRecording()
        }
    }

    private func complete(_ error: Error?) {
        guard let completion = finished else { return }
        finished = nil; started = nil; recordingRequested = false
        timer?.cancel(); timer = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        session?.stopRunning(); session = nil; output = nil
        completion(error)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { [weak self] in self?.started?(); self?.started = nil }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [weak self] in
            let successfulLimit = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            self?.complete(successfulLimit ? nil : error)
        }
    }
}

@MainActor
final class MicrophoneRecorder: ObservableObject {
    static let durationLimit: Double = 300
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isFinishing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var recordingURL: URL?
    @Published var error: String?
    var onFinished: ((URL) -> Void)?
    var isBusy: Bool { isRecording || isRequestingPermission || isFinishing }
    var selectedInputAvailable: Bool { !devices.isEmpty && (selectedDeviceID.isEmpty || devices.contains { $0.id == selectedDeviceID }) }

    private var backend: MicrophoneCaptureBackend?
    private var activeURL: URL?
    private var requestID = UUID()
    private var discardOnFinish = false
    private let permissionRequester: () async -> Bool
    private let deviceProvider: () -> [AudioInputDevice]
    private let backendFactory: () -> MicrophoneCaptureBackend
    private let recordingDirectory: URL?
    private var deviceObservers: [NSObjectProtocol] = []

    init(recordingDirectory: URL? = nil, permissionRequester: (() async -> Bool)? = nil,
         deviceProvider: @escaping () -> [AudioInputDevice] = AudioInputs.devices,
         backendFactory: @escaping () -> MicrophoneCaptureBackend = { FileMicrophoneCapture() }) {
        self.recordingDirectory = recordingDirectory
        self.deviceProvider = deviceProvider; self.backendFactory = backendFactory
        self.permissionRequester = permissionRequester ?? {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            case .denied, .restricted: return false
            @unknown default: return false
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDevices() }
            })
        }
    }

    func refreshDevices() {
        devices = deviceProvider()
        // A disconnected explicit selection stays selected; never silently switch mics.
        if isRecording && !selectedInputAvailable {
            error = L("The selected microphone was disconnected. The recorded part will be kept.")
            stop()
        }
    }

    /// Permission and capture begin only after an explicit Record action.
    func start() async {
        guard !isBusy else { return }
        error = nil; refreshDevices()
        guard selectedInputAvailable else {
            error = L("The selected microphone is unavailable. Connect it or choose another input."); return
        }
        let selectedID = selectedDeviceID
        isRequestingPermission = true
        let identity = UUID(); requestID = identity
        let allowed = await permissionRequester()
        guard requestID == identity else { return }
        guard !Task.isCancelled, allowed else {
            isRequestingPermission = false
            if !allowed { error = L("Allow microphone access in System Settings → Privacy & Security → Microphone, then try again.") }
            return
        }
        do {
            let directory = try recordingDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Voice Desk/Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImportFailure("The recording folder could not be opened.") }
            let url = directory.appendingPathComponent("Recording-\(UUID().uuidString).wav")
            activeURL = url; recordingURL = nil; elapsed = 0; level = 0; discardOnFinish = false
            let backend = backendFactory(); self.backend = backend
            backend.start(deviceID: selectedID, url: url, durationLimit: Self.durationLimit, started: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == identity, !self.isFinishing else { return }
                    self.isRequestingPermission = false; self.isRecording = true
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }, progress: { [weak self] elapsed, level in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == identity, self.isRecording else { return }
                    self.elapsed = min(Self.durationLimit, elapsed); self.level = level
                }
            }, finished: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == identity else { return }
                    self.complete(url, error: error)
                }
            })
        } catch {
            isRequestingPermission = false; activeURL = nil; backend = nil
            self.error = error.localizedDescription
        }
    }

    func stop() {
        if backend == nil { requestID = UUID(); isRequestingPermission = false; return }
        guard !isFinishing else { return }
        isFinishing = true; isRecording = false; isRequestingPermission = false; level = 0
        backend?.stop()
    }
    /// Discards only this unfinished capture, never imported or completed samples.
    func cancel() {
        discardOnFinish = true
        stop()
    }
    private func complete(_ url: URL, error captureError: Error?) {
        backend = nil; activeURL = nil
        isRecording = false; isRequestingPermission = false; isFinishing = false; level = 0
        defer { requestID = UUID() }
        if discardOnFinish { try? FileManager.default.removeItem(at: url); elapsed = 0; return }
        do {
            let info = try ImportService.inspectAudio(url, maximumDuration: Self.durationLimit + 0.2)
            elapsed = min(Self.durationLimit, info.duration); recordingURL = url
            if captureError != nil { self.error = L("Recording stopped unexpectedly. The recorded part has been saved.") }
            onFinished?(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            self.error = (captureError as? ImportFailure)?.localizedDescription ?? L("The recording is empty or could not be saved. Check the microphone and try again.")
        }
    }
    deinit {
        for observer in deviceObservers { NotificationCenter.default.removeObserver(observer) }
        backend?.stop()
    }
}

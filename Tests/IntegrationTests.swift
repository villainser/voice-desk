import Foundation
import AVFoundation

private struct IntegrationFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw IntegrationFailure(message: message) }
}
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

// Network is prohibited in this suite, including requests accidentally introduced later.
private final class IntegrationNetworkGuard: URLProtocol {
    private static let lock = NSLock()
    private static var requestCount = 0
    static var calls: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requestCount += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private func wave() -> Data {
    var data = Data()
    func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    let size: UInt32 = 3200
    data.append(Data("RIFF".utf8)); word(UInt32(36) + size); data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
    word(UInt16(1)); word(UInt16(1)); word(UInt32(16000)); word(UInt32(32000)); word(UInt16(2)); word(UInt16(16))
    data.append(Data("data".utf8)); word(size); data.append(Data(repeating: 0, count: Int(size)))
    return data
}

@MainActor
private func finished(_ model: AppModel) async throws {
    let deadline = Date().addingTimeInterval(5)
    while model.busy {
        guard Date() < deadline else { throw IntegrationFailure(message: "Local AppModel operation timed out") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
private final class LocalGate {
    var wait: CheckedContinuation<Void, Never>?
    func suspend() async { await withCheckedContinuation { wait = $0 } }
    func release() { wait?.resume(); wait = nil }
}

private final class CloneCaptureStub: MicrophoneCaptureBackend {
    var url: URL?
    var completion: ((Error?) -> Void)?
    func start(deviceID: String, url: URL, durationLimit: Double, started: @escaping () -> Void,
               progress: @escaping (Double, Double) -> Void, finished: @escaping (Error?) -> Void) {
        self.url = url; self.completion = finished; started()
    }
    func stop() {}
    func finish() throws { try wave().write(to: url!); completion?(nil) }
}

@MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() {
        guard Date() < deadline else { throw IntegrationFailure(message: "Recording state timed out") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@main
struct IntegrationTests {
    @MainActor static func main() async throws {
        // AppModel checks this argument before reading any Keychain or saved-library data.
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-mode") else {
            throw IntegrationFailure(message: "Run IntegrationTests with --ui-test-mode; normal initialization may access Keychain.")
        }
        URLProtocol.registerClass(IntegrationNetworkGuard.self)
        defer { URLProtocol.unregisterClass(IntegrationNetworkGuard.self) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationNetworkGuard.self]
        let client = ElevenClient(key: "integration-test-only", session: URLSession(configuration: configuration))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceDeskIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let one = try folder("One"), two = try folder("Two"), shared = try folder("Shared")
        let first = one.appendingPathComponent("Scene.txt"), second = two.appendingPathComponent("Scene.txt")
        try "First scene — 日本語".write(to: first, atomically: true, encoding: .utf8)
        try "Second scene — polski".write(to: second, atomically: true, encoding: .utf8)
        var passed = 0
        func ok(_ message: String) { passed += 1; print("PASS \(passed): \(message)") }

        let model = AppModel()
        try expect(!model.hasKey && model.keyDraft.isEmpty && model.voices.isEmpty && model.models.isEmpty && model.localRecordings.isEmpty,
                   "UI-test initialization must skip saved credential and content loading")
        model.validateConnection()
        try expect(model.page == .settings && model.error != nil && !model.busy && !model.canGenerate,
                   "Missing key must route to Settings before starting work")
        try expect(!model.recorder.isRecording && !model.recorder.isRequestingPermission, "Constructing AppModel must not request microphone access")
        ok("credential-free initialization and missing-key navigation")

        let voiceModel = AppModel()
        var mine = Voice(voice_id: "mine", name: "Personal clone"); mine.isSaved = true; mine.category = "cloned"; mine.is_owner = true
        var added = Voice(voice_id: "added", name: "Saved narrator"); added.isSaved = true; added.category = "professional"; added.is_owner = false
        var external = Voice(voice_id: "default", name: "ElevenLabs default"); external.isSaved = false; external.category = "premade"
        voiceModel.applyVoiceCatalog([mine, added, external])
        try expect(voiceModel.visibleVoices.map(\.id) == ["mine", "added"] && voiceModel.pickerVoices.map(\.id) == ["mine", "added"], "My Voices and default picker must exclude unsaved defaults")
        voiceModel.voiceSearch = "narrator"
        try expect(voiceModel.visibleVoices.map(\.id) == ["added"], "text search stays within saved voices")
        voiceModel.voiceSearch = ""; voiceModel.voiceCategory = "professional"
        try expect(voiceModel.visibleVoices.map(\.id) == ["added"] && !voiceModel.voiceCategories.contains("premade"), "category filtering stays within saved voices")
        for page in [WorkspacePage.speech, .changer, .batch] {
            voiceModel.page = page
            voiceModel.setVoiceSource(.elevenLabs)
            try expect(voiceModel.pickerVoices.map(\.id) == ["default"] && voiceModel.voiceID == "default", "external source replaces the hidden selection in every generation workspace")
            voiceModel.setVoiceSource(.saved)
            try expect(voiceModel.voiceID == "mine", "switching back restores a valid saved selection")
        }
        voiceModel.setVoiceSource(.all)
        try expect(voiceModel.pickerVoices.count == 3, "explicit all-voices option")
        voiceModel.chooseVoice(external)
        try expect(voiceModel.voiceSource == .elevenLabs, "selecting from a library aligns the source")
        voiceModel.applyVoiceCatalog([mine, added, external])
        try expect(voiceModel.voiceID == "default", "refresh preserves the selected voice")
        voiceModel.applyVoiceCatalog([external]); voiceModel.setVoiceSource(.saved)
        try expect(voiceModel.voiceID.isEmpty && voiceModel.pickerVoices.isEmpty, "empty saved filter must not keep a hidden external selection")
        ok("voice source selection across TTS, Voice Changer, batch, search, and empty lists")

        let capture = CloneCaptureStub()
        let recorder = MicrophoneRecorder(recordingDirectory: root.appendingPathComponent("Recorded"), permissionRequester: { true },
            deviceProvider: { [AudioInputDevice(id: "usb", name: "USB input")] }, backendFactory: { capture })
        let cloneModel = AppModel(recorder: recorder)
        cloneModel.hasKey = true; cloneModel.voiceID = "test_voice"; cloneModel.sourceAudio = first
        cloneModel.recordCloneSample()
        try await waitUntil { recorder.isRecording }
        try expect(!cloneModel.canGenerate, "generation must be unavailable during recording")
        cloneModel.cloneConsent = true; cloneModel.cloneSamples = [first]
        cloneModel.cloneVoice()
        try expect(!cloneModel.busy, "Create Voice Clone must not send an unfinished recording")
        cloneModel.page = .speech // Completion follows the recording target, not the current page.
        cloneModel.stopRecording()
        try expect(cloneModel.cloneSamples == [first] && recorder.isFinishing, "sample list must wait for finalization")
        try capture.finish(); try await waitUntil { !recorder.isBusy }
        let sample = capture.url!
        try expect(cloneModel.cloneSamples == [first, sample] && cloneModel.sourceAudio == first, "recorded clone sample appends without replacing Voice Changer source")
        cloneModel.removeCloneSample(sample)
        try expect(cloneModel.cloneSamples == [first] && FileManager.default.fileExists(atPath: sample.path), "removing a sample is list-only and must preserve the local file")
        cloneModel.record(); try await waitUntil { recorder.isRecording }
        cloneModel.stopRecording(); try capture.finish(); try await waitUntil { !recorder.isBusy }
        try expect(cloneModel.sourceAudio == capture.url && cloneModel.cloneSamples == [first], "Voice Changer recording must not enter the cloning sample list")
        ok("microphone cloning samples, finalization, generation gating, and separate Voice Changer routing")

        model.page = .batch
        model.importJobs([first, second])
        try await finished(model)
        try expect(model.error == nil && model.jobs.count == 2 && model.readyJobs.count == 2,
                   "Same basenames in different input folders must remain valid with per-source outputs")
        try expect(model.jobs.allSatisfy { $0.fingerprint.count == 64 && $0.characters > 0 && $0.parts == 1 }, "Imported jobs must have validated source fingerprints")
        try expect(model.result == nil && model.localRecordings.isEmpty && !FileManager.default.fileExists(atPath: first.deletingPathExtension().appendingPathExtension("mp3").path),
                   "Import must not generate or register audio")
        model.importJobs([first]); try await finished(model)
        try expect(model.jobs.count == 2, "Repeated import must deduplicate input URLs")
        ok("batch import preserves contents, deduplicates, and does not generate")

        model.batchDestination = shared; model.refreshJobOutputs()
        try expect(model.jobs.filter { $0.state == .invalid }.count == 1 && model.readyJobs.count == 1,
                   "Colliding output names under a shared destination must be blocked")
        model.batchDestination = nil; model.refreshJobOutputs()
        try expect(model.readyJobs.count == 2 && model.jobs.allSatisfy { $0.state == .ready },
                   "Changing destination must recover rows invalid only because of previous output collisions")
        ok("shared-destination collision and reset to per-source output folders")

        let caption = one.appendingPathComponent("Scene.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nCaption words.".write(to: caption, atomically: true, encoding: .utf8)
        model.importJobs([caption]); try await finished(model)
        try expect(model.jobs.count == 3 && model.jobs.filter { $0.state == .invalid }.count == 1,
                   "TXT and SRT with the same basename in one folder must collide")
        model.jobs.removeAll { $0.url == first }; model.refreshJobOutputs()
        try expect(model.jobs.count == 2 && model.readyJobs.count == 2,
                   "Removing a conflicting row must recover the remaining valid source")
        ok("same-folder cross-extension collision and recovery after row removal")

        let empty = one.appendingPathComponent("Empty.txt")
        try "   \n".write(to: empty, atomically: true, encoding: .utf8)
        model.importJobs([empty]); try await finished(model)
        try expect(model.jobs.first { $0.url == empty }?.state == .invalid, "An unreadable source must be invalid")
        model.batchDestination = shared; model.refreshJobOutputs()
        model.batchDestination = nil; model.refreshJobOutputs()
        try expect(model.jobs.first { $0.url == empty }?.state == .invalid,
                   "Destination refresh must not turn an empty source into a runnable job")
        let validTwin = one.appendingPathComponent("Broken.txt"), invalidTwin = two.appendingPathComponent("Broken.txt")
        try "Readable source".write(to: validTwin, atomically: true, encoding: .utf8)
        try "".write(to: invalidTwin, atomically: true, encoding: .utf8)
        model.importJobs([validTwin, invalidTwin]); try await finished(model)
        model.batchDestination = shared; model.refreshJobOutputs()
        model.batchDestination = nil; model.refreshJobOutputs()
        try expect(model.jobs.first { $0.url == invalidTwin }?.state == .invalid,
                   "A collision must not erase a pre-existing source-validation failure")
        ok("source-validation errors survive destination changes")

        let languageBefore = UserDefaults.standard.object(forKey: Localizer.preferenceKey)
        defer {
            if let languageBefore { UserDefaults.standard.set(languageBefore, forKey: Localizer.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: Localizer.preferenceKey) }
        }
        model.text = "Dzień dobry! Welcome. こんにちは。"
        model.speechLanguage = "ja"; model.voiceID = "selected_voice"
        let preservedText = model.text
        model.interfaceLanguage = "pl"
        try expect(model.speechLanguage == "ja" && model.voiceID == "selected_voice" && model.text == preservedText,
                   "Polish UI must not alter content or generation language")
        model.interfaceLanguage = "en"
        try expect(model.speechLanguage == "ja" && model.voiceID == "selected_voice" && model.text == preservedText,
                   "English UI must not alter content or generation language")
        ok("interface language remains independent from speech language and source text")

        model.models = try decode([APIModel].self, """
        [
          {"model_id":"eleven_flash_v2_5","can_do_text_to_speech":true,"can_use_style":false,"can_use_speaker_boost":false,"maximum_text_length_per_request":1000,"languages":[{"language_id":"ja","name":"Japanese"}]},
          {"model_id":"eleven_multilingual_v2","can_do_text_to_speech":true,"can_use_style":true,"can_use_speaker_boost":true,"maximum_text_length_per_request":10000,"languages":[{"language_id":"pl","name":"Polish"}]},
          {"model_id":"eleven_multilingual_sts_v2","can_do_voice_conversion":true,"can_use_style":false,"can_use_speaker_boost":true}
        ]
        """)
        model.expression.enabled = true; model.expression.style = 0.8; model.expression.speakerBoost = true
        model.page = .speech; model.modelID = "eleven_flash_v2_5"
        try expect(model.generationSettings.voiceParameters?["style"] == nil && model.generationSettings.voiceParameters?["use_speaker_boost"] == nil,
                   "Discovered false style/boost capabilities must filter unsupported parameters")
        try expect(model.generationSettings.chunkLimit == 1000 && model.supportsExplicitLanguage,
                   "TTS request length and explicit-language capability must follow the selected model")
        model.modelID = "eleven_multilingual_v2"; model.modelChanged()
        try expect(model.speechLanguage.isEmpty && !model.supportsExplicitLanguage && model.generationSettings.chunkLimit == 4000,
                   "Model switch must reset unsupported language and cap chunks safely")
        try expect(model.generationSettings.voiceParameters?["style"] as? Double == 0.8 && model.generationSettings.voiceParameters?["use_speaker_boost"] as? Bool == true,
                   "Available style/boost must remain enabled")
        model.page = .changer
        try expect(model.generationSettings.modelID == "eleven_multilingual_sts_v2" && model.generationSettings.voiceParameters?["style"] == nil && model.generationSettings.voiceParameters?["use_speaker_boost"] as? Bool == true,
                   "Voice Changer must use conversion-model capabilities, not TTS capabilities")
        model.models = []; model.page = .speech
        try expect(model.generationSettings.voiceParameters?["style"] == nil && model.generationSettings.voiceParameters?["use_speaker_boost"] == nil,
                   "Missing capability metadata must not imply supported flags")
        ok("model-specific settings, language controls, and safe chunk limits")

        let source = one.appendingPathComponent("Original.wav")
        let original = wave(); try original.write(to: source)
        var audioItem = FileItem(url: source, parts: 1, fingerprint: AudioSources.digest(original), isAudio: true, destinationFolder: one)
        try expect(audioItem.existingAudio(except: .mp3) == nil,
                   "The source audio in the destination directory must never be treated as a previous converted result")
        audioItem.inspectOutput(.wav)
        try expect(audioItem.state == .invalid, "An output path identical to its source must be rejected rather than shown as generated")
        do {
            _ = try await BatchProcessor.process(audioItem, settings: GenerationSettings(voiceID: "test_voice", modelID: "eleven_multilingual_sts_v2", format: .wav), client: client) { _, _, _ in }
            throw IntegrationFailure(message: "Processing must reject a destination identical to its source")
        } catch is AppFailure { }
        try expect(try Data(contentsOf: source) == original && IntegrationNetworkGuard.calls == 0,
                   "Same-path rejection must preserve source bytes and avoid all API calls")
        model.batchAudio = true; model.jobs = []; model.batchDestination = one; model.format = .wav
        model.importJobs([source]); try await finished(model)
        try expect(model.jobs.count == 1 && model.jobs[0].state == .invalid && model.readyJobs.isEmpty,
                   "Batch imports must surface a source/output path conflict before Start")
        model.format = .mp3; model.refreshJobOutputs()
        try expect(model.jobs[0].state == .ready && model.jobs[0].existingAudio(except: .mp3) == nil,
                   "Changing format should resolve the path conflict without reusing original speech as changed speech")
        ok("Voice Changer source/output collision safety and format recovery")

        let gate = LocalGate()
        var operationStarts = 0
        model.run("Local test operation") { operationStarts += 1; await gate.suspend() }
        while gate.wait == nil { await Task.yield() }
        model.run("Duplicate local operation") { operationStarts += 1 }
        try expect(operationStarts == 1 && model.busy, "Busy operations must reject duplicate submission")
        model.cancel(); gate.release(); try await finished(model)
        try expect(!model.busy && model.progress == nil && model.status == "Cancelled · completed downloads are kept",
                   "Cancellation must restore usable operation state")
        try expect(IntegrationNetworkGuard.calls == 0, "The suite must never request network access")
        ok("duplicate-operation prevention and cancellation cleanup")
        print("All \(passed) AppModel integration groups passed with --ui-test-mode. No Keychain calls, paid API calls, or microphone access were invoked.")
    }
}

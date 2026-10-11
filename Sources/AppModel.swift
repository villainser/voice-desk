import SwiftUI
import AppKit
import UniformTypeIdentifiers

// User-facing navigation is independent from the API model and speech language.
enum WorkspacePage: String, CaseIterable, Identifiable {
    case speech, changer, effects, myVoices, discover, createVoice, transcription, isolation, dubbing, library, batch, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speech: return L("Text to Speech")
        case .changer: return L("Voice Changer")
        case .effects: return L("Sound Effects")
        case .myVoices: return L("My Voices")
        case .discover: return L("ElevenLabs Voices")
        case .createVoice: return L("Create a Voice")
        case .transcription: return L("Speech to Text")
        case .isolation: return L("Audio Isolation")
        case .dubbing: return L("Dubbing")
        case .library: return L("Audio Library")
        case .batch: return L("Batch Jobs")
        case .settings: return L("Settings")
        }
    }
    var icon: String {
        switch self {
        case .speech: return "text.bubble"
        case .changer: return "person.wave.2"
        case .effects: return "waveform.path"
        case .myVoices: return "person.crop.rectangle.stack"
        case .discover: return "globe"
        case .createVoice: return "person.badge.plus"
        case .transcription: return "text.quote"
        case .isolation: return "waveform.badge.mic"
        case .dubbing: return "captions.bubble"
        case .library: return "music.note.list"
        case .batch: return "square.stack.3d.up"
        case .settings: return "gearshape"
        }
    }
}

struct LocalRecording: Identifiable, Codable {
    var id = UUID()
    var title: String
    var path: String
    var created = Date()
    var kind: String
    var voiceName: String?
    var url: URL { URL(fileURLWithPath: path) }
}

enum AppStorageFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voice Desk", isDirectory: true)
    }
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try BatchProcessor.directory(url)
        return url
    }
    static func resultURL(extension ext: String) throws -> URL {
        try directory("Audio").appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page: WorkspacePage = .speech
    @Published var interfaceLanguage = Localizer.language {
        didSet { UserDefaults.standard.set(interfaceLanguage, forKey: Localizer.preferenceKey) }
    }
    @Published var keyDraft = ""
    @Published var hasKey = false
    @Published var connection = "Not connected"
    @Published var account: AccountSubscription?
    @Published var accountDate: Date?
    @Published var voices: [Voice] = []
    @Published var models: [APIModel] = []
    @Published var voiceID = ""
    @Published var modelID = "eleven_multilingual_v2"
    @Published var conversionModelID = "eleven_multilingual_sts_v2"
    @Published var speechLanguage = ""
    @Published var format: OutputFormat = .mp3
    @Published var expression = ExpressionSettings()
    @Published var advanced = false
    @Published var text = ""
    @Published var recordingTitle = ""
    @Published var sourceAudio: URL?
    @Published var removeNoise = false
    @Published var busy = false
    @Published var status = "Ready"
    @Published var progress: Double?
    @Published var error: String?
    @Published var notice: String?
    @Published var dropTargeted = false
    @Published var result: LocalRecording?
    @Published var localRecordings: [LocalRecording] = []
    @Published var historyItems: [HistoryItem] = []
    @Published var historyMore = false
    private var historyCursor: String?
    @Published var voiceSearch = ""
    @Published var voiceCategory = ""
    @Published var sharedSearch = ""
    @Published var sharedLanguage = ""
    @Published var sharedVoices: [SharedVoice] = []
    @Published var sharedMore = false
    private var sharedPage = 0
    @Published var voiceName = ""
    @Published var voiceDescription = ""
    @Published var voiceCreationMode = "design"
    @Published var cloneSamples: [URL] = []
    @Published var cloneConsent = false
    @Published var designPreviews: [VoiceDesignPreview] = []
    @Published var designText = ""
    @Published var selectedDesign = ""
    @Published var effectsPrompt = ""
    @Published var effectAutomaticDuration = true
    @Published var effectDuration = 5.0
    @Published var effectInfluence = 0.3
    @Published var effectLoop = false
    @Published var transcript = ""
    @Published var diarize = false
    @Published var transcriptLanguage = ""
    @Published var dubbingTargetLanguage = "en"
    @Published var dubbingSourceLanguage = ""
    @Published var dubbingProjectID = ""
    @Published var dubbingProject: DubbingProject?
    @Published var dubbingTarget: DubbingTarget?
    @Published var jobs: [FileItem] = []
    @Published var batchAudio = false
    @Published var batchDestination: URL?
    @Published var batchFolder: URL?
    @Published var editingVoice: Voice?
    @Published var editName = ""
    @Published var editDescription = ""
    let player = AudioPlayerModel()
    let recorder = MicrophoneRecorder()
    private var apiKey = ""
    private var task: Task<Void, Never>?
    private let previewMode = ProcessInfo.processInfo.arguments.contains("--ui-test-mode")

    var client: ElevenClient { ElevenClient(key: apiKey) }
    var selectedVoice: Voice? { voices.first { $0.id == voiceID } }
    var selectedModel: APIModel? { models.first { $0.id == modelID } }
    var ttsModels: [APIModel] { models.filter { $0.can_do_text_to_speech == true } }
    var conversionModels: [APIModel] { models.filter { $0.can_do_voice_conversion == true } }
    var availableLanguages: [APILanguage] { selectedModel?.languages ?? [] }
    var supportsExplicitLanguage: Bool { selectedModel?.supportsExplicitLanguage == true }
    var visibleVoices: [Voice] {
        voices.filter { (voiceSearch.isEmpty || ($0.name + " " + ($0.description ?? "") + " " + $0.languageSummary).localizedCaseInsensitiveContains(voiceSearch)) && (voiceCategory.isEmpty || $0.category == voiceCategory) }
    }
    var voiceCategories: [String] { Set(voices.compactMap(\.category)).sorted() }
    var readyJobs: [FileItem] { jobs.filter { $0.state == .ready || $0.state == .failed } }
    var canGenerate: Bool { hasKey && !voiceID.isEmpty && !busy }
    var isConversion: Bool { page == .changer || (page == .batch && batchAudio) }
    var expressionModel: String { isConversion ? conversionModelID : modelID }
    var expressionCapabilities: APIModel? { models.first { $0.id == expressionModel } }
    var expressiveModel: Bool { expressionModel == "eleven_v3" || expressionModel.hasPrefix("eleven_v4") }
    var generationSettings: GenerationSettings {
        GenerationSettings(voiceID: voiceID, modelID: expressionModel, format: format,
            expression: expression, removeNoise: removeNoise,
            languageCode: isConversion || speechLanguage.isEmpty ? nil : speechLanguage,
            supportedExplicitLanguage: !isConversion && supportsExplicitLanguage,
            chunkLimit: isConversion ? 4000 : max(1, min(4000, selectedModel?.maximum_text_length_per_request ?? 4000)),
            supportsStyle: expressionCapabilities?.can_use_style == true,
            supportsSpeakerBoost: expressionCapabilities?.can_use_speaker_boost == true)
    }

    init() {
        guard !previewMode else { return }
        let defaults = UserDefaults.standard
        voiceID = defaults.string(forKey: "voiceID") ?? ""
        modelID = defaults.string(forKey: "modelID") ?? "eleven_multilingual_v2"
        conversionModelID = defaults.string(forKey: "conversionModelID") ?? "eleven_multilingual_sts_v2"
        speechLanguage = defaults.string(forKey: "speechLanguage") ?? ""
        format = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "mp3") ?? .mp3
        if let data = defaults.data(forKey: "expression"), let saved = try? JSONDecoder().decode(ExpressionSettings.self, from: data) { expression = saved }
        if let data = defaults.data(forKey: "voices"), let saved = try? JSONDecoder().decode([Voice].self, from: data) { voices = saved }
        if let data = defaults.data(forKey: "models"), let saved = try? JSONDecoder().decode([APIModel].self, from: data) { models = saved }
        if let folder = defaults.string(forKey: "folder") { batchFolder = URL(fileURLWithPath: folder) }
        dubbingProjectID = defaults.string(forKey: "dubbingProjectID") ?? ""
        let index = AppStorageFiles.root.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([LocalRecording].self, from: data) { localRecordings = saved }
        Task { [weak self] in
            let key = await Task.detached { KeyStore.read() }.value ?? ""
            self?.apiKey = key; self?.keyDraft = key; self?.hasKey = !key.isEmpty
            self?.connection = key.isEmpty ? "Not connected" : "Key loaded · connection not yet checked"
        }
    }
    func persistPreferences() {
        guard !previewMode else { return }
        let defaults = UserDefaults.standard
        defaults.set(voiceID, forKey: "voiceID"); defaults.set(modelID, forKey: "modelID")
        defaults.set(conversionModelID, forKey: "conversionModelID")
        defaults.set(speechLanguage, forKey: "speechLanguage"); defaults.set(format.rawValue, forKey: "format")
        defaults.set(try? JSONEncoder().encode(expression), forKey: "expression")
        defaults.set(try? JSONEncoder().encode(voices), forKey: "voices")
        defaults.set(try? JSONEncoder().encode(models), forKey: "models")
        defaults.set(batchFolder?.path, forKey: "folder")
        defaults.set(dubbingProjectID, forKey: "dubbingProjectID")
    }
    func saveKey() {
        let replacement = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { error = L("Enter an API key first."); return }
        run("Saving API key") { [self] in
            try await Task.detached { try KeyStore.save(replacement) }.value
            apiKey = replacement; hasKey = true; account = nil; accountDate = nil
            connection = "Key saved · validate the connection"
        }
    }
    func removeKey() {
        guard confirm(title: L("Remove the saved API key?"), message: L("This removes the key from Voice Desk and Keychain. It does not revoke the key on ElevenLabs."), action: L("Remove Key")) else { return }
        run("Removing API key") { [self] in
            try await Task.detached { try KeyStore.delete() }.value
            apiKey = ""; keyDraft = ""; hasKey = false
            account = nil; accountDate = nil; connection = "Not connected"
            voices = []; sharedVoices = []; models = []; historyItems = []
            persistPreferences()
        }
    }
    func validateConnection() {
        guard requireKey() else { return }
        run("Checking connection") { [self] in
            // Endpoints have separate scopes. Preserve useful data when one scope is absent.
            var successes = 0, failures: [String] = []
            do { models = try await client.models(); successes += 1 } catch { failures.append(error.localizedDescription) }
            do { voices = try await client.voices(); successes += 1 } catch { failures.append(error.localizedDescription) }
            do { account = try await client.subscription(); accountDate = Date(); successes += 1 } catch { account = nil; accountDate = nil; failures.append(error.localizedDescription) }
            connection = successes > 0 ? "Connected" : "Connection failed"
            if !ttsModels.contains(where: { $0.id == modelID }), let first = ttsModels.first { modelID = first.id }
            if !conversionModels.contains(where: { $0.id == conversionModelID }), let first = conversionModels.first { conversionModelID = first.id }
            if !voices.contains(where: { $0.id == voiceID }), let first = voices.first { voiceID = first.id }
            if !availableLanguages.contains(where: { $0.id == speechLanguage }) { speechLanguage = "" }
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            persistPreferences()
        }
    }
    @discardableResult func requireKey() -> Bool {
        guard hasKey else { page = .settings; error = L("Add your ElevenLabs API key in Settings."); return false }
        return true
    }
    func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil; status = title; progress = nil
        task = Task { [weak self] in
            do {
                try await operation()
                try Task.checkCancellation()
                self?.status = "Done"
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self?.status = "Cancelled · completed downloads are kept"
                } else { self?.error = self?.safeError(error); self?.status = "Operation failed" }
            }
            self?.busy = false; self?.progress = nil; self?.task = nil
        }
    }
    func safeError(_ error: Error) -> String {
        let text = error.localizedDescription
        return apiKey.isEmpty ? text : text.replacingOccurrences(of: apiKey, with: "[redacted]")
    }
    func cancel() { task?.cancel(); status = "Cancelling" }
    func modelChanged() {
        if !availableLanguages.contains(where: { $0.id == speechLanguage }) { speechLanguage = "" }
        if modelID == "eleven_v3" { expression.stability = (expression.stability * 2).rounded() / 2 }
        persistPreferences()
    }
    func chooseVoice(_ voice: Voice) { voiceID = voice.id; persistPreferences(); notice = L("Selected voice: %@", voice.name) }
    func selectFiles(audio: Bool, multiple: Bool = false, folders: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        if !folders { panel.allowedContentTypes = audio ? [.audio] : [.plainText, UTType(filenameExtension: "srt") ?? .data, UTType(filenameExtension: "vtt") ?? .data] }
        return panel.runModal() == .OK ? panel.urls : []
    }
    func prepareTextBatch() -> Bool {
        if batchAudio && !jobs.isEmpty {
            error = L("Clear the audio queue before importing a text batch."); return false
        }
        batchAudio = false
        return true
    }
    func importText() {
        let urls = selectFiles(audio: false, multiple: true)
        guard !urls.isEmpty else { return }
        if urls.count > 1 {
            page = .batch
            guard prepareTextBatch() else { return }
            importJobs(urls); return
        }
        run("Importing text") { [self] in
            text = try await Task.detached { try ImportService.readText(urls[0]) }.value
            recordingTitle = urls[0].deletingPathExtension().lastPathComponent
            if urls[0].pathExtension.lowercased() != "txt" { notice = L("Subtitle text imported. Cue timing is not used for speech generation.") }
        }
    }
    func importAudio() {
        guard let url = selectFiles(audio: true).first else { return }
        useAudio(url)
    }
    func useAudio(_ url: URL) {
        run("Reading audio") { [self] in
            let limit: Double? = page == .changer ? 300 : nil
            if page == .changer { try validateConversionSource(url) }
            _ = try await Task.detached { try ImportService.inspectAudio(url, maximumDuration: limit) }.value
            sourceAudio = url
            player.load(url)
        }
    }
    func record() {
        guard !busy else { return }
        if recorder.isRecording {
            if let url = recorder.stop() { sourceAudio = url; player.load(url) }
        } else {
            player.stop()
            Task { await recorder.start() }
        }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, !recorder.isRecording else { return false }
        Task {
            do {
                let urls = try await ImportService.dropURLs(from: providers)
                guard !busy else { return }
                if page == .changer || page == .transcription || page == .isolation || page == .dubbing {
                    guard urls.count == 1 else { throw AppFailure("Choose one source recording.") }
                    useAudio(urls[0])
                } else if page == .speech, urls.count == 1, ImportService.textExtensions.contains(urls[0].pathExtension.lowercased()) {
                    run("Importing text") { [self] in
                        text = try await Task.detached { try ImportService.readText(urls[0]) }.value
                        recordingTitle = urls[0].deletingPathExtension().lastPathComponent
                    }
                } else {
                    if page == .speech && !prepareTextBatch() { return }
                    page = .batch; importJobs(urls)
                }
            } catch { self.error = safeError(error) }
        }
        return true
    }
    func generateSpeech() {
        guard canGenerate, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines), settings = generationSettings, client = client
        let title = recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        run("Generating speech") { [self] in
            let location = try AppStorageFiles.resultURL(extension: "txt")
            let item = FileItem(url: location, characters: input.unicodeScalars.count, parts: TextFiles.chunks(input).count,
                fingerprint: TextFiles.digest(input), inlineText: input)
            _ = try await BatchProcessor.process(item, settings: settings, client: client) { [weak self] part, total, message in
                await self?.updateProgress(part: part, total: total, message: message)
            }
            try register(item.output(settings.format), title: title.isEmpty ? L("Speech recording") : title, kind: "Text to Speech")
        }
    }
    nonisolated static func conversionSourceAllowed(_ url: URL) -> Bool {
        ["mp3", "m4a", "flac", "oga", "ogg", "wav"].contains(url.pathExtension.lowercased())
    }
    func validateConversionSource(_ url: URL) throws {
        guard Self.conversionSourceAllowed(url) else { throw AppFailure("Voice Changer accepts MP3, M4A, FLAC, OGA, OGG or WAV. Export other formats as WAV first.") }
    }
    func convertVoice() {
        guard canGenerate, let sourceAudio else { return }
        let client = client, settings = generationSettings
        run("Converting voice") { [self] in
            let destination = try AppStorageFiles.directory("Audio").appendingPathComponent(UUID().uuidString, isDirectory: true)
            let item = try await Task.detached { () -> FileItem in
                _ = try ImportService.inspectAudio(sourceAudio, maximumDuration: 300)
                let data = try AudioSources.read(sourceAudio)
                return FileItem(url: sourceAudio, parts: 1, fingerprint: AudioSources.digest(data), isAudio: true, destinationFolder: destination)
            }.value
            _ = try await BatchProcessor.process(item, settings: settings, client: client) { [weak self] part, total, message in
                await self?.updateProgress(part: part, total: total, message: message)
            }
            try register(item.output(settings.format), title: sourceAudio.deletingPathExtension().lastPathComponent, kind: "Voice Changer")
        }
    }
    func updateProgress(part: Int, total: Int, message: String) { progress = Double(part) / Double(max(1, total)); status = message }
    func register(_ url: URL, title: String, kind: String) throws {
        let recording = LocalRecording(title: title, path: url.path, kind: kind, voiceName: selectedVoice?.name)
        localRecordings.insert(recording, at: 0); result = recording
        try saveLibrary()
        player.load(url)
    }
    func storeAudio(_ data: Data, title: String, kind: String) async throws {
        guard let sourceExtension = ElevenClient.audioExtension(for: data) else { throw AppFailure("The server returned an unsupported audio file.") }
        let source = try AppStorageFiles.resultURL(extension: sourceExtension)
        let outputFormat = format
        try await Task.detached {
            try data.write(to: source, options: .atomic)
            guard AudioFiles.valid(source) else { throw AppFailure("The server returned an unsupported audio file.") }
        }.value
        // Index the paid response before attempting a fallible local export.
        try register(source, title: title, kind: kind)
        if sourceExtension != outputFormat.rawValue {
            let destination = source.deletingPathExtension().appendingPathExtension(outputFormat.rawValue)
            do {
                _ = try await Task.detached { try BatchProcessor.export([source], to: destination, stagingFolder: source.deletingLastPathComponent()) }.value
                if let index = localRecordings.firstIndex(where: { $0.url == source }) {
                    localRecordings[index].path = destination.path
                    result = localRecordings[index]
                    try saveLibrary()
                }
                player.load(destination)
                try? FileManager.default.removeItem(at: source)
            } catch {
                notice = L("The original audio was saved in Audio Library. Local format conversion failed; you can export the original without generating again.")
                throw error
            }
        }
    }
    func saveLibrary() throws {
        try BatchProcessor.directory(AppStorageFiles.root)
        let data = try JSONEncoder().encode(localRecordings)
        try data.write(to: AppStorageFiles.root.appendingPathComponent("library.json"), options: .atomic)
    }
    func exportAudio(_ recording: LocalRecording? = nil) {
        guard let chosen = recording ?? result else { return }
        let panel = NSSavePanel(); panel.title = L("Save Audio")
        panel.nameFieldStringValue = chosen.title + "." + chosen.url.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: chosen.url.pathExtension) ?? .audio]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != chosen.url.standardizedFileURL else { return }
        run("Saving audio") { [self] in
            // NSSavePanel obtained the user's explicit overwrite confirmation.
            try await Task.detached {
                let data = try Data(contentsOf: chosen.url)
                try data.write(to: destination, options: .atomic)
            }.value
            notice = L("Saved %@", destination.lastPathComponent)
        }
    }
    func play(_ recording: LocalRecording) {
        player.load(recording.url); player.play(); result = recording
    }
    func previewVoice(url: String?) {
        guard let url else { notice = L("This voice has no preview available."); return }
        run("Loading voice preview") { [self] in
            let data = try await client.previewAudio(url: url)
            let location = try AppStorageFiles.directory("Previews").appendingPathComponent(TextFiles.digest(url)).appendingPathExtension("mp3")
            try data.write(to: location, options: .atomic); player.load(location); player.play()
        }
    }
    func refreshAfterMutation() async {
        do { voices = try await client.voices(); persistPreferences() }
        catch { self.error = L("The account change succeeded, but the voice list could not refresh: %@", safeError(error)) }
    }
    func refreshVoices() {
        guard requireKey() else { return }
        run("Loading voices") { [self] in voices = try await client.voices(); persistPreferences() }
    }
    func searchShared(more: Bool = false) {
        guard requireKey() else { return }
        run("Searching voice library") { [self] in
            let nextPage = more ? sharedPage + 1 : 0
            let response = try await client.sharedVoices(search: sharedSearch, language: sharedLanguage.isEmpty ? nil : sharedLanguage, page: nextPage)
            if more { sharedVoices += response.voices } else { sharedVoices = response.voices }
            sharedPage = nextPage; sharedMore = response.has_more
        }
    }
    func addShared(_ voice: SharedVoice) {
        guard requireKey() else { return }
        run("Adding voice") { [self] in
            let added = try await client.addSharedVoice(voice, name: voice.name)
            voiceID = added.voice_id; notice = L("Voice added to My Voices."); persistPreferences()
            await refreshAfterMutation()
        }
    }
    func saveVoiceMetadata() {
        guard let voice = editingVoice else { return }
        run("Updating voice") { [self] in
            try await client.editVoice(voice, name: editName, description: editDescription)
            editingVoice = nil; await refreshAfterMutation()
        }
    }
    func deleteVoice(_ voice: Voice) {
        guard voice.canDelete, confirm(title: L("Delete voice %@?", voice.name), message: L("This deletes the owned voice from your ElevenLabs account. This action cannot be undone."), action: L("Delete Voice")) else { return }
        run("Deleting voice") { [self] in
            try await client.deleteVoice(voice); voices.removeAll { $0.id == voice.id }
            if voiceID == voice.id { voiceID = "" }; persistPreferences()
            await refreshAfterMutation()
        }
    }
    func pickCloneSamples() { cloneSamples = selectFiles(audio: true, multiple: true) }
    func cloneVoice() {
        guard requireKey(), cloneConsent, !cloneSamples.isEmpty else { return }
        run("Creating voice clone") { [self] in
            let result = try await client.cloneVoice(name: voiceName, description: voiceDescription, samples: cloneSamples, removeNoise: removeNoise)
            voiceID = result.voice_id; cloneConsent = false; persistPreferences()
            notice = result.requires_verification == true ? L("The voice was created and requires verification on ElevenLabs before use.") : L("Voice created. Select it in Text to Speech to generate new words.")
            await refreshAfterMutation()
        }
    }
    func designVoice() {
        guard requireKey() else { return }
        run("Designing voice previews") { [self] in
            let result = try await client.designVoice(description: voiceDescription, text: designText.isEmpty ? nil : designText)
            designPreviews = result.previews; selectedDesign = result.previews.first?.id ?? ""
        }
    }
    func playDesign(_ preview: VoiceDesignPreview) {
        guard let audio = preview.audio else { return }
        do {
            let url = try AppStorageFiles.directory("Previews").appendingPathComponent(preview.id).appendingPathExtension("mp3")
            try audio.write(to: url, options: .atomic); player.load(url); player.play()
        } catch { self.error = safeError(error) }
    }
    func saveDesign() {
        guard requireKey(), !selectedDesign.isEmpty else { return }
        run("Saving designed voice") { [self] in
            let voice = try await client.createDesignedVoice(name: voiceName, description: voiceDescription, generatedVoiceID: selectedDesign)
            voiceID = voice.id; designPreviews = []; selectedDesign = ""; persistPreferences()
            notice = L("Voice saved to My Voices.")
            await refreshAfterMutation()
        }
    }
    func generateEffect() {
        guard requireKey() else { return }
        run("Generating sound effect") { [self] in
            let audio = try await client.soundEffect(prompt: effectsPrompt, duration: effectAutomaticDuration ? nil : effectDuration, influence: effectInfluence, loop: effectLoop)
            try await storeAudio(audio, title: L("Sound effect"), kind: "Sound Effects")
        }
    }
    func transcribe() {
        guard requireKey(), let sourceAudio else { return }
        run("Transcribing audio") { [self] in
            let result = try await client.transcribe(file: sourceAudio, languageCode: transcriptLanguage.isEmpty ? nil : transcriptLanguage, diarize: diarize)
            if diarize, let words = result.words, words.contains(where: { $0.speaker_id != nil }) {
                var lines: [String] = [], currentSpeaker: String?, segment = ""
                for word in words {
                    let speaker = word.speaker_id ?? currentSpeaker
                    if speaker != currentSpeaker && !segment.isEmpty {
                        lines.append((currentSpeaker.map { $0 + ": " } ?? "") + segment.trimmingCharacters(in: .whitespacesAndNewlines))
                        segment = ""
                    }
                    currentSpeaker = speaker
                    segment += word.text
                }
                if !segment.isEmpty { lines.append((currentSpeaker.map { $0 + ": " } ?? "") + segment.trimmingCharacters(in: .whitespacesAndNewlines)) }
                transcript = lines.joined(separator: "\n\n")
            } else { transcript = result.text }
            notice = L("Detected language: %@", result.language_code)
        }
    }
    func exportTranscript() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(transcript.utf8).write(to: url, options: .atomic) } catch { self.error = safeError(error) }
    }
    func isolate() {
        guard requireKey(), let sourceAudio else { return }
        run("Isolating speech") { [self] in
            let audio = try await client.isolateAudio(file: sourceAudio)
            try await storeAudio(audio, title: sourceAudio.deletingPathExtension().lastPathComponent + " · " + L("Isolated"), kind: "Audio Isolation")
        }
    }
    func createDubbing() {
        guard requireKey(), let sourceAudio else { return }
        run("Creating dubbing project") { [self] in
            let project = try await client.createDubbing(file: sourceAudio, targetLanguage: dubbingTargetLanguage, sourceLanguage: dubbingSourceLanguage.isEmpty ? nil : dubbingSourceLanguage)
            dubbingProject = project; dubbingProjectID = project.id; dubbingTarget = nil; persistPreferences()
            notice = L("Dubbing runs on ElevenLabs. Refresh the project to check progress; cancelling here does not cancel server processing.")
        }
    }
    func refreshDubbing() {
        guard requireKey(), !dubbingProjectID.isEmpty else { return }
        run("Checking dubbing project") { [self] in
            let project = try await client.dubbingProject(id: dubbingProjectID)
            dubbingProject = project
            if let languageID = project.language_ids?.first { dubbingTarget = try await client.dubbingTarget(projectID: project.id, languageID: languageID) }
        }
    }
    func downloadDubbing() {
        guard requireKey(), let dubbingTarget else { return }
        run("Downloading dubbed audio") { [self] in
            let data = try await client.downloadDubbing(dubbingTarget)
            try await storeAudio(data, title: L("Dubbed audio"), kind: "Dubbing")
        }
    }
    func refreshHistory(more: Bool = false) {
        guard requireKey() else { return }
        run("Loading generation history") { [self] in
            let response = try await client.history(after: more ? historyCursor : nil)
            if more { historyItems += response.history } else { historyItems = response.history }
            historyMore = response.has_more; historyCursor = response.last_history_item_id
        }
    }
    func downloadHistory(_ item: HistoryItem) {
        guard requireKey() else { return }
        run("Downloading recording") { [self] in
            let data = try await client.historyAudio(id: item.id)
            try await storeAudio(data, title: item.voice_name ?? L("History recording"), kind: "ElevenLabs History")
        }
    }
    func chooseBatchFiles() { let urls = selectFiles(audio: batchAudio, multiple: true, folders: true); if !urls.isEmpty { importJobs(urls) } }
    func chooseBatchDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { batchDestination = panel.url; refreshJobOutputs() }
    }
    func importJobs(_ selections: [URL]) {
        let audio = batchAudio, selectedFormat = format, destination = batchDestination
        run("Importing batch jobs") { [self] in
            let imported = try await Task.detached { () -> [FileItem] in
                let urls = try ImportService.urls(from: selections, kind: audio ? .audio : .text)
                return urls.map { url in
                    var item = FileItem(url: url, isAudio: audio, destinationFolder: destination)
                    do {
                        if audio {
                            guard Self.conversionSourceAllowed(url) else { throw AppFailure("Voice Changer accepts MP3, M4A, FLAC, OGA, OGG or WAV. Export other formats as WAV first.") }
                            _ = try ImportService.inspectAudio(url, maximumDuration: 300)
                            item.fingerprint = AudioSources.digest(try AudioSources.read(url)); item.parts = 1
                        } else {
                            let input = try ImportService.readText(url)
                            guard !input.isEmpty else { throw AppFailure("The file contains no readable text.") }
                            item.fingerprint = TextFiles.digest(input); item.parts = TextFiles.chunks(input).count; item.characters = input.unicodeScalars.count
                        }
                        item.inspectOutput(selectedFormat)
                    } catch { item.state = .invalid; item.detail = error.localizedDescription }
                    return item
                }
            }.value
            var seen = Set(jobs.map(\.id))
            jobs += imported.filter { seen.insert($0.id).inserted }
            if let folder = selections.first, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { batchFolder = folder }
            refreshJobOutputs(); persistPreferences()
            if imported.contains(where: { ["srt", "vtt"].contains($0.url.pathExtension.lowercased()) }) { notice = L("Subtitle text imported. Cue timing is not used for speech generation.") }
        }
    }
    func refreshJobOutputs() {
        var outputs: Set<String> = []
        for index in jobs.indices {
            if jobs[index].state == .invalid && !jobs[index].destinationIssue { continue }
            if jobs[index].destinationIssue { jobs[index].state = .ready; jobs[index].destinationIssue = false }
            jobs[index].destinationFolder = batchDestination
            if jobs[index].isAudio && jobs[index].output(format).standardizedFileURL == jobs[index].url.standardizedFileURL {
                jobs[index].state = .invalid; jobs[index].destinationIssue = true
                jobs[index].detail = L("Choose a destination different from the source recording."); continue
            }
            let path = jobs[index].output(format).path.precomposedStringWithCanonicalMapping.lowercased()
            if !outputs.insert(path).inserted { jobs[index].state = .invalid; jobs[index].destinationIssue = true; jobs[index].detail = L("Duplicate output filename. Choose another destination or rename a source."); continue }
            if jobs[index].state != .invalid {
                jobs[index].state = .ready; jobs[index].detail = "Ready"; jobs[index].inspectOutput(format)
            }
        }
    }
    func startBatch() {
        guard !readyJobs.isEmpty else { return }
        let queue = readyJobs
        let requiresAPI = queue.contains { $0.existingAudio(except: format) == nil }
        if requiresAPI && (!requireKey() || voiceID.isEmpty) { return }
        let client = client, settings = generationSettings
        run("Processing batch") { [self] in
            let total = queue.reduce(0) { $0 + max(1, $1.parts) }; var completed = 0
            for item in queue {
                try Task.checkCancellation()
                updateJob(item.id, state: .working, detail: L("Processing"))
                do {
                    let before = completed
                    let generated = try await BatchProcessor.process(item, settings: settings, client: client) { [weak self] part, _, message in
                        await self?.batchProgress(item.id, completed: before + part, total: total, message: message)
                    }
                    updateJob(item.id, state: generated ? .done : .existing, detail: item.output(settings.format).lastPathComponent)
                    completed += max(1, item.parts)
                    if generated { try register(item.output(settings.format), title: item.url.deletingPathExtension().lastPathComponent, kind: "Batch Jobs") }
                } catch {
                    updateJob(item.id, state: Task.isCancelled ? .ready : .failed, detail: Task.isCancelled ? L("Ready to resume") : safeError(error))
                    throw error
                }
            }
        }
    }
    func batchProgress(_ id: String, completed: Int, total: Int, message: String) { updateJob(id, state: .working, detail: message); updateProgress(part: completed, total: total, message: message) }
    func updateJob(_ id: String, state: FileState, detail: String) { if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = state; jobs[i].detail = detail } }
    func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: L("Cancel")); alert.addButton(withTitle: action)
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
}

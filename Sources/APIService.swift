import Foundation

// Credentials must never follow a redirect to a third-party host.
private final class APIHostGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "api.elevenlabs.io" else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

struct ElevenClient {
    let key: String
    var session: URLSession = .shared

    func request(path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        guard path.range(of: "^/v[12]/[A-Za-z0-9_/-]+$", options: .regularExpression) != nil,
              !path.contains("//"), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure(L("Enter a valid ElevenLabs API key in Settings."))
        }
        var components = URLComponents(string: "https://api.elevenlabs.io" + path)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AppFailure(L("The API request is invalid.")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 240
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func checked(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        guard request.url?.scheme == "https", request.url?.host == "api.elevenlabs.io" else {
            throw AppFailure(L("The API request is invalid."))
        }
        let (data, response) = try await session.data(for: request, delegate: APIHostGuard())
        guard let http = response as? HTTPURLResponse else { throw AppFailure(L("ElevenLabs did not return a response.")) }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = json?["detail"] as? [String: Any]
            let raw = (detail?["message"] as? String) ?? (json?["detail"] as? String) ?? ""
            let safe = String(raw.replacingOccurrences(of: key, with: "[redacted]").prefix(250))
            let hint: String
            switch http.statusCode {
            case 401: hint = L("Authentication failed. Check the API key in Settings.")
            case 403: hint = L("This key or account does not have permission for this operation. Check the key scopes and subscription.")
            case 402: hint = L("ElevenLabs requires credits or a different subscription for this operation.")
            case 429: hint = L("ElevenLabs reached a request or usage limit. Check your account before trying again.")
            case 422: hint = L("ElevenLabs rejected these settings. Check the model, language, and input file.")
            default: hint = L("ElevenLabs returned HTTP %@.", String(http.statusCode))
            }
            throw AppFailure(hint + (safe.isEmpty ? "" : "\n" + safe))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data = try await checked(request)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AppFailure(L("ElevenLabs returned an unexpected response. Refresh and try again.")) }
    }

    func models() async throws -> [APIModel] { try await decode([APIModel].self, from: request(path: "/v1/models")) }
    func account() async throws -> APIAccount { try await decode(APIAccount.self, from: request(path: "/v1/user")) }
    func subscription() async throws -> AccountSubscription {
        try await decode(AccountSubscription.self, from: request(path: "/v1/user/subscription"))
    }
    func voices() async throws -> [Voice] {
        var voices: [Voice] = [], token: String?, seen: Set<String> = []
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let token { query.append(URLQueryItem(name: "next_page_token", value: token)) }
            let page = try await decode(VoicePage.self, from: request(path: "/v2/voices", query: query))
            voices += page.voices
            token = page.has_more ? page.next_page_token : nil
            if let token, !seen.insert(token).inserted { throw AppFailure(L("The voice list could not be fully loaded.")) }
            if page.has_more && (token == nil || token?.isEmpty == true) {
                throw AppFailure(L("ElevenLabs returned an incomplete voice list."))
            }
        } while token != nil
        var ids: Set<String> = []
        return voices.filter { ids.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func sharedVoices(search: String = "", language: String? = nil, category: String? = nil, page: Int = 0) async throws -> SharedVoicePage {
        guard page >= 0 else { throw AppFailure(L("The API request is invalid.")) }
        var query = [URLQueryItem(name: "page_size", value: "30"), URLQueryItem(name: "page", value: String(page))]
        if !search.isEmpty { query.append(.init(name: "search", value: search)) }
        if let language, !language.isEmpty { query.append(.init(name: "language", value: language)) }
        if let category, ["professional", "famous", "high_quality"].contains(category) {
            query.append(.init(name: "category", value: category))
        }
        return try await decode(SharedVoicePage.self, from: request(path: "/v1/shared-voices", query: query))
    }
    func addSharedVoice(_ voice: SharedVoice, name: String) async throws -> VoiceCreationResult {
        try validateVoice(voice.voice_id); try validateIdentifier(voice.public_owner_id)
        guard voice.canAdd else { throw AppFailure(L("This voice is already in your account.")) }
        try requireText(name)
        return try await decode(VoiceCreationResult.self, from: request(path: "/v1/voices/add/\(voice.public_owner_id)/\(voice.voice_id)", body: ["new_name": name]))
    }
    func editVoice(_ voice: Voice, name: String, description: String) async throws {
        try validateVoice(voice.voice_id); try requireText(name)
        guard voice.canEdit else { throw AppFailure(L("Ownership is not confirmed for this voice. Refresh My Voices.")) }
        let form = MultipartForm(fields: [("name", name), ("description", description)])
        _ = try await checked(multipart(path: "/v1/voices/\(voice.voice_id)/edit", form: form))
    }
    func deleteVoice(_ voice: Voice) async throws {
        try validateVoice(voice.voice_id)
        guard voice.canDelete else { throw AppFailure(L("Ownership is not confirmed for this voice. Refresh My Voices.")) }
        var req = try request(path: "/v1/voices/\(voice.voice_id)"); req.httpMethod = "DELETE"
        _ = try await checked(req)
    }
    func cloneVoice(name: String, description: String, samples: [URL], removeNoise: Bool = false) async throws -> VoiceCreationResult {
        try requireText(name)
        guard !samples.isEmpty else { throw AppFailure(L("Choose at least one voice sample.")) }
        var form = MultipartForm(fields: [("name", name), ("description", description), ("remove_background_noise", String(removeNoise))])
        for (index, url) in samples.enumerated() {
            try Task.checkCancellation()
            let audio = try uploadData(url)
            guard form.count + audio.count <= Self.uploadLimit else { throw AppFailure(L("The selected files exceed the 100 MB upload limit of this app.")) }
            form.file("files", filename: "sample-\(index)." + safeExtension(url), mime: mime(url), data: audio)
        }
        return try await decode(VoiceCreationResult.self, from: multipart(path: "/v1/voices/add", form: form))
    }
    func designVoice(description: String, text: String?, modelID: String = "eleven_multilingual_ttv_v2") async throws -> VoiceDesignResult {
        try requireText(description)
        guard ["eleven_multilingual_ttv_v2", "eleven_ttv_v3"].contains(modelID) else { throw AppFailure(L("Select a supported Voice Design model.")) }
        var body: [String: Any] = ["voice_description": description, "model_id": modelID]
        if let text, !text.isEmpty {
            guard (100...1000).contains(text.count) else { throw AppFailure(L("Voice Design preview text must contain 100–1000 characters.")) }
            body["text"] = text
        } else { body["auto_generate_text"] = true }
        return try await decode(VoiceDesignResult.self, from: request(path: "/v1/text-to-voice/design", query: Self.mp3Query, body: body))
    }
    func createDesignedVoice(name: String, description: String, generatedVoiceID: String) async throws -> Voice {
        try requireText(name); try requireText(description); try validateIdentifier(generatedVoiceID)
        return try await decode(Voice.self, from: request(path: "/v1/text-to-voice", body: [
            "voice_name": name, "voice_description": description, "generated_voice_id": generatedVoiceID]))
    }

    func speech(text: String, settings: GenerationSettings, previous: String?, next: String?) async throws -> Data {
        try validateVoice(settings.voiceID); try requireText(text)
        let spoken = settings.delivery.isEmpty ? text : "[\(settings.delivery)] " + text
        var body: [String: Any] = ["text": spoken, "model_id": settings.modelID]
        if let parameters = settings.voiceParameters { body["voice_settings"] = parameters }
        if settings.supportedExplicitLanguage, !settings.modelID.contains("multilingual_v2"), let language = settings.languageCode, !language.isEmpty {
            try validateLanguage(language, bcp47: false)
            body["language_code"] = language
        }
        if settings.modelID == "eleven_multilingual_v2" || settings.modelID == "eleven_flash_v2_5" {
            if let previous { body["previous_text"] = String(previous.suffix(500)) }
            if let next { body["next_text"] = String(next.prefix(500)) }
        }
        var req = try request(path: "/v1/text-to-speech/" + settings.voiceID, query: Self.mp3Query, body: body)
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        return try await checked(req)
    }
    func changeVoice(audio: Data, extension ext: String, settings: GenerationSettings) async throws -> Data {
        try validateVoice(settings.voiceID)
        guard !audio.isEmpty, audio.count <= Self.uploadLimit else { throw AppFailure(L("Choose a nonempty audio file smaller than 100 MB.")) }
        var fields = [("model_id", settings.modelID), ("remove_background_noise", String(settings.removeNoise))]
        if let parameters = settings.voiceParameters {
            let json = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
            fields.append(("voice_settings", String(decoding: json, as: UTF8.self)))
        }
        var form = MultipartForm(fields: fields)
        let url = URL(fileURLWithPath: "input." + ext)
        form.file("audio", filename: "input." + safeExtension(url), mime: mime(url), data: audio)
        return try await checked(multipart(path: "/v1/speech-to-speech/" + settings.voiceID, query: Self.mp3Query, form: form, accept: "audio/mpeg"))
    }
    func transcribe(file: URL, languageCode: String? = nil, diarize: Bool = false, modelID: String = "scribe_v2") async throws -> TranscriptionResult {
        guard ["scribe_v1", "scribe_v2"].contains(modelID) else { throw AppFailure(L("Select a supported transcription model.")) }
        var fields = [("model_id", modelID), ("diarize", String(diarize)), ("timestamps_granularity", "word"), ("tag_audio_events", "true")]
        if let languageCode, !languageCode.isEmpty {
            try validateLanguage(languageCode, bcp47: false); fields.append(("language_code", languageCode))
        }
        var form = MultipartForm(fields: fields)
        form.file("file", filename: "input." + safeExtension(file), mime: mime(file), data: try uploadData(file))
        return try await decode(TranscriptionResult.self, from: multipart(path: "/v1/speech-to-text", form: form))
    }
    func soundEffect(prompt: String, duration: Double? = nil, influence: Double = 0.3, loop: Bool = false) async throws -> Data {
        try requireText(prompt)
        guard influence.isFinite, (0...1).contains(influence), duration == nil || (duration!.isFinite && (0.5...30).contains(duration!)) else {
            throw AppFailure(L("Sound duration must be 0.5–30 seconds and prompt influence must be between 0 and 1."))
        }
        var body: [String: Any] = ["text": prompt, "model_id": "eleven_text_to_sound_v2", "prompt_influence": influence, "loop": loop]
        if let duration { body["duration_seconds"] = duration }
        var req = try request(path: "/v1/sound-generation", query: Self.mp3Query, body: body)
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        return try await checked(req)
    }
    func isolateAudio(file: URL) async throws -> Data {
        var form = MultipartForm(fields: [("file_format", "other")])
        form.file("audio", filename: "input." + safeExtension(file), mime: mime(file), data: try uploadData(file))
        return try await checked(multipart(path: "/v1/audio-isolation", form: form, accept: "audio/*"))
    }
    func history(after: String? = nil, search: String = "") async throws -> HistoryPage {
        var query = [URLQueryItem(name: "page_size", value: "50")]
        if let after { try validateIdentifier(after); query.append(.init(name: "start_after_history_item_id", value: after)) }
        if !search.isEmpty { query.append(.init(name: "search", value: search)) }
        return try await decode(HistoryPage.self, from: request(path: "/v1/history", query: query))
    }
    func historyAudio(id: String) async throws -> Data {
        try validateIdentifier(id)
        var req = try request(path: "/v1/history/\(id)/audio"); req.setValue("audio/*", forHTTPHeaderField: "Accept")
        return try await checked(req)
    }

    func createDubbing(file: URL, targetLanguage: String, sourceLanguage: String? = nil, reference: String = "") async throws -> DubbingProject {
        try validateLanguage(targetLanguage, bcp47: true)
        var fields = [("target_language", targetLanguage), ("model_id", "dubbing_v2")]
        if !reference.isEmpty { fields.append(("reference", String(reference.prefix(500)))) }
        if let sourceLanguage, !sourceLanguage.isEmpty {
            try validateLanguage(sourceLanguage, bcp47: true); fields.append(("source_language", sourceLanguage))
        }
        var form = MultipartForm(fields: fields)
        form.file("file", filename: "input." + safeExtension(file), mime: mime(file), data: try uploadData(file))
        return try await decode(DubbingProject.self, from: multipart(path: "/v1/dubbing/project", form: form))
    }
    func dubbingProject(id: String) async throws -> DubbingProject {
        try validateIdentifier(id)
        return try await decode(DubbingProject.self, from: request(path: "/v1/dubbing/project/" + id))
    }
    func dubbingTarget(projectID: String, languageID: String) async throws -> DubbingTarget {
        try validateIdentifier(projectID); try validateIdentifier(languageID)
        return try await decode(DubbingTarget.self, from: request(path: "/v1/dubbing/project/\(projectID)/language/\(languageID)"))
    }
    func downloadDubbing(_ target: DubbingTarget) async throws -> Data {
        guard target.status == "completed", let url = target.outputs?.lossless_audio else {
            throw AppFailure(L("The dubbing output is not ready. Refresh its status later."))
        }
        return try await previewAudio(url: url)
    }

    // Public preview and signed output URLs originate in authenticated service
    // responses. They never receive xi-api-key, even on a CDN redirect.
    func previewAudio(url: String) async throws -> Data {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host,
              !host.isEmpty, parsed.user == nil, parsed.password == nil else {
            throw AppFailure(L("ElevenLabs returned an invalid audio URL."))
        }
        try Task.checkCancellation()
        var req = URLRequest(url: parsed); req.timeoutInterval = 240
        req.setValue("audio/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw AppFailure(L("Audio could not be downloaded. Refresh the item and try again."))
        }
        guard !data.isEmpty else { throw AppFailure(L("ElevenLabs returned an empty audio file.")) }
        return data
    }
    static func audioExtension(for data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE" { return "wav" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "fLaC" { return "flac" }
        if b.count >= 3, String(bytes: b[0..<3], encoding: .ascii) == "ID3" { return "mp3" }
        if b.count >= 2, b[0] == 0xff, b[1] & 0xe0 == 0xe0 { return "mp3" }
        if b.count >= 8, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" { return "m4a" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "OggS" { return "ogg" }
        return nil
    }

    func validateVoice(_ id: String) throws {
        do { try validateIdentifier(id) }
        catch { throw AppFailure(L("Select a voice or enter a valid Voice ID.")) }
    }
    private func validateIdentifier(_ id: String) throws {
        guard !id.isEmpty, id.count <= 128, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw AppFailure(L("The API identifier is invalid."))
        }
    }
    private func validateLanguage(_ language: String, bcp47: Bool) throws {
        let pattern = bcp47 ? "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$" : "^[a-z]{2,3}$"
        guard language.range(of: pattern, options: .regularExpression) != nil else {
            throw AppFailure(L("Enter a supported language code, such as en or pl."))
        }
    }
    private func requireText(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure(L("Enter text before continuing.")) }
    }
    private static let uploadLimit = 100 * 1024 * 1024
    private static var mp3Query: [URLQueryItem] { [.init(name: "output_format", value: "mp3_44100_128")] }
    private func uploadData(_ file: URL) throws -> Data {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard file.isFileURL, info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= Self.uploadLimit else {
            throw AppFailure(L("Choose a nonempty audio file smaller than 100 MB."))
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= Self.uploadLimit else { throw AppFailure(L("The selected files exceed the 100 MB upload limit of this app.")) }
        return data
    }
    private func safeExtension(_ file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "flac", "aif", "aiff", "ogg", "opus", "mp4", "mov", "webm"].contains(ext) ? ext : "bin"
    }
    private func mime(_ file: URL) -> String {
        ["mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "flac": "audio/flac", "aiff": "audio/aiff", "aif": "audio/aiff", "ogg": "audio/ogg", "opus": "audio/ogg", "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"][safeExtension(file)] ?? "application/octet-stream"
    }
    private func multipart(path: String, query: [URLQueryItem] = [], form: MultipartForm, accept: String = "application/json") throws -> URLRequest {
        var req = try request(path: path, query: query)
        req.httpMethod = "POST"; req.httpBody = form.body
        req.setValue("multipart/form-data; boundary=" + form.boundary, forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        return req
    }
}

private struct MultipartForm {
    let boundary = "VoiceDesk-" + UUID().uuidString
    private var data = Data()
    var count: Int { data.count }
    init(fields: [(String, String)]) {
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
    }
    mutating func file(_ field: String, filename: String, mime: String, data file: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        data.append(file); append("\r\n")
    }
    var body: Data { var result = data; result.append(Data("--\(boundary)--\r\n".utf8)); return result }
    private mutating func append(_ text: String) { data.append(Data(text.utf8)) }
}

import Foundation

private final class APIStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.calls += 1
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppFailure("API TEST FAILED: " + message) }
}
private func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var bytes = [UInt8](repeating: 0, count: 4096), result = Data()
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        result.append(bytes, count: count)
    }
    return result
}
private func json(_ value: String) -> Data { Data(value.utf8) }
private func parse(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: Any]
}
private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try JSONDecoder().decode(type, from: json(value))
}

@main struct APITests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIStub.self]
        let client = ElevenClient(key: "test-only-credential", session: URLSession(configuration: config))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.wav")
        try json("RIFF0000WAVEfixture").write(to: file)
        var passed = 0
        func ok(_ name: String) { passed += 1; print("PASS " + name) }

        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/models", "model endpoint")
            try expect(req.value(forHTTPHeaderField: "xi-api-key") == "test-only-credential", "authenticated model discovery")
            return (200, json("""
            [{"model_id":"eleven_multilingual_v2","name":"Multilingual v2","can_do_text_to_speech":true,"languages":[{"language_id":"ja","name":"Japanese"}]},{"model_id":"eleven_flash_v2_5","can_do_text_to_speech":true,"can_use_style":false,"languages":[{"language_id":"pl","name":"Polish"}]},{"model_id":"future_model"}]
            """))
        }
        let models = try await client.models()
        try expect(!models[0].supportsExplicitLanguage && models[1].supportsExplicitLanguage, "explicit language model compatibility")
        try expect(models[2].can_do_text_to_speech == nil && models[2].displayName == "future_model", "unknown capability remains unknown")
        ok("model discovery, optional metadata, and language capabilities")

        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/user/subscription", "subscription endpoint")
            return (200, json("{\"tier\":\"starter\",\"character_count\":45,\"character_limit\":100,\"can_use_instant_voice_cloning\":true}"))
        }
        let subscription = try await client.subscription()
        try expect(subscription.remainingCharacters == 55 && subscription.can_use_instant_voice_cloning == true, "reported allowance")
        APIStub.handler = { _ in (200, json("{\"user_id\":\"user_example\",\"workspace_id\":\"workspace_example\",\"xi_api_key_preview\":\"ignored\"}")) }
        _ = try await client.account()
        ok("account and subscription decoding")

        var page = 0
        APIStub.handler = { req in
            page += 1
            if page == 1 { return (200, json("{\"voices\":[{\"voice_id\":\"v1\",\"name\":\"Shared\",\"category\":\"cloned\"}],\"has_more\":true,\"next_page_token\":\"page2\"}")) }
            try expect(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "next_page_token", value: "page2")) == true, "voice cursor")
            return (200, json("{\"voices\":[{\"voice_id\":\"v1\",\"name\":\"Shared\"},{\"voice_id\":\"v2\",\"name\":\"Owned\",\"is_owner\":true,\"category\":\"cloned\"}],\"has_more\":false}"))
        }
        let voices = try await client.voices()
        try expect(voices.count == 2, "duplicate voice IDs removed")
        try expect(voices.first { $0.id == "v1" }?.canDelete == false && voices.first { $0.id == "v2" }?.canEdit == true, "ownership never inferred from cloned category")
        let unknown = try decode(Voice.self, "{\"voice_id\":\"unknown\"}")
        try expect(unknown.name == "unknown" && !unknown.canEdit, "missing metadata fail closed")
        APIStub.handler = { _ in (200, json("{\"voices\":[],\"has_more\":true}")) }
        do { _ = try await client.voices(); throw AppFailure("pagination should fail") } catch let e as AppFailure { try expect(e.message != "pagination should fail", "missing pagination cursor rejected") }
        ok("account voice pagination and ownership controls")

        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/shared-voices", "shared library endpoint")
            let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try expect(query.contains(.init(name: "search", value: "calm & warm")) && query.contains(.init(name: "page", value: "2")), "escaped search and pagination")
            return (200, json("{\"voices\":[{\"voice_id\":\"shared\",\"public_owner_id\":\"publicowner\",\"name\":\"Example\",\"is_added_by_user\":false}],\"has_more\":true}"))
        }
        let shared = try await client.sharedVoices(search: "calm & warm", language: "en", page: 2)
        try expect(shared.has_more && shared.voices[0].canAdd, "shared voices separately typed")
        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/voices/add/publicowner/shared", "add shared endpoint")
            let body = try parse(req); try expect(body["new_name"] as? String == "Saved name", "shared save JSON")
            return (200, json("{\"voice_id\":\"saved\"}"))
        }
        _ = try await client.addSharedVoice(shared.voices[0], name: "Saved name")
        ok("shared voice search, paging, and add")

        var owned = Voice(voice_id: "owned", name: "Owned"); owned.is_owner = true; owned.category = "cloned"
        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/voices/owned/edit", "edit endpoint")
            try expect(String(decoding: bodyData(req), as: UTF8.self).contains("name=\"description\"\r\n\r\nUpdated"), "metadata multipart")
            return (200, json("{\"status\":\"ok\"}"))
        }
        try await client.editVoice(owned, name: "Name", description: "Updated")
        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/voices/owned" && req.httpMethod == "DELETE", "delete endpoint and method")
            return (200, json("{\"status\":\"ok\"}"))
        }
        try await client.deleteVoice(owned)
        let before = APIStub.calls
        do { try await client.deleteVoice(unknown); throw AppFailure("delete should fail") } catch {}
        try expect(APIStub.calls == before, "unknown ownership sends no delete")
        ok("owned voice edit/delete and unknown-owner rejection")

        APIStub.handler = { req in
            let body = String(decoding: bodyData(req), as: UTF8.self)
            try expect(req.url?.path == "/v1/voices/add", "IVC endpoint")
            try expect(body.components(separatedBy: "name=\"files\"").count == 3, "two repeated sample files")
            try expect(body.contains("filename=\"sample-0.wav\"") && !body.contains(root.path), "local paths not transmitted")
            return (200, json("{\"voice_id\":\"clone\",\"requires_verification\":true}"))
        }
        let clone = try await client.cloneVoice(name: "My sample", description: "Clear", samples: [file, file])
        try expect(clone.requires_verification == true, "verification status retained")
        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/text-to-voice/design", "design endpoint")
            let body = try parse(req); try expect(body["auto_generate_text"] as? Bool == true && body["text"] == nil, "automatic preview script")
            return (200, json("{\"previews\":[{\"generated_voice_id\":\"design\",\"audio_base_64\":\"SUQz\",\"media_type\":\"audio/mpeg\"}],\"text\":\"Preview\"}"))
        }
        let design = try await client.designVoice(description: "Warm narrator", text: nil)
        try expect(design.previews[0].audio == json("ID3"), "preview data decoding")
        APIStub.handler = { req in
            let body = try parse(req)
            try expect(req.url?.path == "/v1/text-to-voice" && body["generated_voice_id"] as? String == "design", "save selected design")
            return (200, json("{\"voice_id\":\"created\",\"name\":\"Created\"}"))
        }
        _ = try await client.createDesignedVoice(name: "Created", description: "Warm narrator", generatedVoiceID: "design")
        ok("instant cloning samples and two-step voice design")

        let multilingualText = "Dzień dobry! Welcome. 今日もよろしくお願いします。"
        var settings = GenerationSettings(voiceID: "v1", modelID: "eleven_flash_v2_5")
        settings.languageCode = "ja"; settings.supportedExplicitLanguage = true
        APIStub.handler = { req in
            let body = try parse(req)
            try expect(body["text"] as? String == multilingualText, "Unicode text preserved")
            try expect(body["language_code"] as? String == "ja", "explicit supported language")
            return (200, json("ID3audio"))
        }
        _ = try await client.speech(text: multilingualText, settings: settings, previous: nil, next: nil)
        var auto = GenerationSettings(voiceID: "v1", modelID: "eleven_multilingual_v2")
        auto.languageCode = "ja"; auto.supportedExplicitLanguage = true
        APIStub.handler = { req in
            let body = try parse(req); try expect(body["language_code"] == nil, "unsupported parameter omitted even when UI flag stale")
            return (200, json("ID3audio"))
        }
        _ = try await client.speech(text: multilingualText, settings: auto, previous: nil, next: nil)
        ok("multilingual TTS and unsupported language omission")

        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/speech-to-text", "STT endpoint")
            let body = String(decoding: bodyData(req), as: UTF8.self)
            try expect(body.contains("name=\"file\"") && body.contains("scribe_v2") && body.contains("name=\"language_code\"\r\n\r\npl"), "STT multipart")
            return (200, json("{\"text\":\"Zażółć\",\"language_code\":\"pol\",\"words\":[{\"text\":\"Zażółć\",\"start\":0,\"end\":1,\"speaker_id\":\"speaker_0\"}]}"))
        }
        let transcript = try await client.transcribe(file: file, languageCode: "pl", diarize: true)
        try expect(transcript.text == "Zażółć" && transcript.words?.first?.speaker_id == "speaker_0", "transcript words and diarization")
        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/audio-isolation", "isolation endpoint")
            try expect(String(decoding: bodyData(req), as: UTF8.self).contains("name=\"audio\""), "isolation audio field")
            return (200, json("RIFF0000WAVEresult"))
        }
        let isolated = try await client.isolateAudio(file: file)
        try expect(ElevenClient.audioExtension(for: isolated) == "wav", "output format detected from content")
        APIStub.handler = { req in
            let body = try parse(req)
            try expect(req.url?.path == "/v1/sound-generation" && body["model_id"] as? String == "eleven_text_to_sound_v2", "SFX model")
            try expect(body["loop"] as? Bool == true && body["duration_seconds"] as? Double == 2, "SFX parameters")
            return (200, json("ID3audio"))
        }
        _ = try await client.soundEffect(prompt: "Rain", duration: 2, influence: 0.4, loop: true)
        let beforeInvalid = APIStub.calls
        do { _ = try await client.soundEffect(prompt: "Rain", duration: 50); throw AppFailure("validation should fail") } catch {}
        try expect(APIStub.calls == beforeInvalid, "invalid duration sends no request")
        ok("transcription, isolation, and sound effects contracts")

        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/history", "history endpoint")
            return (200, json("{\"history\":[{\"history_item_id\":\"h1\",\"date_unix\":100,\"source\":\"TTS\"}],\"has_more\":true,\"last_history_item_id\":\"h1\"}"))
        }
        let history = try await client.history()
        try expect(history.has_more && history.last_history_item_id == "h1", "history cursor")
        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/history/h1/audio", "history audio retrieval")
            return (200, json("ID3audio"))
        }
        _ = try await client.historyAudio(id: "h1")
        ok("generation history and audio retrieval")

        APIStub.handler = { req in
            try expect(req.url?.path == "/v1/dubbing/project", "current dubbing API")
            let body = String(decoding: bodyData(req), as: UTF8.self)
            try expect(body.contains("dubbing_v2") && body.contains("name=\"target_language\"\r\n\r\npl"), "first language queued on create")
            return (201, json("{\"project_id\":\"proj_example\",\"status\":\"queued\",\"language_ids\":[\"lang_example\"]}"))
        }
        let project = try await client.createDubbing(file: file, targetLanguage: "pl")
        APIStub.handler = { req in
            if req.url?.path == "/v1/dubbing/project/proj_example" { return (200, json("{\"project_id\":\"proj_example\",\"status\":\"ready\"}")) }
            try expect(req.url?.path == "/v1/dubbing/project/proj_example/language/lang_example", "language target status")
            return (200, json("{\"project_id\":\"proj_example\",\"language_id\":\"lang_example\",\"target_language\":\"pl\",\"status\":\"completed\",\"outputs\":{\"lossless_audio\":\"https://storage.example.com/output.flac?signature=example\"}}"))
        }
        _ = try await client.dubbingProject(id: project.project_id)
        let target = try await client.dubbingTarget(projectID: project.project_id, languageID: project.language_ids![0])
        APIStub.handler = { req in
            try expect(req.value(forHTTPHeaderField: "xi-api-key") == nil, "API key never sent to CDN")
            return (200, json("fLaCaudio"))
        }
        let dubbed = try await client.downloadDubbing(target)
        try expect(ElevenClient.audioExtension(for: dubbed) == "flac", "lossless dubbing output")
        _ = try await client.previewAudio(url: "https://storage.example.com/preview.mp3")
        ok("dubbing creation/status/download and credential-free CDN previews")

        APIStub.handler = { _ in (403, json("{\"detail\":{\"message\":\"Denied test-only-credential\"}}")) }
        let count = APIStub.calls
        do { _ = try await client.models(); throw AppFailure("error should fail") }
        catch { try expect(!error.localizedDescription.contains("test-only-credential"), "key redacted") }
        try expect(APIStub.calls == count + 1, "failed calls never auto-retry")
        let invalidBefore = APIStub.calls
        do { _ = try client.request(path: "/v1/../secret"); throw AppFailure("path should fail") } catch {}
        do { _ = try await client.historyAudio(id: "../escape"); throw AppFailure("ID should fail") } catch {}
        do { _ = try await client.previewAudio(url: "file:///tmp/private"); throw AppFailure("preview should fail") } catch {}
        try expect(APIStub.calls == invalidBefore, "unsafe identifiers and URLs rejected before network")
        ok("redaction, no paid retries, path and URL validation")
        print("\(passed) API contract groups passed; mock transport only, no live API requests.")
    }
}

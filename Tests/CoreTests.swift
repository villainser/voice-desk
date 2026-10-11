import Foundation
import AVFoundation

final class MockAPI: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.calls += 1
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw AppFailure("TEST FAILED: " + message) }
}

func requestData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

@main
struct CoreTests {
    static func main() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: Localizer.preferenceKey)
        UserDefaults.standard.set("en", forKey: Localizer.preferenceKey)
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: Localizer.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: Localizer.preferenceKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-voice-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        func ok(_ name: String) { passed += 1; print("PASS \(name)") }

        for text in [String(repeating: "Zażółć gęślą jaźń.\n", count: 800), String(repeating: "X", count: 12001), String(repeating: "👨‍👩‍👧‍👦 é ", count: 2000)] {
            let parts = TextFiles.chunks(text)
            try check(parts.joined() == text, "chunking must preserve every Unicode scalar")
            try check(parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 4000 }, "API chunk length")
        }
        try check(TextFiles.chunks("").isEmpty, "empty text")
        ok("Long text and Unicode preserve all characters")

        let input = root.appendingPathComponent("Zażółć. rozdział 01.TXT")
        let text = String(repeating: "To jest zdanie po polsku. ", count: 250)
        try Data(text.utf8).write(to: input)
        try Data().write(to: root.appendingPathComponent("pusty.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("katalog.txt"), withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("kodowanie.txt")
        try "Zażółć gęślą jaźń".data(using: .windowsCP1250)!.write(to: legacy)
        try check(try TextFiles.read(legacy) == "Zażółć gęślą jaźń", "Windows-1250")
        let utf16 = root.appendingPathComponent("unicode.txt")
        try "Łódź i książka".data(using: .utf16)!.write(to: utf16)
        try check(try TextFiles.read(utf16) == "Łódź i książka", "UTF-16 BOM")
        var list = try TextFiles.scan(root)
        let item = list.first { $0.url.lastPathComponent == input.lastPathComponent }!
        try check(item.parts == 2, "long file requires two API requests")
        try check(list.first { $0.url.lastPathComponent == "pusty.txt" }?.state == .invalid, "empty skipped")
        try check(list.first { $0.url.lastPathComponent == "katalog.txt" }?.state == .invalid, "directory skipped")
        try check(TextFiles.output(for: input).lastPathComponent == "Zażółć. rozdział 01.m4a", "same basename")
        ok("Filenames, uppercase TXT, encodings, and empty files")

        // Twenty valid MPEG-1 Layer III silence frames, generated locally.
        // This exercises the actual MP3 decoder and AAC/M4A output path.
        var frame = Data([0xff, 0xfb, 0x90, 0xc4])
        frame.append(Data(repeating: 0, count: 413))
        var audio = Data()
        for _ in 0..<20 { audio.append(frame) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAPI.self]
        let client = ElevenClient(key: "test-only-dummy-key", session: URLSession(configuration: config))
        let settings = GenerationSettings(voiceID: "ExampleVoiceID", modelID: "eleven_multilingual_v2")
        var requestTexts: [String] = []
        MockAPI.calls = 0
        MockAPI.handler = { req in
            try check(req.url?.host == "api.elevenlabs.io", "official host only")
            try check(req.value(forHTTPHeaderField: "xi-api-key") == "test-only-dummy-key", "API auth header")
            try check(req.httpMethod == "POST", "POST speech")
            try check(req.url!.path == "/v1/text-to-speech/ExampleVoiceID", "voice path")
            var body = req.httpBody
            if body == nil, let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var d = Data(), bytes = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; d.append(bytes, count: count) }
                body = d
            }
            let json = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            requestTexts.append(json["text"] as! String)
            try check(json["model_id"] as? String == settings.modelID, "chosen model")
            if MockAPI.calls == 2 { return (429, Data("{\"detail\":{\"message\":\"quota exhausted\"}}".utf8)) }
            return (200, audio)
        }
        do {
            _ = try await BatchProcessor.process(item, settings: settings, client: client) { _, _, _ in }
            throw AppFailure("TEST FAILED: 429 should stop generation")
        } catch {
            try check(error.localizedDescription.contains("limit"), "429 reported clearly; received: " + error.localizedDescription)
        }
        try check(MockAPI.calls == 2, "no automatic paid retry")
        try check(!FileManager.default.fileExists(atPath: TextFiles.output(for: input).path), "no partial final file")
        try check(requestTexts.joined() == text.trimmingCharacters(in: .whitespacesAndNewlines), "correct content sent")
        ok("API errors stop the queue without retries or partial output")

        MockAPI.handler = { _ in (200, audio) }
        let generated = try await BatchProcessor.process(item, settings: settings, client: client) { _, _, _ in }
        try check(generated, "resume produces final audio")
        try check(MockAPI.calls == 3, "resume reuses the first paid chunk")
        let out = TextFiles.output(for: input)
        let decoded = try AVAudioFile(forReading: out)
        let duration = Double(decoded.length) / decoded.processingFormat.sampleRate
        try check(abs(duration - 1.0) < 0.08, "both audio chunks joined in M4A: \(duration)")
        ok("Resume downloads only the missing segment and writes valid M4A")

        let before = try Data(contentsOf: out)
        let skipped = try await BatchProcessor.process(item, settings: settings, client: client) { _, _, _ in }
        try check(!skipped && MockAPI.calls == 3, "existing audio must cause zero API calls")
        try check(try Data(contentsOf: out) == before, "existing output unchanged")
        list = try TextFiles.scan(root)
        try check(list.first { $0.url.lastPathComponent == input.lastPathComponent }?.state == .existing, "existing visible in scan")
        ok("Rerunning preserves existing audio without API requests")

        let changing = root.appendingPathComponent("zmieniany.txt")
        try Data("Pierwotny tekst".utf8).write(to: changing)
        let changedItem = try TextFiles.scan(root).first { $0.url.lastPathComponent == changing.lastPathComponent }!
        try Data("Zmieniony tekst".utf8).write(to: changing)
        do {
            _ = try await BatchProcessor.process(changedItem, settings: settings, client: client) { _, _, _ in }
            throw AppFailure("TEST FAILED: changed file accepted")
        } catch { try check(error.localizedDescription.contains("changed"), "changed text detected") }
        try check(MockAPI.calls == 3, "changed file sends no text")
        try check(settings.cacheID(for: text) != GenerationSettings(voiceID: "Other", modelID: settings.modelID).cacheID(for: text), "cache depends on voice")
        try check(settings.cacheID(for: text) != GenerationSettings(voiceID: settings.voiceID, modelID: "eleven_v3").cacheID(for: text), "cache depends on model")
        ok("Text, voice, and model changes invalidate mismatched cached segments")

        MockAPI.calls = 0
        MockAPI.handler = { req in
            let second = req.url!.query!.contains("next_page_token")
            let json = second ? "{\"voices\":[{\"voice_id\":\"b\",\"name\":\"Beata\"}],\"has_more\":false}" : "{\"voices\":[{\"voice_id\":\"a\",\"name\":\"Anna\"}],\"has_more\":true,\"next_page_token\":\"next\"}"
            return (200, Data(json.utf8))
        }
        let voices = try await client.voices()
        try check(voices.map(\.name) == ["Anna", "Beata"] && MockAPI.calls == 2, "voice pagination")
        ok("Account voices support API pagination")

        MockAPI.handler = { _ in (403, Data("{\"detail\":{\"message\":\"bad test-only-dummy-key\"}}".utf8)) }
        do { _ = try await client.voices(); throw AppFailure("TEST FAILED: 403 accepted") }
        catch { try check(!error.localizedDescription.contains("test-only-dummy-key"), "keys never shown in API errors") }
        ok("Authorization errors redact the API key")

        MockAPI.calls = 0
        MockAPI.handler = { _ in throw AppFailure("TEST FAILED: format conversion must stay offline") }
        for format in [OutputFormat.mp3, .wav] {
            var convertedSettings = settings; convertedSettings.format = format
            let result = try await BatchProcessor.process(item, settings: convertedSettings, client: client) { _, _, _ in }
            try check(result && MockAPI.calls == 0, "local conversion without API")
            let resultFile = try AVAudioFile(forReading: item.output(format))
            let resultDuration = Double(resultFile.length) / resultFile.processingFormat.sampleRate
            try check(abs(resultDuration - duration) < 0.10, "converted duration \(format): \(resultDuration)")
        }
        let wav = try Data(contentsOf: item.output(.wav))
        try check(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF", "real WAV header")
        let wavFile = try AVAudioFile(forReading: item.output(.wav))
        try check(wavFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16, "16-bit PCM")
        try check(try Data(contentsOf: out) == before, "source M4A remains unchanged")
        ok("Local MP3 and WAV export preserves duration and valid PCM without API requests")

        let fragment = root.appendingPathComponent("fragment.mp3")
        try audio.write(to: fragment)
        let mergedMP3 = root.appendingPathComponent("merged.mp3")
        try AudioFiles.merge([fragment, fragment, fragment], to: mergedMP3)
        let mp3File = try AVAudioFile(forReading: mergedMP3)
        try check(abs(Double(mp3File.length) / mp3File.processingFormat.sampleRate - 1.5) < 0.15, "multi-part MP3 duration and header")
        let copiedMP3 = root.appendingPathComponent("copied.mp3")
        try AudioFiles.merge([fragment], to: copiedMP3)
        try check(try Data(contentsOf: copiedMP3) == audio, "single API MP3 kept without re-encoding")
        ok("Multipart MP3 uses the encoder; single MP3 is copied without recompression")

        var expressive = settings
        expressive.expression.enabled = true
        expressive.expression.style = 0.8
        expressive.expression.speed = 0.85
        try check(expressive.cacheID(for: text) != settings.cacheID(for: text), "expression affects resume cache")
        var differentFormat = expressive; differentFormat.format = .wav
        try check(differentFormat.cacheID(for: text) == expressive.cacheID(for: text), "format does not invalidate downloaded audio")
        let params = expressive.voiceParameters!
        try check(params["style"] as? Double == 0.8 && params["speed"] as? Double == 0.85, "v2 expression parameters")
        var v4 = GenerationSettings(voiceID: settings.voiceID, modelID: "eleven_v4", expression: expressive.expression)
        v4.expression.delivery = "whispers"
        try check(v4.voiceParameters?.count == 2 && v4.voiceParameters?["style"] == nil, "v4 only supported controls")
        let v3 = GenerationSettings(voiceID: settings.voiceID, modelID: "eleven_v3", expression: expressive.expression)
        try check(v3.voiceParameters?.count == 1 && v3.voiceParameters?["stability"] as? Double == 0.5, "v3 discrete stability")
        MockAPI.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestData(request)) as! [String: Any]
            try check(body["text"] as? String == "[whispers] Cześć!", "selected emotion tag included")
            try check((body["voice_settings"] as? [String: Any])?.count == 2, "voice settings JSON object")
            return (200, audio)
        }
        _ = try await client.speech(text: "Cześć!", settings: v4, previous: nil, next: nil)
        ok("Expression and delivery tags reach the API with model-dependent parameters")

        let sourceFolder = root.appendingPathComponent("voice-input")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("Zażółć głos.MP3")
        try audio.write(to: source)
        let sourceItem = try AudioSources.scan(sourceFolder, format: .wav).first!
        try check(sourceItem.isAudio && sourceItem.duration > 0 && sourceItem.state == .ready, "audio scan")
        let sts = GenerationSettings(voiceID: settings.voiceID, modelID: "eleven_multilingual_sts_v2", format: .wav, expression: expressive.expression, removeNoise: true)
        MockAPI.calls = 0
        MockAPI.handler = { request in
            try check(request.url!.path == "/v1/speech-to-speech/ExampleVoiceID", "Voice Changer endpoint")
            let type = request.value(forHTTPHeaderField: "Content-Type")!
            try check(type.hasPrefix("multipart/form-data; boundary="), "multipart content type")
            let data = requestData(request)
            let body = String(decoding: data, as: UTF8.self)
            try check(body.contains("name=\"remove_background_noise\"\r\n\r\ntrue"), "noise flag")
            try check(body.contains("name=\"voice_settings\"\r\n\r\n{"), "settings JSON string part")
            try check(body.contains("filename=\"input.mp3\""), "no private filename transmitted")
            try check(data.range(of: audio) != nil, "source audio in multipart")
            return (200, audio)
        }
        let voiceResult = try await BatchProcessor.process(sourceItem, settings: sts, client: client) { _, _, _ in }
        try check(voiceResult && MockAPI.calls == 1, "one STS request")
        try check(sourceItem.output(.wav).deletingLastPathComponent().lastPathComponent == "Voice Changer", "isolated output folder")
        try check(AudioFiles.valid(sourceItem.output(.wav)), "Voice Changer output valid")
        try check(try Data(contentsOf: source) == audio, "input unchanged")
        let repeatSTS = try await BatchProcessor.process(sourceItem, settings: sts, client: client) { _, _, _ in }
        try check(!repeatSTS && MockAPI.calls == 1, "no duplicate STS charge")
        ok("Voice Changer multipart, noise removal, WAV export, and input protection")

        let inline = FileItem(url: root.appendingPathComponent("bez-pliku-txt.txt"), characters: 6, parts: 1,
            fingerprint: TextFiles.digest("Cześć!"), inlineText: "Cześć!")
        MockAPI.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestData(request)) as! [String: Any]
            try check(body["text"] as? String == "Cześć!", "typed text sent directly")
            return (200, audio)
        }
        var inlineSettings = settings; inlineSettings.format = .mp3
        _ = try await BatchProcessor.process(inline, settings: inlineSettings, client: client) { _, _, _ in }
        try check(AudioFiles.valid(inline.output(.mp3)), "typed text output")
        try check(!FileManager.default.fileExists(atPath: inline.url.path), "no unwanted TXT written")
        ok("Typed text generates audio without a TXT file or preview generation")
        print("\(passed) test groups passed. No external API calls. No credits used.")
    }
}

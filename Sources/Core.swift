import Foundation
import CryptoKit
import AVFoundation
import Security

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { L(message) }
    init(_ message: String) { self.message = message }
}

enum TextFiles {
    static func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AppFailure("Choose a regular text file, not a symbolic link.")
        }
        guard (values.fileSize ?? 0) <= 10_000_000 else {
            throw AppFailure("Text files must be smaller than 10 MB.")
        }
        let data = try Data(contentsOf: url)
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1250)
        }
        guard var result = text else { throw AppFailure("Could not read the text. Save the file as UTF-8.") }
        if result.hasPrefix("\u{FEFF}") { result.removeFirst() }
        guard !result.contains("\0") else { throw AppFailure("The file contains binary data. Save the text as UTF-8.") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Count Unicode scalars, not graphemes: API limits must also hold for emoji.
    // Preserve every character while preferring sentence or paragraph boundaries.
    static func chunks(_ text: String, limit: Int = 4000) -> [String] {
        precondition(limit > 0)
        let scalars = Array(text.unicodeScalars)
        var result: [String] = []
        var start = 0
        while start < scalars.count {
            var end = min(start + limit, scalars.count)
            if end < scalars.count {
                let lower = start + max(1, limit / 2)
                var paragraph: Int?, sentence: Int?, space: Int?
                if lower < end {
                    for i in lower..<end {
                        if scalars[i] == "\n" { paragraph = i + 1 }
                        if CharacterSet.whitespacesAndNewlines.contains(scalars[i]) {
                            space = i + 1
                            if i > start, ".!?…".unicodeScalars.contains(scalars[i - 1]) { sentence = i + 1 }
                        }
                    }
                }
                end = paragraph ?? sentence ?? space ?? end
            }
            result.append(String(String.UnicodeScalarView(scalars[start..<end])))
            start = end
        }
        return result
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func output(for input: URL, format: OutputFormat = .m4a) -> URL { input.deletingPathExtension().appendingPathExtension(format.rawValue) }
    static func outputExists(for input: URL) -> Bool {
        let base = input.deletingPathExtension()
        return ["m4a", "mp3", "wav"].contains { FileManager.default.fileExists(atPath: base.appendingPathExtension($0).path) }
    }
    static func scan(_ folder: URL, format: OutputFormat = .m4a) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var seen: Set<String> = []
        return urls.map { url in
            var item = FileItem(url: url)
            let name = output(for: url).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(name).inserted else {
                item.state = .invalid; item.detail = "Duplicate output filename"; return item
            }
            do {
                let text = try read(url)
                item.characters = text.unicodeScalars.count
                item.fingerprint = digest(text)
                item.parts = chunks(text).count
                if text.isEmpty { item.state = .invalid; item.detail = "Empty file" }
                else { item.inspectOutput(format) }
            } catch { item.state = .invalid; item.detail = error.localizedDescription }
            return item
        }
    }
}

enum FileState: String { case ready, working, done, existing, invalid, failed }
struct FileItem: Identifiable {
    let url: URL
    var id: String { url.path }
    var characters = 0
    var parts = 0
    var fingerprint = ""
    var state: FileState = .ready
    var detail = "Ready"
    var inlineText: String?
    var isAudio = false
    var duration: Double = 0
    var destinationFolder: URL?
    var destinationIssue = false
    var outputBase: URL {
        if let destinationFolder { return destinationFolder.appendingPathComponent(url.lastPathComponent).deletingPathExtension() }
        if isAudio {
            return url.deletingLastPathComponent().appendingPathComponent("Voice Changer", isDirectory: true)
                .appendingPathComponent(url.lastPathComponent).deletingPathExtension()
        }
        return url.deletingPathExtension()
    }
    func output(_ format: OutputFormat) -> URL { outputBase.appendingPathExtension(format.rawValue) }
    func existingAudio(except format: OutputFormat) -> URL? {
        OutputFormat.allCases.filter { $0 != format }.map { output($0) }.first { (!isAudio || $0.standardizedFileURL != url.standardizedFileURL) && AudioFiles.valid($0) }
    }
    mutating func inspectOutput(_ format: OutputFormat) {
        if isAudio && output(format).standardizedFileURL == url.standardizedFileURL {
            state = .invalid; destinationIssue = true
            detail = L("Choose a destination different from the source recording."); return
        }
        if FileManager.default.fileExists(atPath: output(format).path) {
            state = .existing; detail = L("%@ already exists — skipping", format.label)
        } else if let other = existingAudio(except: format) {
            detail = L("Convert from %@ · no API request", other.pathExtension.uppercased())
        }
    }
}
enum OutputFormat: String, CaseIterable, Codable {
    case m4a, mp3, wav
    var label: String { rawValue.uppercased() }
}
enum InputMode: String, CaseIterable {
    case folder, text, changer
    var label: String {
        switch self { case .folder: return "Text folder"; case .text: return "Enter text"; case .changer: return "Voice Changer" }
    }
}
struct ExpressionSettings: Codable, Equatable {
    var enabled = false
    var stability = 0.5
    var similarity = 0.75
    var style = 0.0
    var speed = 1.0
    var speakerBoost = true
    var delivery = ""
    func parameters(model: String) -> [String: Any]? {
        guard enabled else { return nil }
        if model == "eleven_v3" {
            return ["stability": (stability * 2).rounded() / 2]
        }
        var p: [String: Any] = ["stability": stability, "similarity_boost": similarity]
        if !model.hasPrefix("eleven_v4") {
            p["style"] = style; p["use_speaker_boost"] = speakerBoost
            if !model.contains("sts") { p["speed"] = speed }
        }
        return p
    }
}
struct GenerationSettings {
    let voiceID: String
    let modelID: String
    var format: OutputFormat = .m4a
    var expression = ExpressionSettings()
    var removeNoise = false
    var languageCode: String?
    var supportedExplicitLanguage = false
    var chunkLimit = 4000
    var supportsStyle: Bool? = nil
    var supportsSpeakerBoost: Bool? = nil
    var voiceParameters: [String: Any]? {
        guard var parameters = expression.parameters(model: modelID) else { return nil }
        if supportsStyle == false { parameters.removeValue(forKey: "style") }
        if supportsSpeakerBoost == false { parameters.removeValue(forKey: "use_speaker_boost") }
        return parameters
    }
    var delivery: String {
        expression.enabled && (modelID == "eleven_v3" || modelID.hasPrefix("eleven_v4")) ? expression.delivery : ""
    }
    func cacheID(for text: String) -> String {
        var suffix = ""
        if let p = voiceParameters, let data = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys]) {
            suffix += "\nsettings:" + String(decoding: data, as: UTF8.self)
        }
        if !delivery.isEmpty { suffix += "\ndelivery:" + delivery }
        if removeNoise { suffix += "\nremove_noise:true" }
        if supportedExplicitLanguage, let languageCode { suffix += "\nlanguage:" + languageCode }
        if chunkLimit != 4000 { suffix += "\nchunk_limit:" + String(chunkLimit) }
        return TextFiles.digest("folder-voice-v1\n\(voiceID)\n\(modelID)\nmp3_44100_128\n\(text)" + suffix)
    }
}

enum AudioSources {
    static let extensions: Set<String> = ["mp3", "wav", "m4a", "flac", "aif", "aiff"]
    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AppFailure("Choose a regular audio file, not a symbolic link.") }
        guard (values.fileSize ?? 0) <= 100_000_000 else { throw AppFailure("Audio files must be smaller than 100 MB.") }
        return try Data(contentsOf: url)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func scan(_ folder: URL, format: OutputFormat) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var names: Set<String> = []
        return urls.map { url in
            var item = FileItem(url: url, parts: 1, isAudio: true)
            do {
                let name = item.outputBase.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                guard names.insert(name).inserted else { throw AppFailure("Duplicate output filename. Rename one of the source files.") }
                let data = try read(url)
                let file = try AVAudioFile(forReading: url)
                item.duration = Double(file.length) / file.processingFormat.sampleRate
                guard item.duration > 0, item.duration <= 300 else { throw AppFailure("Voice Changer recordings must be between 0 and 5 minutes. Split longer recordings first.") }
                item.fingerprint = digest(data)
                item.inspectOutput(format)
            } catch { item.state = .invalid; item.detail = error.localizedDescription }
            return item
        }
    }
}

enum AudioFiles {
    static func valid(_ url: URL) -> Bool {
        guard let audio = try? AVAudioFile(forReading: url) else { return false }
        return audio.length > 0
    }
    static func merge(_ inputs: [URL], to output: URL) throws {
        guard let first = inputs.first else { throw AppFailure("No audio segments are available.") }
        if output.pathExtension == "mp3" {
            if inputs.count == 1 && first.pathExtension.lowercased() == "mp3" {
                try FileManager.default.copyItem(at: first, to: output)
            } else { try encodeMP3(inputs, to: output) }
            return
        }
        let sample = try AVAudioFile(forReading: first)
        let format = sample.processingFormat
        let settings: [String: Any]
        if output.pathExtension == "wav" {
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        } else {
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 128_000]
        }
        let writer = try AVAudioFile(forWriting: output, settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        for input in inputs {
            try Task.checkCancellation()
            let reader = try AVAudioFile(forReading: input)
            guard reader.processingFormat == format else { throw AppFailure("Audio segments have incompatible formats.") }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AppFailure("Could not create an audio buffer.") }
            while reader.framePosition < reader.length {
                try Task.checkCancellation()
                try reader.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
            }
        }
    }
    static func encodeMP3(_ inputs: [URL], to output: URL) throws {
        let sample = try AVAudioFile(forReading: inputs[0], commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = sample.processingFormat
        guard format.channelCount == 1 || format.channelCount == 2, let encoder = lame_init() else {
            throw AppFailure("MP3 encoding supports mono and stereo recordings.")
        }
        defer { lame_close(encoder) }
        lame_set_in_samplerate(encoder, Int32(format.sampleRate))
        lame_set_num_channels(encoder, Int32(format.channelCount))
        lame_set_brate(encoder, 128)
        lame_set_quality(encoder, 2)
        lame_set_write_id3tag_automatic(encoder, 0)
        guard lame_init_params(encoder) == 0 else { throw AppFailure("Could not initialize the MP3 encoder.") }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw AppFailure("Could not write the MP3 file.") }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var encoded = [UInt8](repeating: 0, count: 32768)
        for input in inputs {
            let reader = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.processingFormat == format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AppFailure("MP3 segments have incompatible formats.") }
            while reader.framePosition < reader.length {
                try Task.checkCancellation()
                try reader.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                let right = format.channelCount > 1 ? channels[1] : channels[0]
                let count = lame_encode_buffer_ieee_float(encoder, channels[0], right, Int32(buffer.frameLength), &encoded, Int32(encoded.count))
                guard count >= 0 else { throw AppFailure(L("MP3 encoding failed (%d).", count)) }
                try writer.write(contentsOf: Data(encoded.prefix(Int(count))))
            }
        }
        let count = lame_encode_flush(encoder, &encoded, Int32(encoded.count))
        guard count >= 0 else { throw AppFailure("Could not finalize the MP3 file.") }
        try writer.write(contentsOf: Data(encoded.prefix(Int(count))))
        let tagSize = lame_get_lametag_frame(encoder, &encoded, encoded.count)
        guard tagSize <= encoded.count else { throw AppFailure("Invalid MP3 header.") }
        if tagSize > 0 {
            try writer.seek(toOffset: 0)
            try writer.write(contentsOf: Data(encoded.prefix(tagSize)))
        }
    }
}

enum BatchProcessor {
    static func directory(_ url: URL) throws {
        // Refuse symlinks, including a dangling one, before creating/writing.
        if let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            guard v.isSymbolicLink != true, v.isDirectory == true else { throw AppFailure(L("Cannot access folder: %@", url.lastPathComponent)) }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    static func process(_ item: FileItem, settings: GenerationSettings, client: ElevenClient,
                        progress: @escaping @Sendable (Int, Int, String) async -> Void) async throws -> Bool {
        try Task.checkCancellation()
        let output = item.output(settings.format)
        guard !item.isAudio || output.standardizedFileURL != item.url.standardizedFileURL else { throw AppFailure("Choose a destination different from the source recording.") }
        if FileManager.default.fileExists(atPath: output.path) { return false }
        try directory(output.deletingLastPathComponent())
        if let existing = item.existingAudio(except: settings.format) {
            await progress(0, 1, "Converting locally · no API request")
            return try export([existing], to: output, stagingFolder: output.deletingLastPathComponent())
        }
        let chunks: [String], fingerprint: String
        var sourceAudio: Data?
        if item.isAudio {
            guard ["mp3", "m4a", "flac", "oga", "ogg", "wav"].contains(item.url.pathExtension.lowercased()) else { throw AppFailure("Voice Changer accepts MP3, M4A, FLAC, OGA, OGG or WAV. Export other formats as WAV first.") }
            let data = try AudioSources.read(item.url)
            fingerprint = AudioSources.digest(data)
            sourceAudio = data; chunks = [fingerprint]
        } else {
            let text = try item.inlineText ?? ImportService.readText(item.url)
            guard !text.isEmpty else { throw AppFailure("Enter some text first.") }
            fingerprint = TextFiles.digest(text)
            // Leave room for an optional delivery tag within the API limit.
            chunks = TextFiles.chunks(text, limit: max(1, min(4000, settings.chunkLimit) - (settings.delivery.isEmpty ? 0 : 100)))
        }
        guard fingerprint == item.fingerprint else {
            throw AppFailure("The source changed after import. Import it again before retrying.")
        }
        let cacheRoot = item.url.deletingLastPathComponent().appendingPathComponent(".folder-voice-cache", isDirectory: true)
        try directory(cacheRoot)
        // Preserve v1 cache identities for the unchanged default text settings.
        let identity = item.isAudio ? fingerprint : chunks.joined()
        let cache = cacheRoot.appendingPathComponent(settings.cacheID(for: identity), isDirectory: true)
        try directory(cache)
        var audioURLs: [URL] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let part = cache.appendingPathComponent(String(format: "%05d.mp3", index))
            if let v = try? part.resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true {
                throw AppFailure("Invalid cached audio segment.")
            }
            if AudioFiles.valid(part) {
                await progress(index + 1, chunks.count, L("Resuming segment %d of %d", index + 1, chunks.count))
            } else {
                await progress(index, chunks.count, L("Generating segment %d of %d", index + 1, chunks.count))
                let data: Data
                if let sourceAudio {
                    data = try await client.changeVoice(audio: sourceAudio, extension: item.url.pathExtension, settings: settings)
                } else {
                    data = try await client.speech(text: chunk, settings: settings,
                        previous: index > 0 ? chunks[index - 1] : nil, next: index + 1 < chunks.count ? chunks[index + 1] : nil)
                }
                try data.write(to: part, options: .atomic)
                guard AudioFiles.valid(part) else { throw AppFailure("ElevenLabs returned invalid audio. Generation stopped.") }
                await progress(index + 1, chunks.count, L("Downloaded segment %d of %d", index + 1, chunks.count))
            }
            audioURLs.append(part)
        }
        try Task.checkCancellation()
        await progress(chunks.count, chunks.count, L("Saving %@", output.lastPathComponent))
        let result = try export(audioURLs, to: output, stagingFolder: cache)
        if result { try? FileManager.default.removeItem(at: cache) }
        return result
    }
    static func export(_ inputs: [URL], to output: URL, stagingFolder: URL) throws -> Bool {
        let staging = stagingFolder.appendingPathComponent(".foldervoice-" + UUID().uuidString).appendingPathExtension(output.pathExtension)
        defer { try? FileManager.default.removeItem(at: staging) }
        try AudioFiles.merge(inputs, to: staging)
        guard AudioFiles.valid(staging) else { throw AppFailure("Could not save the recording.") }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { return false }
        try FileManager.default.moveItem(at: staging, to: output)
        return true
    }
}

enum KeyStore {
    static let service = "local.foldervoice.elevenlabs"
    static let account = "api-key"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure(L("Could not save the API key in Keychain (%d).", status)) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure(L("Could not remove the API key from Keychain (%d).", status)) }
    }
}

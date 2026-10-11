import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ImportKind { case text, audio, all }

struct AudioImportInfo {
    let url: URL
    let duration: Double
    let byteCount: Int
    let sampleRate: Double
    let channels: UInt32
}

struct ImportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ key: String) { message = L(key) }
}

enum ImportService {
    static let textExtensions: Set<String> = ["txt", "srt", "vtt"]
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "flac", "aif", "aiff", "ogg", "oga", "opus", "aac"]
    static let textByteLimit = 10_000_000
    static let audioByteLimit = 100_000_000
    static let selectionLimit = 1_000

    /// Expands selected folders by one level without following links or packages.
    /// Unsupported files inside folders are ignored; explicitly selected files are validated.
    static func urls(from selections: [URL], kind: ImportKind = .text) throws -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        let extensions: Set<String>
        switch kind {
        case .text: extensions = textExtensions
        case .audio: extensions = audioExtensions
        case .all: extensions = textExtensions.union(audioExtensions)
        }
        func append(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ImportFailure("Choose a regular file, not a symbolic link.")
            }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            guard result.count < selectionLimit else { throw ImportFailure("Import up to 1,000 files at a time.") }
            result.append(url.standardizedFileURL)
        }
        for selection in selections {
            guard selection.isFileURL else { throw ImportFailure("Import files from this Mac.") }
            let values = try selection.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            guard values.isSymbolicLink != true else { throw ImportFailure("Choose a regular file, not a symbolic link.") }
            if values.isDirectory == true {
                guard values.isPackage != true else { throw ImportFailure("Choose a folder containing text or audio files.") }
                let children = try FileManager.default.contentsOfDirectory(at: selection,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children where extensions.contains(child.pathExtension.lowercased()) {
                    let attributes = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if attributes.isRegularFile == true && attributes.isSymbolicLink != true { try append(child) }
                }
            } else {
                guard extensions.contains(selection.pathExtension.lowercased()) else {
                    throw ImportFailure("This file type is not supported.")
                }
                try append(selection)
            }
        }
        return result
    }

    static func readText(_ url: URL) throws -> String {
        let fileExtension = url.pathExtension.lowercased()
        guard textExtensions.contains(fileExtension) else { throw ImportFailure("Choose a TXT, SRT, or VTT file.") }
        let data = try checkedData(url, limit: textByteLimit, limitMessage: "Text files must be smaller than 10 MB.")
        let decoded: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            decoded = String(data: data, encoding: .utf16)
        } else {
            decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1250)
        }
        guard var text = decoded, !text.contains("\0") else {
            throw ImportFailure("The text could not be read. Save the file as UTF-8.")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if fileExtension == "txt" { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return try subtitleText(text, isVTT: fileExtension == "vtt")
    }

    /// Extracts spoken text in cue order. Subtitle timings are intentionally ignored.
    static func subtitleText(_ source: String, isVTT: Bool) throws -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: try NSRegularExpression(pattern: "\\n[\\t ]*\\n+"))
        let timing = try NSRegularExpression(pattern: "^(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}\\s+-->\\s+(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}(?:\\s+.*)?$")
        var cues: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isVTT && (first == "WEBVTT" || first.hasPrefix("WEBVTT ") || first.hasPrefix("WEBVTT\t") || first == "STYLE" || first == "REGION" || first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t")) { continue }
            // At most one optional cue identifier may precede its timing line.
            guard let index = lines.prefix(2).firstIndex(where: { line in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return timing.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) != nil
            }) else { continue }
            let content = Array(lines.dropFirst(index + 1)).joined(separator: "\n")
            let plain = subtitleMarkup(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { cues.append(plain) }
        }
        guard !cues.isEmpty else { throw ImportFailure("No readable subtitle cues were found.") }
        return cues.joined(separator: "\n\n")
    }

    private static func subtitleMarkup(_ source: String) -> String {
        var result = source
        let patterns = [
            "</?(?:b|i|u|font|ruby|rt)(?:\\s+[^>]*)?>",
            "</?(?:v|lang)(?:\\s+[^>]*)?>",
            "</?c(?:\\.[^>\\s]+)*(?:\\s+[^>]*)?>",
            "<(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}>",
            "\\{\\\\an[1-9]\\}"
        ]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive]) }
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "lrm": "\u{200E}", "rlm": "\u{200F}"]
        // Decode once so literal strings such as &amp;lt; are not decoded twice.
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);") else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let bodyRange = Range(match.range(at: 1), in: result) else { continue }
            let body = String(result[bodyRange])
            let replacement: String?
            if body.hasPrefix("#x"), let code = UInt32(body.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
            else if body.hasPrefix("#"), let code = UInt32(body.dropFirst()), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
            else { replacement = entities[body] }
            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }
        return result
    }

    static func inspectAudio(_ url: URL, maximumDuration: Double? = nil) throws -> AudioImportInfo {
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { throw ImportFailure("Choose a supported audio file.") }
        let values = try regularFileValues(url)
        guard (values.fileSize ?? 0) <= audioByteLimit else { throw ImportFailure("Audio files must be smaller than 100 MB.") }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw ImportFailure("This audio file is empty, damaged, or unsupported by macOS.")
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        if let maximumDuration, duration > maximumDuration { throw ImportFailure("Voice Changer recordings may be up to 5 minutes long.") }
        return AudioImportInfo(url: url, duration: duration, byteCount: values.fileSize ?? 0,
                               sampleRate: file.processingFormat.sampleRate, channels: file.processingFormat.channelCount)
    }

    static func checkedData(_ url: URL, limit: Int, limitMessage: String) throws -> Data {
        let values = try regularFileValues(url)
        guard (values.fileSize ?? 0) <= limit else { throw ImportFailure(limitMessage) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ImportFailure(limitMessage) }
        return data
    }

    private static func regularFileValues(_ url: URL) throws -> URLResourceValues {
        guard url.isFileURL else { throw ImportFailure("Import files from this Mac.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ImportFailure("Choose a regular file, not a symbolic link.") }
        return values
    }

    static func dropURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        guard !providers.isEmpty, providers.count <= selectionLimit else { throw ImportFailure("Import up to 1,000 files at a time.") }
        var urls: [URL] = []
        for provider in providers {
            try Task.checkCancellation()
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { throw ImportFailure("Drop files or folders from Finder.") }
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    if let error { continuation.resume(throwing: error); return }
                    let url: URL?
                    if let value = value as? URL { url = value }
                    else if let value = value as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                    else if let value = value as? String { url = URL(string: value) }
                    else { url = nil }
                    guard let url, url.isFileURL else { continuation.resume(throwing: ImportFailure("Drop files or folders from Finder.")); return }
                    continuation.resume(returning: url)
                }
            }
            try Task.checkCancellation()
            urls.append(url)
        }
        return urls
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let source = self as NSString
        var start = 0
        var result: [String] = []
        for match in expression.matches(in: self, range: NSRange(location: 0, length: source.length)) {
            result.append(source.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = NSMaxRange(match.range)
        }
        result.append(source.substring(from: start))
        return result
    }
}

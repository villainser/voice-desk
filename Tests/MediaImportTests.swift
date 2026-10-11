import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

private struct TestFailure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(message: "Expected input rejection")
}
private func wave(seconds: Double, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    let count = UInt32(sampleCount * 2)
    var data = Data()
    func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    data.append(Data("RIFF".utf8)); word(UInt32(36) + count); data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
    word(UInt16(1)); word(UInt16(1)); word(UInt32(sampleRate)); word(UInt32(sampleRate * 2)); word(UInt16(2)); word(UInt16(16))
    data.append(Data("data".utf8)); word(count); data.append(Data(repeating: 0, count: Int(count)))
    return data
}
@MainActor
private final class PermissionGate {
    var calls = 0
    var waiter: CheckedContinuation<Bool, Never>?
    func request() async -> Bool { calls += 1; return await withCheckedContinuation { waiter = $0 } }
    func resolve(_ value: Bool) { waiter?.resume(returning: value); waiter = nil }
}

@main
struct MediaImportTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceDeskMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Dzień dobry! こんにちは。 Welcome 👩🏽‍💻"
        let txt = root.appendingPathComponent("Multilingual.TXT")
        try text.write(to: txt, atomically: true, encoding: .utf8)
        try check(try ImportService.readText(txt) == text, "Multilingual TXT must stay unchanged")
        let utf16 = root.appendingPathComponent("UTF16.txt")
        try text.write(to: utf16, atomically: true, encoding: .utf16)
        try check(try ImportService.readText(utf16) == text, "UTF16 must be decoded")
        print("PASS 1: UTF-8/UTF-16 and multilingual text")

        let srt = root.appendingPathComponent("Captions.srt")
        try "1\r\n00:00:01,000 --> 00:00:03,200\r\n<b>Dzień dobry!</b>\r\nこんにちは。\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n123\r\nA &amp; B".write(to: srt, atomically: true, encoding: .utf8)
        try check(try ImportService.readText(srt) == "Dzień dobry!\nこんにちは。\n\n123\nA & B", "SRT sequence/timing must be removed without deleting numeric dialogue")
        print("PASS 2: SRT cue parsing and Unicode content")

        let vtt = root.appendingPathComponent("Captions.vtt")
        try "\u{FEFF}WEBVTT\nKind: captions\nLanguage: ja\n\nNOTE ignored note\nDo not speak this.\n\nSTYLE\n::cue { color: lime }\n\nREGION\nid:top\n\nintro\n00:01.000 --> 00:03.000 align:start\n<v Alice><c.green>こんにちは</c></v> &lt;3\n\n00:04.000 --> 00:05.000\n<00:04.300><i>Hello</i> &#x1F600; &amp;lt;\n".write(to: vtt, atomically: true, encoding: .utf8)
        try check(try ImportService.readText(vtt) == "こんにちは <3\n\nHello 😀 &lt;", "VTT metadata and formatting must not become narration")
        try rejects { _ = try ImportService.subtitleText("WEBVTT\n\nNOTE no captions", isVTT: true) }
        print("PASS 3: VTT metadata, cue settings, inline timestamps, entities")

        let ignored = root.appendingPathComponent("Ignore.pdf")
        try Data("not text".utf8).write(to: ignored)
        let hidden = root.appendingPathComponent(".hidden.txt")
        try text.write(to: hidden, atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try text.write(to: nested.appendingPathComponent("Nested.txt"), atomically: true, encoding: .utf8)
        let linked = root.appendingPathComponent("Linked.txt")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: txt)
        let files = try ImportService.urls(from: [root, txt], kind: .text)
        try check(Set(files.map(\.lastPathComponent)) == ["Multilingual.TXT", "UTF16.txt", "Captions.srt", "Captions.vtt"], "Folders must be one level, deduplicated, and ignore hidden/link files")
        try rejects { _ = try ImportService.urls(from: [linked]) }
        try rejects { _ = try ImportService.urls(from: [ignored]) }
        try rejects { _ = try ImportService.urls(from: [URL(string: "https://example.com/test.txt")!]) }
        print("PASS 4: folder/multiple import, deduplication, file type/link validation")

        let huge = root.appendingPathComponent("Huge.txt")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: UInt64(ImportService.textByteLimit + 1)); try hugeHandle.close()
        try rejects { _ = try ImportService.readText(huge) }
        let binary = root.appendingPathComponent("Binary.txt")
        try Data([0, 1, 2]).write(to: binary)
        try rejects { _ = try ImportService.readText(binary) }
        print("PASS 5: text byte limit and binary rejection")

        let dataProvider = NSItemProvider()
        dataProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { callback in
            callback(txt.dataRepresentation, nil); return nil
        }
        let urlProvider = NSItemProvider(object: vtt as NSURL)
        let dropped = try await ImportService.dropURLs(from: [dataProvider, urlProvider])
        try check(dropped.map(\.lastPathComponent) == ["Multilingual.TXT", "Captions.vtt"], "Both Finder URL representations must work")
        do { _ = try await ImportService.dropURLs(from: [NSItemProvider(object: "plain text" as NSString)]); throw TestFailure(message: "Expected text drop rejection") }
        catch is ImportFailure { }
        print("PASS 6: drag/drop URL payloads and unsupported drop rejection")

        let audio = root.appendingPathComponent("Silence.wav")
        try wave(seconds: 1).write(to: audio)
        let info = try ImportService.inspectAudio(audio, maximumDuration: 300)
        try check(info.duration == 1 && info.sampleRate == 16000 && info.channels == 1, "Audio metadata must be read from actual frames")
        let longAudio = root.appendingPathComponent("TooLong.wav")
        try wave(seconds: 301).write(to: longAudio)
        try rejects { _ = try ImportService.inspectAudio(longAudio, maximumDuration: 300) }
        let badAudio = root.appendingPathComponent("Bad.wav")
        try Data("not audio".utf8).write(to: badAudio)
        try rejects { _ = try ImportService.inspectAudio(badAudio) }
        let largeAudio = root.appendingPathComponent("Huge.wav")
        FileManager.default.createFile(atPath: largeAudio.path, contents: nil)
        let audioHandle = try FileHandle(forWritingTo: largeAudio)
        try audioHandle.truncate(atOffset: UInt64(ImportService.audioByteLimit + 1)); try audioHandle.close()
        try rejects { _ = try ImportService.inspectAudio(largeAudio) }
        print("PASS 7: WAV metadata, 5-minute VC cap, invalid audio, 100 MB cap")

        let player = AudioPlayerModel()
        player.load(audio)
        try check(player.sourceURL == audio && abs(player.duration - 1) < 0.001 && !player.isPlaying, "Load must expose duration without autoplay")
        player.seek(to: 0.5); try check(player.currentTime == 0.5, "Seek must update playhead")
        player.seek(to: 4); try check(player.currentTime == 1, "Seek must clamp to duration")
        player.stop(); try check(player.currentTime == 0 && !player.isPlaying, "Stop must reset playhead")
        player.clear(); try check(player.sourceURL == nil && player.duration == 0, "Clear must release source")
        player.load(URL(string: "http://example.com/preview.mp3")!)
        try check(player.error != nil && player.sourceURL == nil, "Unsafe URL must not load")
        player.load(badAudio); try check(player.error != nil, "Damaged audio must fail gracefully")
        print("PASS 8: local player load/seek/stop/clear and invalid inputs (no audible playback)")

        var permissions = 0
        let recordingFolder = root.appendingPathComponent("Recordings", isDirectory: true)
        let deniedRecorder = MicrophoneRecorder(recordingDirectory: recordingFolder, permissionRequester: { permissions += 1; return false }, deviceProvider: { [AudioInputDevice(id: "builtin", name: "Built-in")] })
        try check(permissions == 0, "Constructing recorder must not request microphone")
        await deniedRecorder.start()
        try check(permissions == 1 && !deniedRecorder.isRecording && deniedRecorder.error != nil, "Denied microphone must have a recoverable error")
        try check(!FileManager.default.fileExists(atPath: recordingFolder.path), "Denied permission must not create a recording")
        print("PASS 9: explicit-only microphone permission and denial (mocked)")

        let gate = PermissionGate()
        let cancelledRecorder = MicrophoneRecorder(recordingDirectory: recordingFolder, permissionRequester: { await gate.request() }, deviceProvider: { [AudioInputDevice(id: "builtin", name: "Built-in")] })
        let pending = Task { await cancelledRecorder.start() }
        while gate.waiter == nil { await Task.yield() }
        await cancelledRecorder.start()
        try check(gate.calls == 1, "Duplicate Start during permission must be ignored")
        cancelledRecorder.cancel()
        gate.resolve(true)
        await pending.value
        try check(!cancelledRecorder.isRecording && !cancelledRecorder.isRequestingPermission && cancelledRecorder.recordingURL == nil, "Accepting permission after cancellation must not record")
        try check(!FileManager.default.fileExists(atPath: recordingFolder.path), "Cancelled request must not create a recording")
        try check(FileManager.default.fileExists(atPath: audio.path), "Cancelling must never delete imported audio")
        print("PASS 10: cancellation and duplicate-start guard while permission is pending (mocked)")
        print("All 10 media/import groups passed. Live microphone and speaker playback were not exercised.")
    }
}

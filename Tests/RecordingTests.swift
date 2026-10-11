import Foundation
import AVFoundation

private struct RecordingFailure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw RecordingFailure(message: message) }
}
private func wave() -> Data {
    var data = Data()
    func word<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    let size: UInt32 = 32000
    data.append(Data("RIFF".utf8)); word(UInt32(36) + size); data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
    word(UInt16(1)); word(UInt16(1)); word(UInt32(16000)); word(UInt32(32000)); word(UInt16(2)); word(UInt16(16))
    data.append(Data("data".utf8)); word(size); data.append(Data(repeating: 0, count: Int(size)))
    return data
}
private final class CaptureStub: MicrophoneCaptureBackend {
    var deviceID: String?
    var url: URL?
    var starts = 0, stops = 0
    var started: (() -> Void)?
    var progress: ((Double, Double) -> Void)?
    var finished: ((Error?) -> Void)?
    func start(deviceID: String, url: URL, durationLimit: Double, started: @escaping () -> Void,
               progress: @escaping (Double, Double) -> Void, finished: @escaping (Error?) -> Void) {
        self.deviceID = deviceID; self.url = url; self.started = started; self.progress = progress; self.finished = finished; starts += 1
    }
    func stop() { stops += 1 }
    func complete() throws { try wave().write(to: url!); finished?(nil) }
}
@MainActor private func settle() async { for _ in 0..<20 { await Task.yield() } }
@main struct RecordingTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceDeskRecordingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtin = AudioInputDevice(id: "builtin-uid", name: "Built-in Microphone")
        let usb = AudioInputDevice(id: "usb-uid", name: "USB Microphone")
        var available = [builtin, usb], permissions = 0, delivered: [URL] = []
        let capture = CaptureStub()
        let recorder = MicrophoneRecorder(recordingDirectory: root, permissionRequester: { permissions += 1; return true }, deviceProvider: { available }, backendFactory: { capture })
        recorder.onFinished = { delivered.append($0) }
        recorder.refreshDevices()
        try check(recorder.devices == [builtin, usb] && permissions == 0 && capture.starts == 0, "device discovery must not request permission or record")
        recorder.selectedDeviceID = usb.id
        await recorder.start()
        try check(capture.deviceID == usb.id && permissions == 1 && recorder.isRequestingPermission, "route the explicit external UID to the capture session")
        await recorder.start()
        try check(capture.starts == 1, "preparation must reject a duplicate start")
        capture.started?(); await settle()
        capture.progress?(1, 0.5); await settle()
        try check(recorder.isRecording && recorder.elapsed == 1 && recorder.level == 0.5, "started callback and meter must reach UI state")
        recorder.stop()
        try check(recorder.isFinishing && delivered.isEmpty && recorder.recordingURL == nil && capture.stops == 1, "stop must wait for WAV finalization")
        try capture.complete(); await settle()
        try check(!recorder.isBusy && delivered.count == 1 && recorder.recordingURL == capture.url, "only a finalized valid recording is delivered")
        print("PASS 1: external microphone routing, explicit permission, duplicate start, meter, and async file finalization")

        recorder.selectedDeviceID = builtin.id
        await recorder.start(); capture.started?(); await settle()
        try check(capture.deviceID == builtin.id && recorder.isRecording, "built-in microphone must use its own UID")
        try capture.complete(); await settle()
        try check(delivered.count == 2 && !recorder.isBusy, "automatic duration-limit completion must deliver a sample without pressing Stop")
        print("PASS 2: built-in selection and automatic completion")

        recorder.selectedDeviceID = usb.id
        await recorder.start(); capture.started?(); await settle()
        available = [builtin]; recorder.refreshDevices()
        try check(recorder.selectedDeviceID == usb.id && !recorder.selectedInputAvailable && recorder.isFinishing, "disconnect must stop without silently switching to a different mic")
        try capture.complete(); await settle()
        try check(delivered.count == 3 && recorder.error != nil, "disconnect keeps the completed part with a warning")
        let calls = permissions
        await recorder.start()
        try check(permissions == calls && !recorder.isBusy, "unavailable selection must fail before permission or capture")
        print("PASS 3: hot-unplug, preserved partial recording, and missing-input rejection")

        recorder.selectedDeviceID = ""
        await recorder.start(); capture.started?(); await settle()
        try check(capture.deviceID == "", "system-default input remains an explicit routing option")
        let cancelledURL = capture.url!
        recorder.cancel(); try capture.complete(); await settle()
        try check(!FileManager.default.fileExists(atPath: cancelledURL.path) && delivered.count == 3 && !recorder.isBusy, "cancel discards only the current file after finalization")
        try check(delivered.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "cancelling must keep previous samples")
        print("PASS 4: default input routing and cancellation preserves previous samples")

        available = []
        recorder.refreshDevices()
        await recorder.start()
        try check(!recorder.isBusy && !recorder.selectedInputAvailable, "no input must remain idle")
        available = [builtin]; recorder.refreshDevices()
        await recorder.start(); capture.started?(); await settle()
        capture.finished?(ImportFailure("The selected microphone is unavailable. Connect it or choose another input.")); await settle()
        try check(delivered.count == 3 && !recorder.isBusy && recorder.error == L("The selected microphone is unavailable. Connect it or choose another input."), "failed capture must retain its actionable device error and not be offered for cloning")
        print("PASS 5: no device and empty/failed recording")
        print("All 5 recording groups passed with fake devices and synthetic WAV; no real microphone or API used.")
    }
}

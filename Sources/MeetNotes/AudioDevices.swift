import AVFoundation

enum AudioDevices {
    /// Every CoreAudio input device, including BlackHole and aggregate devices.
    static func inputs() -> [AVCaptureDevice] {
        var seen = Set<String>()
        var out: [AVCaptureDevice] = []
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        for d in discovered + AVCaptureDevice.devices(for: .audio) where !seen.contains(d.uniqueID) {
            seen.insert(d.uniqueID)
            out.append(d)
        }
        return out.sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
    }

    /// The virtual device that carries Meet's output (the other participants).
    static func preferredSystem(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        for h in ["blackhole", "meetcapture", "aggregate", "loopback"] {
            if let d = devices.first(where: { $0.localizedName.lowercased().contains(h) }) { return d }
        }
        return nil
    }

    /// The physical microphone (you).
    static func preferredMic(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let d = AVCaptureDevice.default(for: .audio), !isVirtual(d) { return d }
        return devices.first { !isVirtual($0) }
    }

    static func isVirtual(_ d: AVCaptureDevice) -> Bool {
        let n = d.localizedName.lowercased()
        return ["blackhole", "aggregate", "loopback", "soundflower", "meetcapture"].contains { n.contains($0) }
    }
}

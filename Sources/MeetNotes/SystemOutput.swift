import CoreAudio
import Foundation

/// Routes system audio through BlackHole without Audio MIDI Setup: creates a stacked (multi-output) aggregate
/// device of {current speakers, BlackHole} and makes it the default output. Undo restores the previous output.
enum SystemOutput {
    static let aggregateUID = "com.alanbishop.meetnotes.multiout"
    static let aggregateName = "MeetNotes Output"
    static let previousKey = "previousOutputUID"

    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        case noBlackHole, noDefault
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let s): return "\(what) failed (CoreAudio \(s))"
            case .noBlackHole: return "BlackHole 2ch not found. Install it: brew install --cask blackhole-2ch, then reboot."
            case .noDefault: return "No default output device."
            }
        }
    }

    // MARK: property plumbing

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func getUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(sel)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var cf: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        guard st == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func defaultOutput() -> AudioDeviceID? {
        getUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice).map { AudioDeviceID($0) }
    }

    static func uid(_ dev: AudioDeviceID) -> String? { getString(dev, kAudioDevicePropertyDeviceUID) }
    static func name(_ dev: AudioDeviceID) -> String? { getString(dev, kAudioObjectPropertyName) }

    static func device(forUID uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        return st == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func blackHole() -> AudioDeviceID? {
        allDevices().first { (name($0) ?? "").lowercased().contains("blackhole") }
    }

    /// Sub-device UIDs of an aggregate device; empty for a plain device.
    static func subDevices(_ dev: AudioDeviceID) -> [String] {
        var addr = address(kAudioAggregateDevicePropertyFullSubDeviceList)
        var cf: Unmanaged<CFArray>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        guard st == noErr, let arr = cf?.takeRetainedValue() as? [String] else { return [] }
        return arr
    }

    static func setDefaultOutput(_ dev: AudioDeviceID) throws {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var v = dev
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &v)
        guard st == noErr else { throw Failure.coreAudio("set default output", st) }
    }

    // MARK: status

    struct Status {
        let outputName: String
        let blackHoleInstalled: Bool
        let routed: Bool      // BlackHole is hearing system audio
    }

    static func status() -> Status {
        let bh = blackHole()
        guard let out = defaultOutput() else {
            return Status(outputName: "none", blackHoleInstalled: bh != nil, routed: false)
        }
        let bhUID = bh.flatMap(uid)
        let outUID = uid(out)
        let routed = bhUID != nil && (outUID == bhUID || subDevices(out).contains(bhUID!))
        return Status(outputName: name(out) ?? "unknown", blackHoleInstalled: bh != nil, routed: routed)
    }

    // MARK: route / restore

    static func route() throws {
        guard let bh = blackHole(), let bhUID = uid(bh) else { throw Failure.noBlackHole }
        guard let current = defaultOutput(), let currentUID = uid(current) else { throw Failure.noDefault }
        if status().routed { return }

        if let existing = device(forUID: aggregateUID) {
            // stale composition (different speakers than last time) → rebuild
            if subDevices(existing) != [currentUID, bhUID] {
                AudioHardwareDestroyAggregateDevice(existing)
            } else {
                UserDefaults.standard.set(currentUID, forKey: previousKey)
                try setDefaultOutput(existing)
                return
            }
        }

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: currentUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: currentUID],
                [kAudioSubDeviceUIDKey: bhUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var agg = AudioDeviceID(0)
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard st == noErr else { throw Failure.coreAudio("create multi-output device", st) }
        UserDefaults.standard.set(currentUID, forKey: previousKey)
        try setDefaultOutput(agg)
    }

    static func restore() throws {
        let prevUID = UserDefaults.standard.string(forKey: previousKey)
        var target = prevUID.flatMap(device(forUID:))
        if target == nil, let out = defaultOutput(), uid(out) == aggregateUID {
            // fall back to the aggregate's own main sub-device
            target = subDevices(out).first.flatMap(device(forUID:))
        }
        guard let t = target else { throw Failure.noDefault }
        try setDefaultOutput(t)
        if let agg = device(forUID: aggregateUID) { AudioHardwareDestroyAggregateDevice(agg) }
    }
}

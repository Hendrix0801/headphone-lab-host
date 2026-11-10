import CoreAudio
import Foundation

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let manufacturer: String
    let currentSampleRate: Double
    let availableSampleRates: [Double]
    let bufferFrameSize: UInt32
}

enum AudioDeviceError: Error, LocalizedError {
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status):
            return "CoreAudio 错误 (OSStatus \(status))"
        }
    }
}

final class AudioDevices {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func defaultInputDeviceID() -> AudioDeviceID {
        return defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID {
        return defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    static func uid(_ id: AudioDeviceID) -> String? {
        return deviceUID(id)
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ref)
        guard status == noErr else { return nil }
        return ref as String
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        return allDevices().filter { streamCount($0.id, scope: kAudioDevicePropertyScopeInput) > 0 }
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        return allDevices().filter { streamCount($0.id, scope: kAudioDevicePropertyScopeOutput) > 0 }
    }

    static func info(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
        let manufacturer = stringProperty(id, selector: kAudioObjectPropertyManufacturer) ?? ""
        return AudioDeviceInfo(
            id: id,
            name: name,
            manufacturer: manufacturer,
            currentSampleRate: sampleRate(id),
            availableSampleRates: availableSampleRates(id),
            bufferFrameSize: bufferFrameSize(id))
    }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = id
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
        return status == noErr
    }

    @discardableResult
    static func setSampleRate(_ id: AudioDeviceID, _ rate: Double) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &value)
        if status != noErr { throw AudioDeviceError.coreAudio(status) }
        return abs(sampleRate(id) - rate) < 0.5
    }

    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = frames
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func bufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    // MARK: - Private

    private static func allDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { info($0) }
    }

    private static func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ref)
        guard status == noErr else { return nil }
        return ref as String
    }

    private static func sampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : 0
    }

    private static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        guard count > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges
            .filter { $0.mMinimum == $0.mMaximum }
            .map { $0.mMinimum }
            .sorted()
    }
}

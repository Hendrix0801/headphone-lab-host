import CoreAudio
import Foundation

/// 我们自己的 AudioServerPlugIn 驱动（HeadphoneLab.driver）暴露的虚拟设备。
/// 设备在 coreaudiod 进程内完成 loopback（写侧混音进环形缓冲，读侧读回），
/// app 把它的输入端作为声音来源。
enum DriverSink {

    static let deviceUIDPrefix = "local.headphonelab.driver"
    static let defaultDeviceName = "Headphone Lab"
    static let nameSuffix = " (Headphone Lab)"

    /// 自定义属性：动态设备名（写后经 host PropertiesChanged 通知 HAL 刷新）。
    private static let namePropertySelector: AudioObjectPropertySelector = {
        var value: UInt32 = 0
        for c in "hpln".utf8 { value = (value << 8) | UInt32(c) }
        return value
    }()

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// 自研驱动开关：默认启用（shm 推送版）；设 disableExperimentalDriver=1 可强制回退 helper 方案。
    static let enabled = ProcessInfo.processInfo.environment["disableExperimentalDriver"] != "1"

    static func deviceID() -> AudioDeviceID? {
        guard enabled else { return nil }
        for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
            let system = AudioObjectID(kAudioObjectSystemObject)
            var list = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr else { continue }
            let count = Int(size) / MemoryLayout<AudioDeviceID>.size
            guard count > 0 else { continue }
            var ids = [AudioDeviceID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { continue }
            for id in ids {
                guard let uid = AudioDevices.deviceUID(id), uid.hasPrefix(deviceUIDPrefix) else { continue }
                // 确认该设备有所需方向的流
                var streamAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain)
                var streamSize: UInt32 = 0
                AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize)
                if streamSize > 0 { return id }
            }
        }
        return nil
    }

    static func isDriverDevice(_ id: AudioDeviceID) -> Bool {
        // 实验驱动禁用时，视其设备为普通第三方虚拟设备（本 app 不接管、不理会）。
        guard enabled else { return false }
        guard let uid = AudioDevices.deviceUID(id) else { return false }
        return uid.hasPrefix(deviceUIDPrefix)
    }

    @discardableResult
    static func setName(_ name: String) -> Bool {
        guard let id = deviceID() else { return false }
        var value = name as CFString
        var addr = address(namePropertySelector)
        let status = AudioObjectSetPropertyData(
            id, &addr, 0, nil,
            UInt32(MemoryLayout<CFString>.size), &value)
        return status == noErr
    }

    static func currentName() -> String? {
        guard let id = deviceID() else { return nil }
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = address(namePropertySelector)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value as String
    }

    /// 从设备名还原背后的真实输出设备（"外置耳机 (Headphone Lab)" → "外置耳机"）。
    static func resolveRealOutput() -> AudioDeviceID {
        let currentName = DriverSink.currentName() ?? ""
        let base = currentName.hasSuffix(nameSuffix)
            ? String(currentName.dropLast(nameSuffix.count))
            : ""
        if !base.isEmpty {
            if let match = AudioDevices.outputDevices().first(where: {
                !isDriverDevice($0.id) && $0.name == base
            }) {
                return match.id
            }
        }
        return AudioDevices.outputDevices().first(where: { !isDriverDevice($0.id) })?.id ?? 0
    }
}

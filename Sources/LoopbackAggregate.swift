import CoreAudio
import Foundation

/// 自动创建并维护一个「<真实输出设备名> (Headphone Lab)」聚合设备：
/// 真实输出 + BlackHole 堆叠（同样的数据同时喂给两者）。
/// 系统输出选它，就能一边听原设备出声，一边把系统声音送进 BlackHole 给插件处理。
final class LoopbackAggregate {

    static let shared = LoopbackAggregate()
    static let aggregateUID = "local.headphonelab.loopback"

    private(set) var deviceID: AudioDeviceID = 0
    private(set) var realOutputDeviceID: AudioDeviceID = 0

    var isInstalled: Bool { deviceID != 0 }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), &qualifier,
            &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    func destroy() {
        guard deviceID != 0 else { return }
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        NSLog("[host] aggregate destroyed status=%d", status)
        deviceID = 0
    }

    /// 清理上一次运行遗留的同名聚合设备。
    func cleanupStale() {
        if let existing = deviceID(forUID: Self.aggregateUID) {
            AudioHardwareDestroyAggregateDevice(existing)
        }
        deviceID = 0
    }

    /// 以 realOutput 为模板重建聚合设备，返回显示名。
    @discardableResult
    func recreate(realOutput: AudioDeviceID) -> String? {
        destroy()

        guard Self.sinkDeviceID != 0,
              let sinkUID = AudioDevices.deviceUID(Self.sinkDeviceID),
              let outputUID = AudioDevices.deviceUID(realOutput)
        else { return nil }

        let baseName = AudioDevices.info(realOutput)?.name ?? "输出设备"
        let name = "\(baseName) (Headphone Lab)"

        // 纯 sink：系统声音只能经 虚拟声卡 → 本 app → 插件 → 真实设备 一条路径，
        // 避免干声直通与处理声在真实设备上叠加。
        let subDevices: [[String: Any]] = [
            ["uid": sinkUID],
        ]
        let description: [String: Any] = [
            "name": name as CFString,
            "uid": Self.aggregateUID as CFString,
            "subdevices": subDevices,
            "master": sinkUID,
            // 注意：单设备聚合 stacked=1 在 macOS 27 上静音（实测），
            // 单设备必须 stacked=0。
            "stacked": subDevices.count > 1 ? 1 : 0,
            "private": 0,
        ]

        var newID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr else {
            NSLog("[host] aggregate create failed status=%d", status)
            return nil
        }
        deviceID = newID
        realOutputDeviceID = realOutput
        NSLog("[host] aggregate created: %@ (%u)", name, newID)
        return name
    }

    /// 上次异常退出后，系统默认输出可能仍指向遗留的聚合设备。
    /// 从它的名字还原真实设备，销毁遗留设备后重建。
    @discardableResult
    func adoptOrRecreate() -> String? {
        guard let orphanID = deviceID(forUID: Self.aggregateUID) else { return nil }
        let suffix = " (Headphone Lab)"
        let orphanName = AudioDevices.info(orphanID)?.name ?? ""
        let baseName = orphanName.hasSuffix(suffix) ? String(orphanName.dropLast(suffix.count)) : ""
        AudioHardwareDestroyAggregateDevice(orphanID)

        var real = AudioDevices.outputDevices().first {
            AudioDevices.deviceUID($0.id) != Self.aggregateUID && $0.name == baseName
        }?.id ?? 0
        if real == 0 {
            real = AudioDevices.outputDevices().first {
                AudioDevices.deviceUID($0.id) != Self.aggregateUID
            }?.id ?? 0
        }
        guard real != 0 else { return nil }
        return recreate(realOutput: real)
    }

    /// 如果系统默认输出正指向我们的聚合设备，把它切回真实设备。
    func restoreSystemOutputIfNeeded() {
        let current = AudioDevices.defaultOutputDeviceID()
        guard AudioDevices.deviceUID(current) == Self.aggregateUID else { return }
        let target = realOutputDeviceID != 0 ? realOutputDeviceID : AudioDevices.defaultOutputDeviceID()
        guard target != 0, target != current else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = target
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    // 回环设备候选：优先 BlackHole，其次已加载的 Oray 虚拟声卡。
    // 需要一个「系统可输出到 + 本 app 可从其输入读取」的虚拟设备。
    static let sinkDeviceID: AudioDeviceID = {
        // 直连采集在 macOS 27 上对 BlackHole 失效（驱动 IO 不启动），Oray 验证可用，排前面。
        let candidates = ["OrayVirtualAudioDevice", "BlackHole"]
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return 0 }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return 0 }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &ids) == noErr else { return 0 }
        for prefix in candidates {
            for id in ids {
                guard let uid = AudioDevices.deviceUID(id) else { continue }
                if uid.hasPrefix(prefix) { return id }
            }
        }
        return 0
    }()

    static let blackHoleDeviceID = sinkDeviceID
}

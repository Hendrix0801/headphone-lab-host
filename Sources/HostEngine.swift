import AVFoundation
import AudioToolbox
import Foundation

struct AudioUnitCocoaUIInfo {
    var mCocoaAUViewBundlePath: CFString
    var mCocoaAUViewClassName: CFString
}

enum HostError: Error, LocalizedError {
    case componentNotFound
    case instantiationFailed(String)
    case audioUnitPointerUnavailable
    case noInputDevice
    case graphFailed(String)

    var errorDescription: String? {
        switch self {
        case .componentNotFound:
            return "未找到 HEADPHONE LAB 音频单元，请确认插件已安装到 /Library/Audio/Plug-Ins/Components"
        case .instantiationFailed(let message):
            return "插件实例化失败：\(message)"
        case .audioUnitPointerUnavailable:
            return "无法获取 AudioUnit 句柄"
        case .noInputDevice:
            return "没有可用的音频输入设备"
        case .graphFailed(let message):
            return "音频图构建失败：\(message)"
        }
    }
}

final class HostEngine {

    static let shared = HostEngine()

    let componentDescription: AudioComponentDescription = {
        func fourCC(_ s: String) -> UInt32 {
            var r: UInt32 = 0
            for c in s.utf8 { r = (r << 8) | UInt32(c) }
            return r
        }
        return AudioComponentDescription(
            componentType: fourCC("aufx"),
            componentSubType: fourCC("BdHL"),
            componentManufacturer: fourCC("Beyd"),
            componentFlags: 0,
            componentFlagsMask: 0)
    }()

    private var engineStorage = AVAudioEngine()

    var engine: AVAudioEngine { engineStorage }

    /// macOS 的音频会话一旦显式切换过输出设备，就无法再切回系统默认
    /// （对纯输出设备会返回 -10851）。切换设备时直接重建引擎对象最干净。
    func recreateEngine() {
        if engineStorage.isRunning { engineStorage.stop() }
        engineStorage = AVAudioEngine()
        graphAttached = false
    }

    private(set) var avUnit: AVAudioUnit?
    private(set) var rawUnit: AudioUnit?
    private var graphAttached = false

    var isRunning: Bool { engine.isRunning }

    var outputSampleRate: Double {
        engine.outputNode.inputFormat(forBus: 0).sampleRate
    }

    var inputSampleRate: Double {
        shmReader?.sampleRate ?? 0
    }

    // MARK: - Plugin lifecycle

    func instantiatePlugin(completion: @escaping (Error?) -> Void) {
        var desc = componentDescription
        guard AudioComponentFindNext(nil, &desc) != nil else {
            completion(HostError.componentNotFound)
            return
        }
        AVAudioUnit.instantiate(with: componentDescription, options: [.loadInProcess]) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let unit else {
                    completion(HostError.instantiationFailed(error?.localizedDescription ?? "未知错误"))
                    return
                }
                self.avUnit = unit
                let auu = unit.wrappedAUAudioUnit
                self.rawUnit = HostEngine.rawAudioUnitPointer(of: auu)
                guard self.rawUnit != nil else {
                    completion(HostError.audioUnitPointerUnavailable)
                    return
                }
                completion(nil)
            }
        }
    }

    // MARK: - Graph

    // MARK: - Input level meter

    private let meterLock = NSLock()
    private var meterSum: Double = 0
    private var meterCount: Double = 0

    private func installInputMeter() {
        let format = mixerIn.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        mixerIn.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            var sum = 0.0
            var count = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    sum += Double(channels[c][i] * channels[c][i])
                    count += 1
                }
            }
            self.meterLock.lock()
            self.meterSum += sum
            self.meterCount += Double(count)
            self.meterLock.unlock()
        }
    }

    /// 返回自上次调用以来的输入 RMS（0..1）。
    func consumeInputLevel() -> Float {
        meterLock.lock()
        let rms = meterCount > 0 ? Float((meterSum / meterCount).squareRoot()) : 0
        meterSum = 0
        meterCount = 0
        meterLock.unlock()
        return min(1, rms)
    }

    private let mixerIn = AVAudioMixerNode()
    private let mixerOut = AVAudioMixerNode()

    /// 共享内存采集读取器（由采集助手进程喂数据）。
    var shmReader: ShmCaptureReader?

    func buildGraph() throws {
        guard let avUnit else { throw HostError.graphFailed("插件尚未加载") }
        guard let reader = shmReader else { throw HostError.graphFailed("采集未就绪") }

        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        if graphAttached {
            engine.detach(avUnit)
            engine.detach(mixerIn)
            engine.detach(mixerOut)
            if let source = sourceNode {
                engine.detach(source)
                sourceNode = nil
            }
            graphAttached = false
        }
        engine.reset()

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0 else {
            throw HostError.graphFailed("输出设备不可用")
        }

        // 源：共享内存（采集助手从 BlackHole 写入），立体声。
        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: reader.sampleRate,
            channels: 2)
        else { throw HostError.graphFailed("无法构建源格式") }

        let channels = 2
        let source = AVAudioSourceNode { [weak self] isSilence, _, frameCount, outputData -> OSStatus in
            guard let self, let reader = self.shmReader else {
                isSilence.pointee = true
                return noErr
            }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let n = min(Int(frameCount), reader.availableFrames)
            if n <= 0 {
                isSilence.pointee = true
                return noErr
            }
            let interleaved = self.meterScratch.bindMemory(to: Float32.self, capacity: Int(frameCount) * channels)
            let got = reader.read(frames: n, to: interleaved)
            guard got > 0 else { isSilence.pointee = true; return noErr }
            var peak: Float = 0
            for i in 0..<(got * channels) {
                let v = abs(interleaved[i])
                if v > peak { peak = v }
            }
            self.debugPeak = max(self.debugPeak, peak)
            for ch in 0..<channels where ch < abl.count {
                guard let dst = abl[ch].mData?.assumingMemoryBound(to: Float32.self) else { continue }
                for f in 0..<got {
                    dst[f] = interleaved[f * channels + ch]
                }
            }
            if got < frameCount {
                for ch in 0..<channels where ch < abl.count {
                    guard let dst = abl[ch].mData?.assumingMemoryBound(to: Float32.self) else { continue }
                    for f in got..<Int(frameCount) { dst[f] = 0 }
                }
            }
            isSilence.pointee = false
            return noErr
        }
        sourceNode = source

        let auFormat = sourceFormat

        engine.attach(source)
        engine.attach(mixerIn)
        engine.attach(mixerOut)
        engine.attach(avUnit)
        graphAttached = true
        engine.connect(source, to: mixerIn, format: sourceFormat)
        engine.connect(mixerIn, to: avUnit, format: auFormat)
        engine.connect(avUnit, to: mixerOut, format: auFormat)
        engine.connect(mixerOut, to: engine.outputNode, format: outputFormat)
        installInputMeter()
    }

    private var sourceNode: AVAudioSourceNode?
    var debugPeak: Float = 0
    private let meterScratch = UnsafeMutableRawPointer.allocate(byteCount: 4096 * 2 * MemoryLayout<Float32>.size, alignment: 16)

    func start() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// 引擎启动后重申输出设备绑定。
    /// macOS 的音频会话在引擎启动时可能把输出静默改回默认设备，
    /// 启动后再设置一次可确保绑定生效。
    func reassertOutputDevice(_ id: AudioDeviceID) {
        guard let au = engine.outputNode.audioUnit else { return }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getStatus = AudioUnitGetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &current, &size)
        NSLog("[host] post-start output check: current=%u want=%u getStatus=%d", current, id, getStatus)
        if getStatus != noErr || current != id {
            var deviceID = id
            let setStatus = AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            NSLog("[host] post-start rebind output -> %u status=%d", id, setStatus)
        }
    }

    /// 输出音量（0..1），作用于图末端的混音节点。
    var outputVolume: Float {
        get { mixerOut.outputVolume }
        set { mixerOut.outputVolume = newValue }
    }

    func stop() {
        if engine.isRunning { engine.pause() }
    }

    func restart() throws {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        try buildGraph()
        if wasRunning { try engine.start() }
    }

    // MARK: - Device switching

    private func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, &size)
        return status == noErr ? deviceID : nil
    }

    private func setCurrentDevice(_ id: AudioDeviceID, of unit: AudioUnit, label: String) throws {
        if let current = currentDevice(of: unit), current == id {
            NSLog("[host] %@ device already current (%u), skipping", label, id)
            return
        }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        NSLog("[host] set %@ device -> %u status=%d", label, id, status)
        if status != noErr { throw AudioDeviceError.coreAudio(status) }
    }

    func setInputDevice(_ id: AudioDeviceID) throws {
        guard let au = engine.inputNode.audioUnit else { return }
        try setCurrentDevice(id, of: au, label: "input")
    }

    func setOutputDevice(_ id: AudioDeviceID) throws {
        guard let au = engine.outputNode.audioUnit else { return }
        try setCurrentDevice(id, of: au, label: "output")
    }

    // MARK: - State persistence

    private var stateFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeadphoneLabHost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plugin-state.plist")
    }

    func restorePluginState() {
        guard let avUnit,
              let dict = NSDictionary(contentsOf: stateFileURL) as? [String: Any]
        else { return }
        avUnit.wrappedAUAudioUnit.fullState = dict
    }

    func savePluginState() {
        guard let avUnit, let state = avUnit.wrappedAUAudioUnit.fullState else { return }
        (state as NSDictionary).write(to: stateFileURL, atomically: true)
    }

    // MARK: - Raw AudioUnit pointer

    static func rawAudioUnitPointer(of auu: AUAudioUnit) -> AudioUnit? {
        let selector = NSSelectorFromString("audioUnit")
        guard let implementation = class_getMethodImplementation(object_getClass(auu), selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AudioUnit
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(auu, selector)
    }
}

extension AVAudioUnit {
    var wrappedAUAudioUnit: AUAudioUnit {
        if #available(macOS 27, *) {
            return withAUAudioUnit { $0 }
        }
        return auAudioUnit
    }
}

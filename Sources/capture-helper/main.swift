import AVFoundation
import CoreAudio
import Foundation

/// 采集助手（AVAudioEngine 版）：打开指定输入设备，把音频写进共享内存环形缓冲。
/// 独立成进程的原因：macOS 的音频会话禁止「带输入流的会话把输出绑定到纯输出设备」，
/// 主 app 因此完全不持有输入流（输出任意绑定、无麦克风指示灯），采集由本进程承担。
///
/// 用法：HeadphoneLabCapture <deviceID>

var deviceID = AudioDeviceID(0)
let args = CommandLine.arguments
if args.count >= 2 { deviceID = AudioDeviceID(UInt32(args[1]) ?? 0) }
guard deviceID != 0 else { fputs("usage: HeadphoneLabCapture <deviceID>\n", stderr); exit(2) }

// MARK: - 共享内存

let headerSize = MemoryLayout<CaptureHeader>.size
let ringFrames = 16384
let channelCount = 2
let ringBytes = ringFrames * channelCount * MemoryLayout<Float32>.size

let shmPath = kCaptureShmPath
unlink(shmPath)
let fd = open(shmPath, O_RDWR | O_CREAT | O_TRUNC, 0o666)
guard fd >= 0 else { fputs("open failed\n", stderr); exit(1) }
guard ftruncate(fd, off_t(headerSize + ringBytes)) == 0 else { fputs("ftruncate failed\n", stderr); exit(1) }
guard let base = mmap(nil, headerSize + ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else {
    fputs("mmap failed\n", stderr); exit(1)
}
let header = base.assumingMemoryBound(to: CaptureHeader.self)
let ring = base.advanced(by: headerSize).assumingMemoryBound(to: Float32.self)
header.pointee = CaptureHeader(
    magic: kCaptureMagic, sampleRate: 48000, channels: UInt32(channelCount),
    ringFrames: UInt32(ringFrames), writePos: 0, readPos: 0, running: 0, tick: 0)

final class RingWriter {
    var totalWritten: UInt64 = 0
    let ringFrames: Int
    let channels: Int
    let ring: UnsafeMutablePointer<Float32>
    let header: UnsafeMutablePointer<CaptureHeader>

    init(ring: UnsafeMutablePointer<Float32>, ringFrames: Int, channels: Int, header: UnsafeMutablePointer<CaptureHeader>) {
        self.ring = ring
        self.ringFrames = ringFrames
        self.channels = channels
        self.header = header
    }

    func write(interleaved src: UnsafePointer<Float32>, frames n: Int) {
        let ch = channels
        let baseIdx = Int(totalWritten % UInt64(ringFrames))
        if baseIdx + n <= ringFrames {
            memcpy(ring.advanced(by: baseIdx * ch), src, n * ch * MemoryLayout<Float32>.size)
        } else {
            let first = ringFrames - baseIdx
            memcpy(ring.advanced(by: baseIdx * ch), src, first * ch * MemoryLayout<Float32>.size)
            memcpy(ring, src.advanced(by: first * ch), (n - first) * ch * MemoryLayout<Float32>.size)
        }
        totalWritten += UInt64(n)
        header.pointee.writePos = totalWritten
    }
}

// MARK: - AVAudioEngine 输入

func setInputDevice(_ engine: AVAudioEngine, _ id: AudioDeviceID) -> OSStatus {
    guard let au = engine.inputNode.audioUnit else { return -1 }
    var dev = id
    return AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
}

func currentInputDevice(_ engine: AVAudioEngine) -> AudioDeviceID {
    guard let au = engine.inputNode.audioUnit else { return 0 }
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, &size)
    return dev
}

let engine = AVAudioEngine()
let input = engine.inputNode

let setSt = setInputDevice(engine, deviceID)
fputs("set input device \(deviceID) status=\(setSt)\n", stderr)

let inputFormat = input.outputFormat(forBus: 0)
fputs(String(format: "input format: %.0fHz %dch", inputFormat.sampleRate, inputFormat.channelCount), stderr)
guard inputFormat.channelCount > 0 else { fputs("no input\n", stderr); exit(1) }

header.pointee.sampleRate = inputFormat.sampleRate
header.pointee.channels = UInt32(channelCount)
header.pointee.ringFrames = UInt32(ringFrames)
header.pointee.running = 1

let writer = RingWriter(ring: ring, ringFrames: ringFrames, channels: channelCount, header: header)

var tapTick: UInt64 = 0
input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
    tapTick += 1
    header.pointee.tick = tapTick
    let frames = Int(buffer.frameLength)
    let ch = min(2, Int(buffer.format.channelCount))
    guard frames > 0, let data = buffer.floatChannelData else { return }
    let scratch = UnsafeMutablePointer<Float32>.allocate(capacity: frames * 2)
    defer { scratch.deallocate() }
    for f in 0..<frames {
        scratch[f * 2] = data[0][f]
        scratch[f * 2 + 1] = ch == 2 ? data[1][f] : data[0][f]
    }
    writer.write(interleaved: scratch, frames: frames)
}

do {
    try engine.start()
    fputs("engine started\n", stderr)
} catch {
    fputs("engine start failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// 启动后重设并确认（引擎初始化可能重置绑定）
_ = setInputDevice(engine, deviceID)
fputs("post-start input device: \(currentInputDevice(engine)) (want \(deviceID))\n", stderr)

signal(SIGTERM, SIG_IGN)
let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
src.setEventHandler { exit(0) }
src.resume()
dispatchMain()

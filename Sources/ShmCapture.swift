import CoreAudio
import Foundation

/// 与采集助手（HeadphoneLabCapture）共享的内存环形缓冲布局。
/// 头结构固定布局，紧随其后的是 Float32 交错采样数据。
struct CaptureHeader {
    var magic: UInt32        // 'HPL1'
    var sampleRate: Float64
    var channels: UInt32
    var ringFrames: UInt32
    var writePos: UInt64     // 已写入的帧数（总计）
    var readPos: UInt64      // 已被消费的帧数（app 回写）
    var running: UInt32
    var tick: UInt64         // 回调心跳（每次渲染自增，用于看门狗判断存活）
}

let kCaptureMagic: UInt32 = 0x48504C31  // 'HPL1'
let kCaptureShmPath = "/tmp/headphonelab_capture.shm"


/// app 侧读取器：mmap 共享内存，从环形缓冲拉取音频帧。
final class ShmCaptureReader {

    private let header: UnsafeMutablePointer<CaptureHeader>
    private let ring: UnsafeMutablePointer<Float32>
    private let ringFrames: Int
    private(set) var channels: Int
    private(set) var sampleRate: Double

    init?() {
        let fd = open(kCaptureShmPath, O_RDWR, 0o666)
        guard fd >= 0 else { NSLog("[shm] open failed errno=%d", errno); return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= off_t(MemoryLayout<CaptureHeader>.size) else { return nil }
        guard let base = mmap(nil, Int(st.st_size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else { return nil }
        let h = base.assumingMemoryBound(to: CaptureHeader.self)
        guard h.pointee.magic == kCaptureMagic else { NSLog("[shm] bad magic"); return nil }
        header = h
        ringFrames = Int(h.pointee.ringFrames)
        channels = Int(h.pointee.channels)
        sampleRate = h.pointee.sampleRate
        ring = base.advanced(by: MemoryLayout<CaptureHeader>.size).assumingMemoryBound(to: Float32.self)
        NSLog("[shm] mapped: %uHz %dch ring=%d", UInt32(sampleRate), channels, ringFrames)
    }

    var isRunning: Bool { header.pointee.running == 1 }
    var availableFrames: Int {
        let w = Int(header.pointee.writePos)
        let r = Int(header.pointee.readPos)
        return max(0, min(w - r, ringFrames - 1))
    }

    /// 拷贝最多 frameCount 帧到 destination（交错 Float32），返回实际帧数。
    @discardableResult
    func read(frames frameCount: Int, to destination: UnsafeMutablePointer<Float32>) -> Int {
        let w = Int(header.pointee.writePos)
        var r = Int(header.pointee.readPos)
        if w - r > ringFrames {
            // 溢出：落后太多，跳转到最新位置附近（以写入方为准）
            r = w - ringFrames / 2
        }
        let n = min(frameCount, w - r)
        guard n > 0 else { return 0 }
        let start = r % ringFrames
        let count = n * channels
        if start + n <= ringFrames {
            memcpy(destination, ring.advanced(by: start * channels), count * MemoryLayout<Float32>.size)
        } else {
            let first = (ringFrames - start) * channels
            memcpy(destination, ring.advanced(by: start * channels), first * MemoryLayout<Float32>.size)
            memcpy(destination.advanced(by: first), ring, (count - first) * MemoryLayout<Float32>.size)
        }
        header.pointee.readPos = UInt64(r + n)
        return n
    }
}

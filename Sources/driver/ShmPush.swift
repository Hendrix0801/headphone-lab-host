import CoreAudio
import Foundation

// 注意：此布局必须与 Sources/ShmCapture.swift 的 CaptureHeader 保持同步。
struct DriverCaptureHeader {
    var magic: UInt32
    var sampleRate: Float64
    var channels: UInt32
    var ringFrames: UInt32
    var writePos: UInt64
    var readPos: UInt64
    var running: UInt32
    var tick: UInt64
}

let driverCaptureMagic: UInt32 = 0x48504C31  // 'HPL1'
let driverShmPath = "/tmp/headphonelab_capture.shm"
let driverDebugPath = "/tmp/headphonelab_driver_debug"

/// 把系统写入的音频送进共享内存环形缓冲，供主 app 的 source node 读取。
/// 整个链路没有任何进程持有音频输入流（无麦克风指示灯）。
final class DriverShmWriter {
    private let header: UnsafeMutablePointer<DriverCaptureHeader>
    private let ring: UnsafeMutablePointer<Float32>
    private let ringFrames: Int
    private(set) var channels: Int

    init?() {
        let headerSize = MemoryLayout<DriverCaptureHeader>.size
        let ringFrames = 16384
        let ringBytes = ringFrames * 2 * MemoryLayout<Float32>.size
        var fd = open(driverShmPath, O_RDWR, 0o666)
        var created = false
        if fd < 0 {
            fd = open(driverShmPath, O_RDWR | O_CREAT | O_EXCL, 0o666)
            created = true
        }
        guard fd >= 0 else { return nil }
        // 跨进程（_coreaudiod 插件宿主 ↔ 用户 app）共享，必须放开权限。
        fchmod(fd, 0o666)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        if st.st_size < off_t(headerSize + ringBytes) {
            guard ftruncate(fd, off_t(headerSize + ringBytes)) == 0 else { return nil }
            fstat(fd, &st)
        }
        guard st.st_size >= off_t(headerSize + ringBytes) else { return nil }
        guard let base = mmap(nil, Int(st.st_size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else {
            return nil
        }
        header = base.assumingMemoryBound(to: DriverCaptureHeader.self)
        ring = base.advanced(by: headerSize).assumingMemoryBound(to: Float32.self)
        self.ringFrames = ringFrames
        channels = 2
        // 驱动是唯一的写入方且以 HAL sample time 为计数基准，
        // 每次初始化都重置计数器，避免与读取方的历史计数错位。
        let needsReset = created
            || header.pointee.magic != driverCaptureMagic
            || header.pointee.ringFrames != UInt32(ringFrames)
            || header.pointee.readPos > header.pointee.writePos
        if needsReset {
            header.pointee = DriverCaptureHeader(
                magic: driverCaptureMagic, sampleRate: 48000, channels: 2,
                ringFrames: UInt32(ringFrames), writePos: 0, readPos: 0, running: 1, tick: 0)
        } else {
            header.pointee.running = 1
        }
    }

    /// 写入一帧区间（帧位置由外部按 sample time 取模传入）。
    func write(baseIdx: Int, frame: Int, channel: Int, value: Float32) {
        ring[((baseIdx + frame) % ringFrames) * channels + channel] = value
    }

    private var lastPublishedWritePos: UInt64 = 0

    /// 发布单调递增的 writePos；对 sampleTime 跳变/回绕做钳制。
    func publish(writePos: UInt64, tick: UInt64, sampleRate: Double, channels: UInt32) {
        var w = writePos
        if w < lastPublishedWritePos { w = lastPublishedWritePos }
        lastPublishedWritePos = w
        header.pointee.sampleRate = sampleRate
        header.pointee.channels = channels
        header.pointee.writePos = w
        header.pointee.tick = tick
    }
}

/// 驱动调试计数器（共享内存文件，app/探针直接读取，不依赖日志系统）。
struct DriverDebugBlock {
    var magic: UInt32          // 'HPLD'
    var initializeCalled: UInt32
    var startIOCount: UInt32
    var stopIOCount: UInt32
    var writeMixCount: UInt32
    var performConfigCount: UInt32
    var lastPerformAction: UInt64
    var sampleRate: Float64
    var phase: UInt32
    var startIOReturned: UInt32
    var lastError: Int32
    var shmOk: UInt32
    var framesWritten: UInt64
    var negativeBaseCount: UInt32
    var sampleTimeJumps: UInt32
}

final class DriverDebug {
    private let block: UnsafeMutablePointer<DriverDebugBlock>

    init?() {
        let size = MemoryLayout<DriverDebugBlock>.size
        let fd = open(driverDebugPath, O_RDWR | O_CREAT, 0o666)
        guard fd >= 0, ftruncate(fd, off_t(size)) == 0 else { return nil }
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else { return nil }
        block = base.assumingMemoryBound(to: DriverDebugBlock.self)
        if block.pointee.magic != 0x48504C44 {
            block.pointee = DriverDebugBlock(
                magic: 0x48504C44, initializeCalled: 0, startIOCount: 0, stopIOCount: 0,
                writeMixCount: 0, performConfigCount: 0, lastPerformAction: 0,
                sampleRate: 0, phase: 0, startIOReturned: 0, lastError: 0, shmOk: 0, framesWritten: 0,
                negativeBaseCount: 0, sampleTimeJumps: 0)
        }
    }

    @inline(__always)
    func bump(_ keyPath: WritableKeyPath<DriverDebugBlock, UInt32>) {
        block.pointee[keyPath: keyPath] &+= 1
    }

    @inline(__always)
    func set<T>(_ keyPath: WritableKeyPath<DriverDebugBlock, T>, _ value: T) {
        block.pointee[keyPath: keyPath] = value
    }

    @inline(__always)
    func addFrames(_ n: UInt64) {
        block.pointee.framesWritten += n
    }
}

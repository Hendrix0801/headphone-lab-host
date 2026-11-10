//
// Shared.swift
// HeadphoneLab driver — inlined from eqMac's 'Shared' SwiftPM module
// (native/shared/Source/*.swift), keeping only what the driver uses.
//

import Foundation
import CoreAudio.AudioServerPlugIn

// MARK: Memory.swift
class Memory {
  static func sizeof <T> (_ type: T.Type) -> UInt32 {
    return UInt32(MemoryLayout<T>.stride)
  }

  static func sizeof <T> (_ value: T) -> UInt32 {
    return UInt32(MemoryLayout.size(ofValue: value))
  }
}

// MARK: Mutex.swift
class Mutex {
  var mutex = pthread_mutex_t()

  init () {
    var attributes = pthread_mutexattr_t()
    guard pthread_mutexattr_init(&attributes) == 0 else {
      preconditionFailure()
    }

    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_NORMAL)

    guard pthread_mutex_init(&mutex, &attributes) == 0 else {
      preconditionFailure()
    }

    pthread_mutexattr_destroy(&attributes)
  }

  func lock () {
    pthread_mutex_lock(&mutex)
  }

  func unlock () {
    pthread_mutex_unlock(&mutex)
  }

  deinit {
    pthread_mutex_destroy(&mutex)
  }
}

// MARK: AtomicCounter
// eqMac uses ManagedAtomic<> from apple/swift-atomics. The command-line build
// here has no SwiftPM packages, so this NSLock-backed counter stands in for it.
// Call sites keep eqMac's naming (load / wrappingIncrement /
// incrementThenLoad / wrappingDecrementThenLoad).
final class AtomicCounter {
  private var value: UInt64
  private let lock = NSLock()

  init (_ initial: UInt64 = 0) {
    value = initial
  }

  func load () -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func wrappingIncrement () {
    lock.lock()
    value &+= 1
    lock.unlock()
  }

  func incrementThenLoad () -> UInt64 {
    lock.lock()
    value &+= 1
    defer { lock.unlock() }
    return value
  }

  func wrappingDecrementThenLoad () -> UInt64 {
    lock.lock()
    value &-= 1
    defer { lock.unlock() }
    return value
  }
}

// MARK: AudioObjectPropertySelectorExtensions.swift
extension AudioObjectPropertySelector {
  static func fromString (_ str: String) -> AudioObjectPropertySelector {
    var value: UInt32 = 0
    for byte in str.utf8 { value = (value << 8) | UInt32(byte) }
    return AudioObjectPropertySelector(value)
  }

  var code: String {
    return String(bytes: withUnsafeBytes(of: self.bigEndian, Array.init), encoding: .utf8)!
  }
}

// MARK: StringExtensions.swift (partial)
extension String {
  var byteArray: [UInt8] {
    return Array(self.utf8)
  }
}

// MARK: NumericTypesConversions.swift (partial)
extension UInt32 {
  init (from array: [UInt8]) {
    let bigEndianValue = array.withUnsafeBufferPointer {
      ($0.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0 })
    }.pointee
    let value = UInt32(bigEndian: bigEndianValue)
    self = value
  }
}

extension Comparable {
  func clamp <T: Comparable> (min minimum: T, max maximum: T) -> T {
    return min(maximum, max(minimum, self as! T))
  }
}

// MARK: VolumeConverter.swift
class VolumeConverter {
  static func toDecibel (_ volume: Float32) -> Float32 {
    if (volume <= powf(10.0, kMinVolumeDB / 20.0)) {
      return kMinVolumeDB
    } else {
      return 20.0 * log10f(volume)
    }
  }

  static func fromDecibel (_ decibel: Float32) -> Float32 {
    if (decibel <= kMinVolumeDB) {
      return 0.0
    } else {
      return powf(10.0, decibel / 20.0)
    }
  }

  static func toScalar (_ volume: Float32) -> Float32 {
    let decibel = toDecibel(volume);
    return (decibel - kMinVolumeDB) / (kMaxVolumeDB - kMinVolumeDB);
  }

  static func fromScalar (_ scalar: Float32) -> Float32 {
    let decibel = scalar * (kMaxVolumeDB - kMinVolumeDB) + kMinVolumeDB
    return fromDecibel(decibel)
  }

  static func toRelative (_ volume: Float32) -> Float32 {
    if volume == 0 { return 0 }
    return exp(4 * volume - 4)
  }
}

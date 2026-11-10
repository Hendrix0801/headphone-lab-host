//
// HPLDevice.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/EQMDevice.swift
// Differences vs eqMac:
//   - no 'shwn'/'cltc'/'vrsn' custom properties, only 'hpln' (device rename, no caller check)
//   - no Icon property (the bundle ships no .icns resource)
//   - the device is always visible (eqMac hides itself until its app connects)
//

import Foundation
import CoreAudio.AudioServerPlugIn

class HPLDevice: HPLObject {
  static var name = kHPLDeviceDefaultName
  static var sampleRate = kDefaultSampleRate
  static var running = false
  static var ioCounter = AtomicCounter(0)
  static var anchorHostTime: UInt64 = 0
  static var anchorSampleTime: UInt64 = 0
  static var timestampCount: UInt64 = 0
  static let ioMutex = Mutex()

  static let ringBufferSize: UInt32 = 16384
  static var shmWriter: DriverShmWriter?
  static var debug: DriverDebug?

  static var ringBuffer: UnsafeMutablePointer<Float32>?

  static func getDescription (for samplingRate: Float64) -> AudioStreamBasicDescription {
    return AudioStreamBasicDescription(
      mSampleRate: samplingRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
      mBytesPerPacket: kBytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: kBytesPerFrame,
      mChannelsPerFrame: kChannelCount,
      mBitsPerChannel: kBitsPerChannel,
      mReserved: 0
    )
  }

  static func hasProperty (objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress) -> Bool {
    switch address.mSelector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyName,
         kAudioObjectPropertyManufacturer,
         kAudioObjectPropertyOwnedObjects,
         kAudioDevicePropertyDeviceUID,
         kAudioDevicePropertyModelUID,
         kAudioDevicePropertyTransportType,
         kAudioDevicePropertyRelatedDevices,
         kAudioDevicePropertyClockDomain,
         kAudioDevicePropertyDeviceIsAlive,
         kAudioDevicePropertyDeviceIsRunning,
         kAudioObjectPropertyControlList,
         kAudioDevicePropertyNominalSampleRate,
         kAudioDevicePropertyAvailableNominalSampleRates,
         kAudioDevicePropertyIsHidden,
         kAudioDevicePropertyZeroTimeStampPeriod,
         kAudioDevicePropertyStreams,
         kAudioObjectPropertyCustomPropertyInfoList,
         kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
         HPLDeviceCustom.name:
      return true

    case kAudioDevicePropertyDeviceCanBeDefaultDevice,
         kAudioDevicePropertyLatency,
         kAudioDevicePropertySafetyOffset,
         kAudioDevicePropertyPreferredChannelsForStereo,
         kAudioDevicePropertyPreferredChannelLayout:
      return address.mScope == kAudioObjectPropertyScopeInput || address.mScope == kAudioObjectPropertyScopeOutput

    default:
      return false
    }
  }

  static func isPropertySettable (objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress) -> Bool {
    switch address.mSelector {
    case kAudioDevicePropertyNominalSampleRate,
         HPLDeviceCustom.name:
      return true

    default:
      return false
    }
  }

  static func getPropertyDataSize (objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress) -> UInt32? {
    switch address.mSelector {
    case kAudioObjectPropertyBaseClass: return Memory.sizeof(AudioClassID.self)
    case kAudioObjectPropertyClass: return Memory.sizeof(AudioClassID.self)
    case kAudioObjectPropertyOwner: return Memory.sizeof(AudioObjectID.self)
    case kAudioObjectPropertyName: return Memory.sizeof(CFString.self)
    case kAudioObjectPropertyManufacturer: return Memory.sizeof(CFString.self)
    case kAudioObjectPropertyOwnedObjects:
      switch (address.mScope) {
      case kAudioObjectPropertyScopeGlobal: return 8 * Memory.sizeof(AudioObjectID.self)
      case kAudioObjectPropertyScopeInput: return 0
      case kAudioObjectPropertyScopeOutput: return 4 * Memory.sizeof(AudioObjectID.self)
      default:
        return nil
      }
    case kAudioDevicePropertyDeviceUID: return Memory.sizeof(CFString.self)
    case kAudioDevicePropertyModelUID: return Memory.sizeof(CFString.self)
    case kAudioDevicePropertyTransportType: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyRelatedDevices: return Memory.sizeof(AudioObjectID.self)
    case kAudioDevicePropertyClockDomain: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyDeviceIsAlive: return Memory.sizeof(AudioClassID.self)
    case kAudioDevicePropertyDeviceIsRunning: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyLatency: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyStreams:
      switch(address.mScope) {
      case kAudioObjectPropertyScopeGlobal: return Memory.sizeof(AudioObjectID.self)
      case kAudioObjectPropertyScopeInput: return 0
      case kAudioObjectPropertyScopeOutput: return Memory.sizeof(AudioObjectID.self)
      default:
        return nil
      }
    case kAudioObjectPropertyControlList: return 3 * Memory.sizeof(AudioObjectID.self)
    case kAudioDevicePropertySafetyOffset: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyNominalSampleRate: return Memory.sizeof(Float64.self)
    case kAudioDevicePropertyAvailableNominalSampleRates: return UInt32(kHPLDeviceSupportedSampleRates.count) * Memory.sizeof(AudioValueRange.self)
    case kAudioDevicePropertyIsHidden: return Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyPreferredChannelsForStereo: return 2 * Memory.sizeof(UInt32.self)
    case kAudioDevicePropertyPreferredChannelLayout:
      let layoutSize = Memory.sizeof(AudioChannelLayout.self)
      // Layout will already contain size for 1 channel description
      let channelsSize = Memory.sizeof(AudioChannelDescription.self) * kChannelCount - 1
      return layoutSize + channelsSize

    case kAudioDevicePropertyZeroTimeStampPeriod: return Memory.sizeof(UInt32.self)

    case kAudioObjectPropertyCustomPropertyInfoList:
      return Memory.sizeof(AudioServerPlugInCustomPropertyInfo.self) * HPLDeviceCustom.count
    case HPLDeviceCustom.name: return Memory.sizeof(CFString.self)

    default:
      return nil
    }
  }

  static func getPropertyData (objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress, inData: UnsafeRawPointer?) -> HPLObjectProperty? {
    switch address.mSelector {
    case kAudioObjectPropertyBaseClass:
      // The base class for kAudioDeviceClassID is kAudioObjectClassID
      return .audioClassID(kAudioObjectClassID)
    case kAudioObjectPropertyClass:
      // The class is always kAudioDeviceClassID for devices created by drivers
      return .audioClassID(kAudioDeviceClassID)
    case kAudioObjectPropertyOwner:
      // The device's owner is the plug-in object
      return .audioObjectID(kObjectID_PlugIn)
    case kAudioObjectPropertyName:
      // This is the human readable name of the device.
      return .string(name as CFString)
    case kAudioObjectPropertyManufacturer:
      // This is the human readable name of the maker of the plug-in.
      return .string(kDeviceManufacturer as CFString)
    case kAudioObjectPropertyOwnedObjects:
      // Calculate the number of items that have been requested. Note that this
      // number is allowed to be smaller than the actual size of the list. In such
      // case, only that number of items will be returned

      // The device owns its streams and controls. Note that what is returned here
      // depends on the scope requested.
      switch address.mScope {
      case kAudioObjectPropertyScopeGlobal:
        return .objectIDList([
          kObjectID_Stream_Output,
          kObjectID_Volume_Output_Master,
          kObjectID_Mute_Output_Master,
          kObjectID_DataSource_Output_Master,
        ])
      case kAudioObjectPropertyScopeInput:
        // shm 推送版：无输入流。
        return .objectIDList([])
      case kAudioObjectPropertyScopeOutput:
        return .objectIDList([
          kObjectID_Stream_Output,
          kObjectID_Volume_Output_Master,
          kObjectID_Mute_Output_Master,
          kObjectID_DataSource_Output_Master,
        ])
      default: return .null()
      }
    case kAudioDevicePropertyDeviceUID:
      // This is a CFString that is a persistent token that can identify the same
      // audio device across boot sessions. Note that two instances of the same
      // device must have different values for this property.
      return .string(kDeviceUID as CFString)
    case kAudioDevicePropertyModelUID:
      // This is a CFString that is a persistent token that can identify audio
      // devices that are the same kind of device. Note that two instances of the
      // save device must have the same value for this property.
      return .string(kDeviceModelUID as CFString)
    case kAudioDevicePropertyTransportType:
      // This value represents how the device is attached to the system. This can be
      // any 32 bit integer, but common values for this property are defined in
      // <CoreAudio/AudioHardwareBase.h>
      return .integer(kAudioDeviceTransportTypeVirtual)
    case kAudioDevicePropertyRelatedDevices:
      // The related devices property identifys device objects that are very closely
      // related. Generally, this is for relating devices that are packaged together
      // in the hardware such as when the input side and the output side of a piece
      // of hardware can be clocked separately and therefore need to be represented
      // as separate AudioDevice objects. In such case, both devices would report
      // that they are related to each other. Note that at minimum, a device is
      // related to itself, so this list will always be at least one item long.

      // Calculate the number of items that have been requested. Note that this
      // number is allowed to be smaller than the actual size of the list. In such
      // case, only that number of items will be returned
      return .objectIDList([ kObjectID_Device ])
    case kAudioDevicePropertyClockDomain:
      // This property allows the device to declare what other devices it is
      // synchronized with in hardware. The way it works is that if two devices have
      // the same value for this property and the value is not zero, then the two
      // devices are synchronized in hardware. Note that a device that either can't be
      // synchronized with others or doesn't know should return 0 for this
      // property.
      return .integer(0)
    case kAudioDevicePropertyDeviceIsAlive:
      // This property returns whether or not the device is alive. Note that it is
      // note uncommon for a device to be dead but still momentarily availble in the
      // device list. In the case of this device, it will always be alive.
      return .integer(1)
    case kAudioDevicePropertyDeviceIsRunning:
      // This property returns whether or not IO is running for the device. Note that
      // we need to take both the state lock to check this value for thread safety.
      return .integer(running ? 1 : 0)
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
      // This property returns whether or not the device wants to be able to be the
      // default device for content. This is the device that iTunes and QuickTime
      // will use to play their content on and FaceTime will use as its microphone.
      // Nearly all devices should allow for this.
      if address.mScope == kAudioObjectPropertyScopeInput {
        return .integer(0)
      } else {
        return .integer(1)
      }
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
      // This property returns whether or not the device wants to be the system
      // default device. This is the device that is used to play interface sounds and
      // other incidental or UI-related sounds on. Most devices should allow this
      // although devices with lots of latency may not want to.
      return .integer(1)
    case kAudioDevicePropertyLatency:
      // This property returns the presentation latency of the device. For this
      // device, the value is 0 due to the fact that it always vends silence.
      return .integer(0)

    case kAudioDevicePropertyStreams:
      // Calculate the number of items that have been requested. Note that this
      // number is allowed to be smaller than the actual size of the list. In such
      // case, only that number of items will be returned

      // Note that what is returned here depends on the scope requested.
      switch address.mScope {
      case kAudioObjectPropertyScopeGlobal:
        // global scope means return all streams
        return .objectIDList([ kObjectID_Stream_Output ])
      case kAudioObjectPropertyScopeInput:
        // shm 推送版：无输入流。
        return .objectIDList([])
      case kAudioObjectPropertyScopeOutput:
        // output scope means just the objects on the output side
        return .audioObjectID(kObjectID_Stream_Output)
      default:
        return .null()
      }

    case kAudioObjectPropertyControlList:
      // Calculate the number of items that have been requested. Note that this
      // number is allowed to be smaller than the actual size of the list. In such
      // case, only that number of items will be returned
      return .objectIDList([
        kObjectID_Volume_Output_Master,
        kObjectID_Mute_Output_Master,
        kObjectID_DataSource_Output_Master
      ])
    case kAudioDevicePropertySafetyOffset:
      // This property returns the how close to now the HAL can read and write. For
      // this, device, the value is 0 due to the fact that it always vends silence.
      return .integer(0)

    case kAudioDevicePropertyNominalSampleRate:
      // This property returns the nominal sample rate of the device. Note that we
      // only need to take the state lock to get this value.
      return .float64(sampleRate)

    case kAudioDevicePropertyAvailableNominalSampleRates:
      // This returns all nominal sample rates the device supports as an array of
      // AudioValueRangeStructs. Note that for discrete sampler rates, the range
      // will have the minimum value equal to the maximum value.

      return .valueRangeList(
        ContiguousArray(kHPLDeviceSupportedSampleRates.map { freq -> AudioValueRange in
          let frequency = Float64(freq)
          let range = AudioValueRange(mMinimum: frequency, mMaximum: frequency)
          return range
        })
      )

    case kAudioDevicePropertyIsHidden:
      // This returns whether or not the device is visible to clients.
      // This device is always visible.
      return .integer(0)

    case kAudioDevicePropertyPreferredChannelsForStereo:
      // This property returns which two channesl to use as left/right for stereo
      // data by default. Note that the channel numbers are 1-based.xz
      return .integerList([ 1, 2 ])

    case kAudioDevicePropertyPreferredChannelLayout:
      // This property returns the default AudioChannelLayout to use for the device
      // by default. For this device, we return a stereo ACL.
      // calcualte how big the
      let channelDescriptionsPtr = UnsafeMutablePointer<AudioChannelDescription>.allocate(capacity: Int(kChannelCount))

      for channelNumber in 0 ..< Int(kChannelCount) {
        channelDescriptionsPtr[channelNumber] = AudioChannelDescription(
          mChannelLabel: AudioChannelLabel(channelNumber),
          mChannelFlags: AudioChannelFlags(rawValue: 0),
          mCoordinates: (0, 0, 0)
        )
      }

      let channelLayout = AudioChannelLayout(
        mChannelLayoutTag: kAudioChannelLayoutTag_UseChannelDescriptions,
        mChannelBitmap: AudioChannelBitmap(rawValue: 0),
        mNumberChannelDescriptions: kChannelCount,
        mChannelDescriptions: channelDescriptionsPtr.pointee
      )

      return .channelLayout(channelLayout)
    case kAudioDevicePropertyZeroTimeStampPeriod:
      // This property returns how many frames the HAL should expect to see between
      // successive sample times in the zero time stamps this device provides.
      return .integer(ringBufferSize)

    case kAudioObjectPropertyCustomPropertyInfoList:
      // This property returns an array of AudioServerPlugInCustomPropertyInfo's that
      // describe the type of data used by any custom properties.
      let customProperties = ContiguousArray([
        AudioServerPlugInCustomPropertyInfo(
          mSelector: HPLDeviceCustom.name,
          mPropertyDataType: kAudioServerPlugInCustomPropertyDataTypeCFString,
          mQualifierDataType: kAudioServerPlugInCustomPropertyDataTypeNone
        )
      ])

      return .customPropertyInfoList(customProperties)

    case HPLDeviceCustom.name:
      return .string(name as CFString)

    default: return nil
    }
  }

  static func setPropertyData(client: HPLClient?, objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress, data: UnsafeRawPointer, changedProperties: inout [AudioObjectPropertyAddress]) -> OSStatus {
    switch address.mSelector {

    case kAudioDevicePropertyNominalSampleRate:
      // Changing the sample rate needs to be handled via the
      // RequestConfigChange/PerformConfigChange machinery.

      // check the arguments
      let newSampleRate = data.load(as: Float64.self)

      if !kHPLDeviceSupportedSampleRates.contains(newSampleRate) {
        return kAudioHardwareIllegalOperationError
      }

      // make sure that the new value is different than the old value
      if (sampleRate != newSampleRate) {
        // we dispatch this so that the change can happen asynchronously
        DispatchQueue.global(qos: .default).async {
          _ = HPLDriver.host?.pointee.RequestDeviceConfigurationChange(
            HPLDriver.host!,
            kObjectID_Device,
            UInt64(newSampleRate),
            nil
          )
        }
      }
      return noErr

    // Custom Properties
    case HPLDeviceCustom.name:
      // Any client may rename the device (personal tool, no bundle-id check).
      var newName = data.load(as: CFString.self) as String

      if name != newName {
        if newName == "" {
          newName = kHPLDeviceDefaultName
        }
        name = newName

        changedProperties.append(
          .init(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
          )
        )
      }

      return noErr
    default: return kAudioHardwareUnknownPropertyError
    }
  }

  static func startIO () -> OSStatus {
    let ioCount = ioCounter.load()

    // Reached max amount of possible IOs
    if ioCount == UInt64.max {
      return kAudioHardwareIllegalOperationError
    }

    log("startIO called (ioCount=\(ioCount))")
    ioMutex.lock()

    // If IO is not running we need start it and init all the important vars
    if ioCount == 0 {
      running = true
      timestampCount = 0
      anchorSampleTime = 0
      anchorHostTime = mach_absolute_time()
      ringBuffer?.deallocate()
      ringBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(ringBufferSize * 4 * kChannelCount))
    } else {
      // IO already running so increment the counter
      ioCounter.wrappingIncrement()
    }

    ioMutex.unlock()

    return noErr
  }

  static func stopIO () -> OSStatus {
    log("stopIO called")
    // If IO is not running it's an invalid call
    if !running {
      return kAudioHardwareIllegalOperationError
    }

    var ioCount = ioCounter.load()

    if ioCount > 0 {
      ioCount = ioCounter.wrappingDecrementThenLoad()
    }

    ioMutex.lock()

    // If IO reached zero deinit
    if ioCount == 0 {
      running = false
      ringBuffer?.deallocate()
      ringBuffer = nil
    }

    ioMutex.unlock()

    return noErr
  }

  static func getZeroTimeStamp (outSampleTime: UnsafeMutablePointer<Float64>, outHostTime: UnsafeMutablePointer<UInt64>, outSeed: UnsafeMutablePointer<UInt64>) -> OSStatus {

    ioMutex.lock()

    // get the current host time
    let currentHostTime = mach_absolute_time()

    // calculate the next host time
    let hostTicksPerRingBuffer = HPLDriver.hostTicksPerFrame! * Float64(ringBufferSize)
    let hostTicksOffset = Float64(timestampCount + 1) * hostTicksPerRingBuffer
    let nextHostTime = anchorHostTime + UInt64(hostTicksOffset)

    if nextHostTime <= currentHostTime {
      timestampCount += 1
    }

    outSampleTime.pointee = Float64(timestampCount * UInt64(ringBufferSize))
    outHostTime.pointee = anchorHostTime + timestampCount * UInt64(hostTicksPerRingBuffer)
    outSeed.pointee = 1

    ioMutex.unlock()

    return noErr
  }

  static func doIO (client: HPLClient?, operationID: UInt32, sample: UnsafeMutablePointer<Float32>, cycleInfo: AudioServerPlugInIOCycleInfo, frameSize: UInt32) -> OSStatus {
    guard operationID == AudioServerPlugInIOOperation.writeMix.rawValue else {
      return noErr
    }
    debug?.bump(\.writeMixCount)

    let chCount = Int(kChannelCount)
    let n = Int(frameSize)
    let volume = HPLControl.muted ? Float32(0) : HPLControl.volume

    if let shm = shmWriter {
      // ioMainBuffer 为交错 Float32（与流格式一致）。
      let base = Int(cycleInfo.mOutputTime.mSampleTime)
      for f in 0..<n {
        for c in 0..<chCount {
          shm.write(baseIdx: base, frame: f, channel: c, value: sample[f * chCount + c] * volume)
        }
      }
      shmTick &+= 1
      shm.publish(
        writePos: UInt64(Int64(cycleInfo.mOutputTime.mSampleTime) + Int64(n)),
        tick: shmTick,
        sampleRate: sampleRate, channels: UInt32(chCount))
      debug?.addFrames(UInt64(n))
    }

    // 设备对外静音（音频只进共享内存）。
    sample.update(repeating: 0, count: n * chCount)
    return noErr
  }

  static var shmTick: UInt64 = 0
}

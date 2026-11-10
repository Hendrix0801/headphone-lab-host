//
// HPLStream.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/EQMStream.swift
// (fixes an inverted check in eqMac: it rejected *supported* sample rates in
// the stream format setter; here an unsupported rate returns the error)
//

import Foundation
import CoreAudio.AudioServerPlugIn

class HPLStream: HPLObject {
  static var inputActive = true
  static var outputActive = true

  static func hasProperty (objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress) -> Bool {
    switch address.mSelector {
    case kAudioObjectPropertyBaseClass,
         kAudioObjectPropertyClass,
         kAudioObjectPropertyOwner,
         kAudioObjectPropertyOwnedObjects,
         kAudioStreamPropertyIsActive,
         kAudioStreamPropertyDirection,
         kAudioStreamPropertyTerminalType,
         kAudioStreamPropertyStartingChannel,
         kAudioStreamPropertyLatency,
         kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat,
         kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats:
      return true
    default:
      return false
    }
  }

  static func isPropertySettable (objectID: AudioObjectID? = nil, address: AudioObjectPropertyAddress) -> Bool {
    switch address.mSelector {
    case kAudioStreamPropertyIsActive,
         kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat:
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
    case kAudioObjectPropertyOwnedObjects: return 0 * Memory.sizeof(AudioObjectID.self)
    case kAudioStreamPropertyIsActive: return Memory.sizeof(UInt32.self)
    case kAudioStreamPropertyDirection: return Memory.sizeof(UInt32.self)
    case kAudioStreamPropertyTerminalType: return Memory.sizeof(UInt32.self)
    case kAudioStreamPropertyStartingChannel: return Memory.sizeof(UInt32.self)
    case kAudioStreamPropertyLatency: return Memory.sizeof(UInt32.self)
    case kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat: return Memory.sizeof(AudioStreamBasicDescription.self)
    case kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats: return UInt32(kHPLDeviceSupportedSampleRates.count) * Memory.sizeof(AudioStreamRangedDescription.self)
    default:
      return nil
    }
  }

  static func getPropertyData (objectID: AudioObjectID?, address: AudioObjectPropertyAddress, inData: UnsafeRawPointer?) -> HPLObjectProperty? {

    switch address.mSelector {
    case kAudioObjectPropertyBaseClass:
      // The base class for kAudioStreamClassID is kAudioObjectClassID
      return .audioClassID(kAudioObjectClassID)
    case kAudioObjectPropertyClass:
      // The class is always kAudioStreamClassID for streams created by drivers
      return .audioClassID(kAudioStreamClassID)
    case kAudioObjectPropertyOwner:
      // The stream's owner is the device object
      return .audioObjectID(kObjectID_Device)
    case kAudioObjectPropertyOwnedObjects:
      // Streams do not own any objects
      return .objectIDList([])
    case kAudioStreamPropertyIsActive:
      // This property tells the device whether or not the given stream is going to
      // be used for IO. Note that we need to take the state lock to examine this
      // value.
      let active = objectID == kObjectID_Stream_Input ? inputActive : outputActive
      return .integer(active ? 1 : 0)
    case kAudioStreamPropertyDirection:
      // This returns whether the stream is an input stream or an output stream.
      return .integer(objectID == kObjectID_Stream_Input ? 1 : 0)
    case kAudioStreamPropertyTerminalType:
      // This returns a value that indicates what is at the other end of the stream
      // such as a speaker or headphones, or a microphone. Values for this property
      // are defined in <CoreAudio/AudioHardwareBase.h>
      switch objectID {
      case kObjectID_Stream_Input: return .integer(kAudioStreamTerminalTypeMicrophone)
      case kObjectID_Stream_Output: return .integer(kAudioStreamTerminalTypeSpeaker)
      default: return .integer(kAudioStreamTerminalTypeUnknown)
      }
    case kAudioStreamPropertyStartingChannel:
      // This property returns the absolute channel number for the first channel in
      // the stream. For exmaple, if a device has two output streams with two
      // channels each, then the starting channel number for the first stream is 1
      // and ths starting channel number fo the second stream is 3.
      return .integer(1)
    case kAudioStreamPropertyLatency:
      // This property returns any additonal presentation latency the stream has.
      return .integer(0)
    case kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat:
      // This returns the current format of the stream in an
      // AudioStreamBasicDescription. Note that we need to hold the state lock to get
      // this value.
      // Note that for devices that don't override the mix operation, the virtual
      // format has to be the same as the physical format.

      return .streamDescription(
        HPLDevice.getDescription(for: HPLDevice.sampleRate)
      )
    case kAudioStreamPropertyAvailableVirtualFormats,
         kAudioStreamPropertyAvailablePhysicalFormats:
      // This returns an array of AudioStreamRangedDescriptions that describe what
      // formats are supported.

      // Calculate the number of items that have been requested. Note that this
      // number is allowed to be smaller than the actual size of the list. In such
      // case, only that number of items will be returned

      // fill out the return array

      let formats = ContiguousArray(kHPLDeviceSupportedSampleRates.map { sampleRate in
        return AudioStreamRangedDescription(
          mFormat: HPLDevice.getDescription(for: sampleRate),
          mSampleRateRange: AudioValueRange(
            mMinimum: sampleRate,
            mMaximum: sampleRate
          )
        )
      })

      return .streamDescriptionList(formats)
    default: return nil
    }
  }

  static func setPropertyData(client: HPLClient?, objectID: AudioObjectID?, address: AudioObjectPropertyAddress, data: UnsafeRawPointer, changedProperties: inout [AudioObjectPropertyAddress]) -> OSStatus {
    switch address.mSelector {
    case kAudioStreamPropertyIsActive:
      // Changing the active state of a stream doesn't affect IO or change the structure
      // so we can just save the state and send the notification.
      let activeInt = data.load(as: UInt32.self)
      let active = activeInt != 0

      switch objectID {
      case kObjectID_Stream_Input:
        inputActive = active
        changedProperties.append(
          .init(
            mSelector: kAudioStreamPropertyIsActive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
          )
        )
        break
      case kObjectID_Stream_Output:
        outputActive = active
        changedProperties.append(
          .init(
            mSelector: kAudioStreamPropertyIsActive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
          )
        )
        break
      default: return kAudioHardwareBadObjectError
      }

      return noErr
    case kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat:
      // Changing the stream format needs to be handled via the
      // RequestConfigChange/PerformConfigChange machinery. Note that because this
      // device only supports 2 channel 32 bit float data, the only thing that can
      // change is the sample rate.

      let newDescription = data.load(as: AudioStreamBasicDescription.self)

      // eqMac had this check inverted and rejected every supported rate; fixed here.
      if !kHPLDeviceSupportedSampleRates.contains(newDescription.mSampleRate) {
        return kAudioDeviceUnsupportedFormatError
      }

      // If we made it this far, the requested format is something we support, so make sure the sample rate is actually different
      if HPLDevice.sampleRate != newDescription.mSampleRate {
        // we dispatch this so that the change can happen asynchronously
        DispatchQueue.global(qos: .default).async {
          _ = HPLDriver.host?.pointee.RequestDeviceConfigurationChange(
            HPLDriver.host!,
            kObjectID_Device,
            UInt64(newDescription.mSampleRate),
            nil
          )
        }
      }
      return noErr
    default: return kAudioHardwareUnknownPropertyError
    }
  }
}

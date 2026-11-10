//
// HPLDriver.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/EQMDriver.swift
//

import Foundation
import CoreAudio.AudioServerPlugIn

// @objc public (not just @objc) so the class is visible in the generated
// ObjC header even when batch-mode frontend jobs write the header; HPLDriverBridge.m
// relies on it. eqMac marks it internal and gets away with it under Xcode's job order.
@objc public class HPLDriver: NSObject {
  static var host: AudioServerPlugInHostRef?
  static var hostTicksPerFrame: Float64?

  static private var _interface: AudioServerPlugInDriverInterface?
  static private var _interfacePtr: UnsafeMutablePointer<AudioServerPlugInDriverInterface>?

  static var refCounter = AtomicCounter(0)
  @objc public static var ref: AudioServerPlugInDriverRef?

  static var mutex = Mutex()

  @objc
  public static func create (allocator: CFAllocator!, requestedTypeUUID: CFUUID!) -> UnsafeMutableRawPointer? {
    // This is the CFPlugIn factory function. Its job is to create the implementation for the given
    // type provided that the type is supported. Because this driver is simple and all its
    // initialization is handled via static initialization when the bundle is loaded, all that
    // needs to be done is to return the AudioServerPlugInDriverRef that points to the driver's
    // interface. A more complicated driver would create any base line objects it needs to satisfy
    // the IUnknown methods that are used to discover that actual interface to talk to the driver.
    // The majority of the driver's initialization should be handled in the Initialize() method of
    // the driver's AudioServerPlugInDriverInterface.

    if !CFEqual(requestedTypeUUID, kAudioServerPluginTypeUUID) {
      return nil
    }

    return UnsafeMutableRawPointer(createRef())
  }

  private static func createRef () -> AudioServerPlugInDriverRef {
    if ref != nil {
      return ref!
    }

    _interface = AudioServerPlugInDriverInterface(
      _reserved: nil,
      QueryInterface: HPL_QueryInterface,
      AddRef: HPL_AddRef,
      Release: HPL_Release,
      Initialize: HPL_Initialize,
      CreateDevice: HPL_CreateDevice,
      DestroyDevice: HPL_DestroyDevice,
      AddDeviceClient: HPL_AddDeviceClient,
      RemoveDeviceClient: HPL_RemoveDeviceClient,
      PerformDeviceConfigurationChange: HPL_PerformDeviceConfigurationChange,
      AbortDeviceConfigurationChange: HPL_AbortDeviceConfigurationChange,
      HasProperty: HPL_HasProperty,
      IsPropertySettable: HPL_IsPropertySettable,
      GetPropertyDataSize: HPL_GetPropertyDataSize,
      GetPropertyData: HPL_GetPropertyData,
      SetPropertyData: HPL_SetPropertyData,
      StartIO: HPL_StartIO,
      StopIO: HPL_StopIO,
      GetZeroTimeStamp: HPL_GetZeroTimeStamp,
      WillDoIOOperation: HPL_WillDoIOOperation,
      BeginIOOperation: HPL_BeginIOOperation,
      DoIOOperation: HPL_DoIOOperation,
      EndIOOperation: HPL_EndIOOperation
    )

    _interfacePtr = withUnsafeMutablePointer(to: &_interface!) { $0 }
    ref = withUnsafeMutablePointer(to: &_interfacePtr) { $0 }

    return ref!
  }

  static func validateDriver (_ driverPointer: UnsafeMutableRawPointer?, reference: AudioServerPlugInDriverRef = HPLDriver.ref!) -> Bool {
    guard driverPointer != nil else { return false }
    let driver = driverPointer!.assumingMemoryBound(to: (UnsafeMutablePointer<AudioServerPlugInDriverInterface>?).self)
    let valid = reference == driver
    return valid
  }

  static func validateObject (_ objectID: AudioObjectID) -> Bool {
    if getHPLObject(from: objectID) != nil {
      return true
    }
    log("Invalid object for ID: \(objectID)")
    return false
  }

  static func getHPLObject(from objectID: AudioObjectID) -> HPLObject.Type? {
    switch objectID {
    case kObjectID_PlugIn: return HPLPlugIn.self
    case kObjectID_Device: return HPLDevice.self
    case kObjectID_Stream_Input,
         kObjectID_Stream_Output: return HPLStream.self
    case kObjectID_Volume_Output_Master,
         kObjectID_Mute_Output_Master,
         kObjectID_DataSource_Output_Master: return HPLControl.self
    default: return nil
    }
  }

  static func getHPLObjectClassName (from objectID: AudioObjectID) -> String {
    switch objectID {
    case kObjectID_PlugIn: return "PlugIn"
    case kObjectID_Device: return "Device"
    case kObjectID_Stream_Input,
         kObjectID_Stream_Output: return "Stream"
    case kObjectID_Volume_Output_Master,
         kObjectID_Mute_Output_Master,
         kObjectID_DataSource_Output_Master: return "Control"
    default: return "Unknown"
    }
  }

  static func calculateHostTicksPerFrame () {
    // calculate the host ticks per frame
    var theTimeBaseInfo = mach_timebase_info()
    mach_timebase_info(&theTimeBaseInfo)
    var theHostClockFrequency = Float64(theTimeBaseInfo.denom) / Float64(theTimeBaseInfo.numer)
    theHostClockFrequency *= 1000000000.0
    hostTicksPerFrame = theHostClockFrequency / HPLDevice.sampleRate
  }

  static func propertiesUpdated (objectId: AudioObjectID, changedProperties: [AudioObjectPropertyAddress]) {
    guard let host = host, changedProperties.count > 0 else {
      return
    }
    _ = host.pointee.PropertiesChanged(
      host,
      objectId,
      UInt32(changedProperties.count),
      changedProperties
    )
  }
}

//
// HPLInterface.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/EQMInterface.swift
//

import Foundation
import CoreAudio.AudioServerPlugIn

// MARK: - Inheritance
func HPL_QueryInterface (
  inDriver: UnsafeMutableRawPointer?,
  inUUID: REFIID,
  outInterface: UnsafeMutablePointer<LPVOID?>?
) -> HRESULT {
  // This function is called by the HAL to get the interface to talk to the plug-in through.
  // AudioServerPlugIns are required to support the IUnknown interface and the
  // AudioServerPlugInDriverInterface. As it happens, all interfaces must also provide the
  // IUnknown interface, so we can always just return the single interface we made with
  // gAudioServerPlugInDriverInterfacePtr regardless of which one is asked for.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  // log("Invoked HPL_QueryInterface()")
  let uuid = CFUUIDCreateFromUUIDBytes(nil, inUUID)
  if uuid == nil || outInterface == nil {
    return kAudioHardwareIllegalOperationError
  }

  guard CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPluginDriverInterfaceUUID) else { return HRESULT.noInterface }

  HPLDriver.refCounter.wrappingIncrement()
  outInterface!.pointee = UnsafeMutableRawPointer(HPLDriver.ref)

  // log("HPL_QueryInterface() -> \(String(describing: HPLDriver.ref))")

  return HRESULT.ok
}

func HPL_AddRef (inDriver: UnsafeMutableRawPointer?) -> ULONG {
  // This call returns the resulting reference count after the increment.
  guard HPLDriver.validateDriver(inDriver) else { return ULONG(kAudioHardwareBadObjectError) }
  // log("Invoked HPL_AddRef()")

  return ULONG(HPLDriver.refCounter.incrementThenLoad())
}

func HPL_Release (inDriver: UnsafeMutableRawPointer?) -> ULONG {
  // This call returns the resulting reference count after the decrement.
  guard HPLDriver.validateDriver(inDriver) else { return ULONG(kAudioHardwareBadObjectError) }
  // log("Invoked HPL_Release()")
  return ULONG(HPLDriver.refCounter.wrappingDecrementThenLoad())
}

// MARK: - Basic Operations
func HPL_Initialize (inDriver: AudioServerPlugInDriverRef, inHost: AudioServerPlugInHostRef) -> OSStatus {
  // This method is called to initialize the instance of the plug-in.
  // The job of this method is, as the name implies, to get the driver initialized. One specific
  // thing that needs to be done is to store the AudioServerPlugInHostRef so that it can be used
  // later. Note that when this call returns, the HAL will scan the various lists the driver
  // maintains (such as the device list) to get the inital set of objects the driver is
  // publishing. So, there is no need to notifiy the HAL about any objects created as part of the
  // execution of this method.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  HPLDevice.debug = DriverDebug()
  HPLDevice.debug?.set(\.phase, 1)
  HPLDevice.debug?.bump(\.initializeCalled)

  HPLDriver.host = inHost

  HPLDriver.calculateHostTicksPerFrame()
  HPLDevice.debug?.set(\.phase, 2)

  HPLDevice.shmWriter = DriverShmWriter()
  HPLDevice.debug?.set(\.shmOk, HPLDevice.shmWriter != nil ? 1 : 99)
  HPLDevice.debug?.set(\.phase, 3)

  return noErr
}

func HPL_CreateDevice (
  inDriver: AudioServerPlugInDriverRef,
  inDescription: CFDictionary,
  inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>,
  outDeviceObjectID: UnsafeMutablePointer<AudioObjectID>
) -> OSStatus {
  // Tells the plug-in to create a new device based on the given description.
  // This method is used to tell a driver that implements the Transport Manager semantics to
  // create an AudioEndpointDevice from a set of AudioEndpoints. Since this driver is not a
  // Transport Manager, we just check the arguments and return
  // kAudioHardwareUnsupportedOperationError.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  return kAudioHardwareUnsupportedOperationError
}

func HPL_DestroyDevice (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID) -> OSStatus {
  // Called to tell the plug-in about to destroy the given device.
  // This method is used to tell a driver that implements the Transport Manager semantics to
  // destroy an AudioEndpointDevice. Since this driver is not a Transport Manager, we just check
  // the arguments and return kAudioHardwareUnsupportedOperationError.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  return kAudioHardwareUnsupportedOperationError
}

func HPL_AddDeviceClient (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>) -> OSStatus {
  // Called to tell the plug-in about a new client of the Host for a particular device.
  // This method is used to inform the driver about a new client that is using the given device.
  // This allows the device to act differently depending on who the client is. This driver only
  // tracks the clients so that custom property setters can inspect who is calling.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  HPLClients.add(HPLClient(from: inClientInfo.pointee))

  return noErr
}

func HPL_RemoveDeviceClient (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>) -> OSStatus {
  // Called to tell the plug-in about a client that is no longer using the device.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  let client = HPLClient(from: inClientInfo.pointee)
  HPLClients.remove(client)

  return noErr
}

func HPL_PerformDeviceConfigurationChange (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inChangeAction: UInt64,
  inChangeInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  // This is called by the Host to allow the device to perform a configuration change that had been previously requested via a call to the Host method, RequestDeviceConfigurationChange().
  // The HAL guarantees that IO will be stopped while this method is in progress. The HAL will
  // also handle figuring out exactly what changed for the non-control related properties. This
  // means that the only notifications that would need to be sent here would be for either
  // custom properties the HAL doesn't know about or for controls.
  //
  // For the device implemented by this driver, only sample rate changes go through this process
  // as it is the only state that can be changed for the device that isn't a control. For this
  // change, the new sample rate is passed in the inChangeAction argument.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  HPLDevice.debug?.bump(\.performConfigCount)
  HPLDevice.debug?.set(\.lastPerformAction, inChangeAction)
  if !kHPLDeviceSupportedSampleRates.contains(where: { UInt64($0) == inChangeAction }) { return kAudioHardwareBadObjectError }

  HPLDriver.mutex.lock()

  HPLDevice.sampleRate = Float64(inChangeAction)
  HPLDriver.calculateHostTicksPerFrame()

  HPLDriver.mutex.unlock()
//  log("HPL_PerformDeviceConfigurationChange() - HPLDevice.sampleRate = \(HPLDevice.sampleRate) | hostTicksPerFrame = \(String(describing: HPLDriver.hostTicksPerFrame))")

  return noErr
}

func HPL_AbortDeviceConfigurationChange (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inChangeAction: UInt64,
  inChangeInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  // This is called by the Host to tell the plug-in not to perform a configuration change that had been requested via a call to the Host method, RequestDeviceConfigurationChange().
  // This method is called to tell the driver that a request for a config change has been denied.
  // This provides the driver an opportunity to clean up any state associated with the request.
  // For this driver, an aborted config change requires no action. So we just check the arguments
  // and return
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  return noErr
}

// MARK: - Property Operations
// Note that for each object, this driver implements all the required properties plus a few
// extras that are useful but not required. There is more detailed commentary about each
// property in the HPLPlugIn.getPropertyData() and HPLDevice.getPropertyData() methods.

func HPL_HasProperty (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>
) -> DarwinBoolean {
  // This method returns whether or not the given object has the given property.
  let address = inAddress.pointee

  // log("Invoking: \(HPLDriver.getHPLObjectClassName(from: inObjectID)).hasProperty(\(propertyName(address.mSelector)))")
  let hasProperty: Bool = ({
    guard HPLDriver.validateDriver(inDriver) else { return false }
    if let obj = HPLDriver.getHPLObject(from: inObjectID) {
      return obj.hasProperty(objectID: inObjectID, address: address)
    } else {
      return false
    }
  })()
//  log("\(HPLDriver.getHPLObjectClassName(from: inObjectID)).hasProperty(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(hasProperty)")

  return DarwinBoolean(hasProperty)
}

func HPL_IsPropertySettable (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  outIsSettable: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
  let address = inAddress.pointee
  // This method returns whether or not the given property on the object can have its value changed.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  // log("Invoking: \(HPLDriver.getHPLObjectClassName(from: inObjectID)).isPropertySettable(\(propertyName(inAddress.pointee.mSelector)))")
  let isSettable = DarwinBoolean(({
    if let obj = HPLDriver.getHPLObject(from: inObjectID) {
      return obj.isPropertySettable(objectID: inObjectID, address: address)
    } else {
      return false
    }
  })())
//  log("\(HPLDriver.getHPLObjectClassName(from: inObjectID)).getPropertySettable(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(isSettable)")

  outIsSettable.pointee = isSettable

  return noErr
}

func HPL_GetPropertyDataSize (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  inQualifierDataSize: UInt32,
  inQualifierData: UnsafeRawPointer?,
  outDataSize: UnsafeMutablePointer<UInt32>
) -> OSStatus {
  let address = inAddress.pointee

  // This method returns the byte size of the property's data.
  guard HPLDriver.validateDriver(inDriver) && HPLDriver.validateObject(inObjectID) else { return kAudioHardwareBadObjectError }

  let size = ({ () -> UInt32? in
    if let obj = HPLDriver.getHPLObject(from: inObjectID) {
      return obj.getPropertyDataSize(objectID: inObjectID, address: address)
    } else {
      return nil
    }
  })()
  log("\(HPLDriver.getHPLObjectClassName(from: inObjectID)).getPropertyDataSize(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(size ?? 0)")

  if size != nil {
    outDataSize.pointee = size!
    return noErr
  } else {
    return kAudioHardwareUnknownPropertyError
  }
}

func HPL_GetPropertyData (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  inQualifierDataSize: UInt32,
  inQualifierData: UnsafeRawPointer?,
  inDataSize: UInt32,
  outDataSize: UnsafeMutablePointer<UInt32>,
  outData: UnsafeMutableRawPointer
) -> OSStatus {
  let address = inAddress.pointee

  // Fetches the data of the given property and places it in the provided buffer.
  guard HPLDriver.validateDriver(inDriver) && HPLDriver.validateObject(inObjectID) else {
//    log("Invalid driver or object id while in HPL_GetPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))")
    return kAudioHardwareBadObjectError
  }

   log("Invoking: \(HPLDriver.getHPLObjectClassName(from: inObjectID)).getPropertyData(\(propertyName(inAddress.pointee.mSelector))) - Size requested: \(inDataSize)")

  let data = ({ () -> HPLObjectProperty? in
    if let obj = HPLDriver.getHPLObject(from: inObjectID) {
      return obj.getPropertyData(objectID: inObjectID, address: address, inData: inQualifierData)
    } else {
      return nil
    }
  })()
  log("\(HPLDriver.getHPLObjectClassName(from: inObjectID)).getPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) - Size requested: \(inDataSize) = \(String(describing: data))")
  if data != nil {
    let status = data!.write(to: outData, size: outDataSize, requestedSize: inDataSize)
    return status
  } else {
    outDataSize.pointee = 0
    return kAudioHardwareUnknownPropertyError
  }
}

func HPL_SetPropertyData (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  inQualifierDataSize: UInt32,
  inQualifierData: UnsafeRawPointer?,
  inDataSize: UInt32,
  inData: UnsafeRawPointer
) -> OSStatus {
  let address = inAddress.pointee
  // Tells an object to change the value of the given property.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  log("PID(\(inClientProcessID)) \(HPLDriver.getHPLObjectClassName(from: inObjectID)).setPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(String(describing: inData))")

  if let obj = HPLDriver.getHPLObject(from: inObjectID) {
    var changedProperties: [AudioObjectPropertyAddress] = []
    let status = obj.setPropertyData(
      client: HPLClients.get(processId: inClientProcessID),
      objectID: inObjectID,
      address: address,
      data: inData,
      changedProperties: &changedProperties
    )

    HPLDriver.propertiesUpdated(objectId: inObjectID, changedProperties: changedProperties)

    log("\(HPLDriver.getHPLObjectClassName(from: inObjectID)).setPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) - Status: \(status) - Changed Properties: \(changedProperties)")

    return status
  } else {
    return kAudioHardwareBadObjectError
  }
}

// MARK: - IO Operations
func HPL_StartIO (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientID: UInt32) -> OSStatus {
  // This call tells the device that IO is starting for the given client. When this routine
  // returns, the device's clock is running and it is ready to have data read/written. It is
  // important to note that multiple clients can have IO running on the device at the same time.
  // So, work only needs to be done when the first client starts. All subsequent starts simply
  // increment the counter.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  HPLDevice.debug?.bump(\.startIOCount)
  HPLDriver.mutex.lock()
  let status = HPLDevice.startIO()
  HPLDriver.mutex.unlock()
  HPLDevice.debug?.set(\.startIOReturned, 1)
  HPLDevice.debug?.set(\.lastError, status)

  return status
}

func HPL_StopIO (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientID: UInt32) -> OSStatus {
  // This call tells the device that the client has stopped IO. The driver can stop the hardware
  // once all clients have stopped.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  HPLDevice.debug?.bump(\.stopIOCount)
  HPLDriver.mutex.lock()
  let status = HPLDevice.stopIO()
  HPLDriver.mutex.unlock()

  return status
}

func HPL_GetZeroTimeStamp (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  outSampleTime: UnsafeMutablePointer<Float64>,
  outHostTime: UnsafeMutablePointer<UInt64>,
  outSeed: UnsafeMutablePointer<UInt64>
) -> OSStatus {
  // This method returns the current zero time stamp for the device. The HAL models the timing of
  // a device as a series of time stamps that relate the sample time to a host time. The zero
  // time stamps are spaced such that the sample times are the value of
  // kAudioDevicePropertyZeroTimeStampPeriod apart. This is often modeled using a ring buffer
  // where the zero time stamp is updated when wrapping around the ring buffer.
  //
  // For this device, the zero time stamps' sample time increments every kDevice_RingBufferSize
  // frames and the host time increments by kDevice_RingBufferSize * gDevice_HostTicksPerFrame.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  let status = HPLDevice.getZeroTimeStamp(
    outSampleTime: outSampleTime,
    outHostTime: outHostTime,
    outSeed: outSeed
  )

  return status
}

func HPL_WillDoIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  outWillDo: UnsafeMutablePointer<DarwinBoolean>,
  outWillDoInPlace: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
  // Asks the plug-in whether or not the device will perform the given phase of the IO cycle for a particular device.
  // This method returns whether or not the device will do a given IO operation. For this device,
  // we only support reading input data and writing output data.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  var willDo = false
  var willDoInPlace = true

  switch inOperationID {
  case AudioServerPlugInIOOperation.writeMix.rawValue:
    willDo = true
    willDoInPlace = true
    break
  case AudioServerPlugInIOOperation.readInput.rawValue:
    // shm 推送版无输入流。
    willDo = false
    willDoInPlace = true
    break
  default: break
  }

  outWillDo.pointee = DarwinBoolean(willDo)
  outWillDoInPlace.pointee = DarwinBoolean(willDoInPlace)

  return noErr
}

func HPL_BeginIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  inIOBufferFrameSize: UInt32,
  inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus {
  // Tells the plug-in that the Host is about to begin a phase of the IO cycle for a particular device.
  // This is called at the beginning of an IO operation. This device doesn't do anything, so just
  // check the arguments and return.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  return noErr
}

func HPL_DoIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inStreamObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  inIOBufferFrameSize: UInt32,
  inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>,
  ioMainBuffer: UnsafeMutableRawPointer?,
  ioSecondaryBuffer: UnsafeMutableRawPointer?
) -> OSStatus {
  // This is called to actuall perform a given operation.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  guard let sample = ioMainBuffer?.assumingMemoryBound(to: Float32.self) else {
    return noErr
  }

  let client = HPLClients.get(clientId: inClientID)

  let status = HPLDevice.doIO(
    client: client,
    operationID: inOperationID,
    sample: sample,
    cycleInfo: inIOCycleInfo.pointee,
    frameSize: inIOBufferFrameSize
  )

  return status
}

func HPL_EndIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  inIOBufferFrameSize: UInt32,
  inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus {
  // This is called at the end of an IO operation. This device doesn't do anything, so just check
  // the arguments and return.
  guard HPLDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  return noErr
}

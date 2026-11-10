//
// Helpers.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/Helpers.swift
// (debug logging and property-name tables, trimmed to the objects this driver implements)
//

import Foundation
import CoreAudio.AudioServerPlugIn

// MARK: - Pure Functions
func log (_ msg: String) {
  let message = "coreaudiod: HeadphoneLab - \(msg)"
  NSLog(message)
}

// Debug helpers
func propertyName (_ property: AudioObjectPropertySelector) -> String {
  var props: [String] = AudioProperties.filter { $0.0 == property }.map { $0.1 }
  if props.count == 0 { props.append(property.code) }
  return "\(props.joined(separator: " | "))"
}

func scopeName (_ scope: AudioObjectPropertyScope) -> String {
  return AudioPropertyScopes[scope] ?? "Unknown"
}

let AudioPropertyScopes: [AudioObjectPropertyScope: String] = [
  kAudioObjectPropertyScopeGlobal: "Global",
  kAudioObjectPropertyScopeInput: "Input",
  kAudioObjectPropertyScopeOutput: "Output"
]

// This is a hashmap of all properties for debug logging purposes
let AudioProperties: [(AudioObjectPropertySelector, String)] = [
  // Shared
  (kAudioObjectPropertyBaseClass, "kAudioObjectPropertyBaseClass"),
  (kAudioObjectPropertyClass, "kAudioObjectPropertyClass"),
  (kAudioObjectPropertyOwner, "kAudioObjectPropertyOwner"),
  (kAudioObjectPropertyName, "kAudioObjectPropertyName"),
  (kAudioObjectPropertyModelName, "kAudioObjectPropertyModelName"),
  (kAudioObjectPropertyManufacturer, "kAudioObjectPropertyManufacturer"),
  (kAudioObjectPropertyOwnedObjects, "kAudioObjectPropertyOwnedObjects"),
  (kAudioObjectPropertyCustomPropertyInfoList, "kAudioObjectPropertyCustomPropertyInfoList"),

  // Plug-in
  (kAudioPlugInPropertyBundleID, "kAudioPlugInPropertyBundleID"),
  (kAudioPlugInPropertyDeviceList, "kAudioPlugInPropertyDeviceList"),
  (kAudioPlugInPropertyTranslateUIDToDevice, "kAudioPlugInPropertyTranslateUIDToDevice"),
  (kAudioPlugInPropertyResourceBundle, "kAudioPlugInPropertyResourceBundle"),

  // Device
  (kAudioDevicePropertyConfigurationApplication, "kAudioDevicePropertyConfigurationApplication"),
  (kAudioDevicePropertyDeviceUID, "kAudioDevicePropertyDeviceUID"),
  (kAudioDevicePropertyModelUID, "kAudioDevicePropertyModelUID"),
  (kAudioDevicePropertyTransportType, "kAudioDevicePropertyTransportType"),
  (kAudioDevicePropertyRelatedDevices, "kAudioDevicePropertyRelatedDevices"),
  (kAudioDevicePropertyClockDomain, "kAudioDevicePropertyClockDomain"),
  (kAudioDevicePropertyDeviceIsAlive, "kAudioDevicePropertyDeviceIsAlive"),
  (kAudioDevicePropertyDeviceIsRunning, "kAudioDevicePropertyDeviceIsRunning"),
  (kAudioDevicePropertyDeviceCanBeDefaultDevice, "kAudioDevicePropertyDeviceCanBeDefaultDevice"),
  (kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, "kAudioDevicePropertyDeviceCanBeDefaultSystemDevice"),
  (kAudioDevicePropertyLatency, "kAudioDevicePropertyLatency"),
  (kAudioDevicePropertyStreams, "kAudioDevicePropertyStreams"),
  (kAudioObjectPropertyControlList, "kAudioObjectPropertyControlList"),
  (kAudioDevicePropertySafetyOffset, "kAudioDevicePropertySafetyOffset"),
  (kAudioDevicePropertyNominalSampleRate, "kAudioDevicePropertyNominalSampleRate"),
  (kAudioDevicePropertyAvailableNominalSampleRates, "kAudioDevicePropertyAvailableNominalSampleRates"),
  (kAudioDevicePropertyIcon, "kAudioDevicePropertyIcon"),
  (kAudioDevicePropertyIsHidden, "kAudioDevicePropertyIsHidden"),
  (kAudioDevicePropertyPreferredChannelsForStereo, "kAudioDevicePropertyPreferredChannelsForStereo"),
  (kAudioDevicePropertyPreferredChannelLayout, "kAudioDevicePropertyPreferredChannelLayout"),
  (kAudioDevicePropertyZeroTimeStampPeriod, "kAudioDevicePropertyZeroTimeStampPeriod"),

  // Stream
  (kAudioStreamPropertyIsActive, "kAudioStreamPropertyIsActive"),
  (kAudioStreamPropertyDirection, "kAudioStreamPropertyDirection"),
  (kAudioStreamPropertyTerminalType, "kAudioStreamPropertyTerminalType"),
  (kAudioStreamPropertyStartingChannel, "kAudioStreamPropertyStartingChannel"),
  (kAudioStreamPropertyLatency, "kAudioStreamPropertyLatency"),
  (kAudioStreamPropertyVirtualFormat, "kAudioStreamPropertyVirtualFormat"),
  (kAudioStreamPropertyAvailableVirtualFormats, "kAudioStreamPropertyAvailableVirtualFormats"),
  (kAudioStreamPropertyPhysicalFormat, "kAudioStreamPropertyPhysicalFormat"),
  (kAudioStreamPropertyAvailablePhysicalFormats, "kAudioStreamPropertyAvailablePhysicalFormats"),

  // Control
  (kAudioControlPropertyScope, "kAudioControlPropertyScope"),
  (kAudioControlPropertyElement, "kAudioControlPropertyElement"),
  (kAudioLevelControlPropertyScalarValue, "kAudioLevelControlPropertyScalarValue"),
  (kAudioLevelControlPropertyDecibelValue, "kAudioLevelControlPropertyDecibelValue"),
  (kAudioLevelControlPropertyDecibelRange, "kAudioLevelControlPropertyDecibelRange"),
  (kAudioLevelControlPropertyConvertScalarToDecibels, "kAudioLevelControlPropertyConvertScalarToDecibels"),
  (kAudioLevelControlPropertyConvertDecibelsToScalar, "kAudioLevelControlPropertyConvertDecibelsToScalar"),
  (kAudioBooleanControlPropertyValue, "kAudioBooleanControlPropertyValue"),
  (kAudioSelectorControlPropertyCurrentItem, "kAudioSelectorControlPropertyCurrentItem"),
  (kAudioSelectorControlPropertyAvailableItems, "kAudioSelectorControlPropertyAvailableItems"),
  (kAudioSelectorControlPropertyItemName, "kAudioSelectorControlPropertyItemName")
]

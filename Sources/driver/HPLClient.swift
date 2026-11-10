//
// HPLClient.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/EQMClient.swift
// (trimmed: no app-bundle-id helpers, this driver doesn't gate on the caller)
//

import Foundation
import CoreAudio.AudioServerPlugIn

class HPLClient {
  var clientId: UInt32
  var processId: pid_t
  var bundleId: String?

  init (clientId: UInt32, processId: pid_t, bundleId: String? = nil) {
    self.clientId = clientId
    self.processId = processId
    self.bundleId = bundleId
  }

  init (from clientInfo: AudioServerPlugInClientInfo) {
    clientId = clientInfo.mClientID
    processId = clientInfo.mProcessID
    bundleId = clientInfo.mBundleID?.takeUnretainedValue() as String?
  }
}

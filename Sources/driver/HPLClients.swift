//
// HPLClients.swift
// HeadphoneLab driver — ported from eqMac's native/driver/Source/EQMClients.swift
//

import Foundation
import CoreAudio.AudioServerPlugIn

class HPLClients {
  private static let mutex = Mutex()
  static var clients: [UInt32: HPLClient] = [:]

  static func add (_ client: HPLClient) {
    mutex.lock()
    clients[client.clientId] = client
    mutex.unlock()
  }

  static func remove (_ client: HPLClient) {
    mutex.lock()
    clients.removeValue(forKey: client.clientId)
    mutex.unlock()
  }

  static func get (clientId: UInt32) -> HPLClient? {
    mutex.lock()
    let client = clients[clientId]
    mutex.unlock()
    return client
  }

  static func get (processId: pid_t) -> HPLClient? {
    mutex.lock()
    let client = clients.values.first { $0.processId == processId }
    mutex.unlock()
    return client
  }
}

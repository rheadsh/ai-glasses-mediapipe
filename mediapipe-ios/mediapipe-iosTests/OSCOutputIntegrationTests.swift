import Foundation
import Network
import XCTest

@testable import mediapipe_ios

@MainActor
final class OSCOutputIntegrationTests: XCTestCase {
  func testDestinationPersistsButSendingDoesNotAutoEnable() throws {
    let suite = "OSCOutputTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let output = OSCOutput(defaults: defaults)
    output.configure(host: "127.0.0.1", port: 9001, rate: 7, enabled: false)
    let reopened = OSCOutput(defaults: defaults)
    XCTAssertEqual(reopened.host, "127.0.0.1")
    XCTAssertEqual(reopened.port, 9001)
    XCTAssertEqual(reopened.rate, 7)
    XCTAssertFalse(reopened.enabled)
  }

  func testLoopbackReceivesTrackingAndTerminalClear() async throws {
    let suite = "OSCOutputTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let receiver = try LoopbackOSCReceiver()
    defer { receiver.stop() }
    try await waitUntil("UDP listener must acquire an ephemeral port") { receiver.port != nil }
    let output = OSCOutput(defaults: defaults)
    defer { output.shutdown() }
    output.configure(host: "127.0.0.1", port: Int(try XCTUnwrap(receiver.port)), rate: 15, enabled: true)
    try await waitUntil("UDP sender must become ready") { output.status.hasPrefix("UDP listo") }
    output.test()
    try await waitUntil("Independent UDP listener must receive the OSC test message") {
      receiver.contains(OSCMessage(address: "/mediapipe/test", arguments: [.string("rayban"), .int(1)]))
    }

    let empty = VisionAnalysisResult(detections: [], landmarkGroups: [], maskImage: nil,
      summary: "", resultCount: 0, inferenceTimeMilliseconds: 1)
    output.publish(empty, task: .handLandmarkDetection)
    try await waitUntil("Empty tracking results must reach the receiver") {
      receiver.contains(OSCMessage(address: "/mediapipe/handLandmarkDetection/counts",
        arguments: [.int(0), .int(0), .int(0)]))
    }
    output.shutdown()
    try await waitUntil("Shutdown must send active=0 before closing UDP") {
      receiver.contains(OSCMessage(address: "/mediapipe/handLandmarkDetection/active", arguments: [.int(0)]))
    }
    XCTAssertFalse(output.enabled)
  }
}

/// Keeps all received data/connections behind a lock; no XCTest state is accessed
/// from Network.framework's callback queue. The listener is loopback-only.
private final class LoopbackOSCReceiver: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "tests.osc.loopback")
  private let lock = NSLock()
  private var packets: [Data] = []
  private var connections: [NWConnection] = []

  var port: UInt16? { listener.port?.rawValue }

  init() throws {
    let parameters = NWParameters.udp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.lock.lock()
      self.connections.append(connection)
      self.lock.unlock()
      connection.start(queue: self.queue)
      self.receive(on: connection)
    }
    listener.start(queue: queue)
  }

  func contains(_ message: OSCMessage) -> Bool {
    let encoded = message.encoded()
    lock.lock()
    defer { lock.unlock() }
    return packets.contains { $0.range(of: encoded) != nil }
  }

  func stop() {
    listener.cancel()
    lock.lock()
    let connections = connections
    self.connections = []
    lock.unlock()
    for connection in connections { connection.cancel() }
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      if let data {
        self.lock.lock()
        self.packets.append(data)
        self.lock.unlock()
      }
      if error == nil { self.receive(on: connection) }
    }
  }
}

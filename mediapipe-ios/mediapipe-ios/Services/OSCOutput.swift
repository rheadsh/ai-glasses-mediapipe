import Foundation
import Network
import Observation
import SwiftUI

@Observable
@MainActor
final class OSCOutput {
  private(set) var enabled = false
  private(set) var host: String
  private(set) var port: Int
  private(set) var rate: Int
  private(set) var status = "Desactivado"
  private(set) var sentFrames = 0
  private let defaults: UserDefaults
  private var connection: NWConnection?
  private let queue = DispatchQueue(label: "com.rheadsh.mediapipe.osc", qos: .utility)
  private var ready = false
  private var busy = false
  private var lastSent = -Double.infinity
  private var frameID: Int32 = 0
  private var generation = 0
  private var activeTask: MediaPipeVisionTask?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    host = defaults.string(forKey: "osc.host") ?? ""
    port = defaults.object(forKey: "osc.port") as? Int ?? 9000
    rate = defaults.object(forKey: "osc.rate") as? Int ?? 15
  }

  func shutdown() {
    clear(cancelConnection: true)
    generation += 1
    connection = nil
    ready = false
    busy = false
    enabled = false
    status = "Desactivado"
  }

  static func isValid(host: String, port: Int) -> Bool {
    !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !host.contains(where: { $0.isWhitespace || $0 == "/" })
      && (1...65535).contains(port)
  }

  func configure(host: String, port: Int, rate: Int, enabled: Bool) {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValid(host: host, port: port), (1...30).contains(rate) else {
      status = "Introduce una IP o hostname y un puerto entre 1 y 65535."
      return
    }
    clear(cancelConnection: true)
    generation += 1
    connection = nil
    ready = false
    busy = false
    lastSent = -.infinity
    self.host = host
    self.port = port
    self.rate = rate
    self.enabled = enabled
    defaults.set(host, forKey: "osc.host")
    defaults.set(port, forKey: "osc.port")
    defaults.set(rate, forKey: "osc.rate")
    guard enabled else { status = "Desactivado"; return }
    guard let rawPort = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
      self.enabled = false
      status = "Puerto UDP no válido."
      return
    }
    status = "Preparando UDP…"
    let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
    self.connection = connection
    let generation = generation
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        switch state {
        case .ready:
          self.ready = true
          self.status = "UDP listo · recepción sin confirmar"
        case .waiting(let error):
          self.ready = false
          self.status = error.localizedDescription
        case .failed(let error):
          // NWConnection does not leave .failed on its own: rebuild it shortly.
          self.ready = false
          self.status = error.localizedDescription
          self.scheduleReconnect(generation: generation)
        case .cancelled: self.ready = false
        default: break
        }
      }
    }
    connection.start(queue: queue)
  }

  private func scheduleReconnect(generation: Int) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, self.enabled, self.generation == generation else { return }
      self.configure(host: self.host, port: self.port, rate: self.rate, enabled: true)
    }
  }

  func test() {
    send([OSCMessage(address: "/mediapipe/test", arguments: [.string("rayban"), .int(1)])], force: true)
  }

  func publish(_ result: VisionAnalysisResult, task: MediaPipeVisionTask) {
    guard enabled, ready, !busy else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSent >= 1 / Double(rate) else { return }
    activeTask = task
    send(OSCTrackingMessages.make(result, task: task))
  }

  func clear(cancelConnection: Bool = false) {
    guard let task = activeTask else {
      if cancelConnection { connection?.cancel() }
      return
    }
    activeTask = nil
    let root = "/mediapipe/\(task.rawValue)"
    // Independent from an in-flight data frame: receivers should clear on active=0.
    let messages = [
      OSCMessage(address: root + "/active", arguments: [.int(0)]),
      OSCMessage(address: root + "/counts", arguments: [.int(0), .int(0), .int(0)])
    ]
    send(messages, force: true, cancelAfterSending: cancelConnection)
  }

  private func send(_ messages: [OSCMessage], force: Bool = false, cancelAfterSending: Bool = false) {
    guard enabled, ready, let connection, force || !busy else {
      if cancelAfterSending { self.connection?.cancel() }
      return
    }
    if !force { busy = true; lastSent = ProcessInfo.processInfo.systemUptime }
    frameID = frameID == .max ? 1 : frameID + 1
    let frameID = frameID
    let generation = generation
    // Encoding and network submission run outside the main actor. No frame queue accumulates.
    queue.async { [weak self] in
      let packets = OSCPacketEncoder.packets(messages: messages, frameID: frameID)
      let group = DispatchGroup()
      let errors = OSCTransmissionError()
      for packet in packets {
        group.enter()
        connection.send(content: packet, completion: .contentProcessed { error in
          if let error { errors.set(error.localizedDescription) }
          group.leave()
        })
      }
      group.notify(queue: .main) {
        if cancelAfterSending { connection.cancel() }
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          if !force { self.busy = false }
          if let error = errors.message {
            self.status = error
          } else {
            self.sentFrames += 1
            self.status = "UDP enviado · recepción sin confirmar"
          }
        }
      }
    }
  }
}

private final class OSCTransmissionError: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  func set(_ message: String) { lock.lock(); value = message; lock.unlock() }
  var message: String? { lock.lock(); defer { lock.unlock() }; return value }
}

enum OSCTrackingMessages {
  static func make(_ result: VisionAnalysisResult, task: MediaPipeVisionTask) -> [OSCMessage] {
    let root = "/mediapipe/\(task.rawValue)"
    var messages = [
      OSCMessage(address: root + "/active", arguments: [.int(1)]),
      OSCMessage(address: root + "/counts", arguments: [
        .int(Int32(result.resultCount)), .int(Int32(result.detections.count)),
        .int(Int32(result.landmarkGroups.count))]),
      OSCMessage(address: root + "/inferenceMs", arguments: [.float(Float(result.inferenceTimeMilliseconds))])
    ]
    for (index, detection) in result.detections.enumerated() {
      let box = detection.normalizedBoundingBox
      messages.append(OSCMessage(address: root + "/detection/\(index)", arguments: [
        .string(detection.label), .float(detection.score), .float(Float(box.minX)),
        .float(Float(box.minY)), .float(Float(box.width)), .float(Float(box.height))]))
    }
    for (index, group) in result.landmarkGroups.enumerated() {
      messages.append(OSCMessage(address: root + "/landmarks/\(index)/count", arguments: [.int(Int32(group.points.count))]))
      // 32 points per message keeps face/holistic data below the UDP packet size limit.
      for offset in stride(from: 0, to: group.points.count, by: 32) {
        let points = group.points[offset..<min(offset + 32, group.points.count)]
        messages.append(OSCMessage(address: root + "/landmarks/\(index)/points", arguments:
          [.int(Int32(offset))] + points.flatMap { [.float(Float($0.x)), .float(Float($0.y))] }))
      }
    }
    messages += result.oscMessages.map { OSCMessage(address: root + $0.address, arguments: $0.arguments) }
    return messages
  }
}

struct OSCSettingsView: View {
  let output: OSCOutput
  @Environment(\.dismiss) private var dismiss
  @State private var host: String
  @State private var port: String
  @State private var rate: Int
  @State private var enabled: Bool

  init(output: OSCOutput) {
    self.output = output
    _host = State(initialValue: output.host)
    _port = State(initialValue: String(output.port))
    _rate = State(initialValue: output.rate)
    _enabled = State(initialValue: output.enabled)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Destino OSC · UDP") {
          Toggle("Enviar tracking por OSC", isOn: $enabled)
          TextField("IP o hostname del receptor", text: $host)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("osc_host")
          TextField("Puerto", text: $port).keyboardType(.numberPad)
            .accessibilityIdentifier("osc_port")
          Stepper("Máximo \(rate) envíos/s", value: $rate, in: 1...30)
        }
        Section {
          Text("Conecta el iPhone y el receptor a la misma red. Configura el receptor para escuchar UDP en este puerto y permite el acceso a la red local.")
          Text("Se envía únicamente la Vision Task seleccionada. OSC se activa manualmente en cada apertura de la app.")
        }
        Section("Estado del destino aplicado") {
          Text(output.status)
          Text("\(output.sentFrames) envíos completados localmente")
          Button("Enviar prueba /mediapipe/test") { output.test() }
            .disabled(!output.enabled)
          Text("UDP no confirma recepción. Comprueba el mensaje en TouchDesigner, Max, Pure Data u otro receptor OSC.")
            .font(.caption)
        }
      }
      .navigationTitle("Salida OSC")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Aplicar") {
            output.configure(host: host, port: Int(port) ?? 0, rate: rate, enabled: enabled)
            dismiss()
          }
          .disabled(!OSCOutput.isValid(host: host, port: Int(port) ?? 0))
        }
      }
    }
  }
}

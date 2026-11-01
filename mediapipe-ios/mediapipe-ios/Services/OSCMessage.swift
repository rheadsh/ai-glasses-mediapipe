import Foundation

/// OSC 1.0 wire types. All numeric values are encoded in network byte order.
enum OSCArgument: Sendable, Equatable {
  case int(Int32)
  case float(Float)
  case string(String)
}

struct OSCMessage: Sendable {
  let address: String
  let arguments: [OSCArgument]

  func encoded() -> Data {
    var data = Self.string(address)
    let tags = arguments.map { argument in
      switch argument {
      case .int: return "i"
      case .float: return "f"
      case .string: return "s"
      }
    }.joined()
    data.append(Self.string("," + tags))
    for argument in arguments {
      switch argument {
      case .int(let value): Self.append(UInt32(bitPattern: value), to: &data)
      case .float(let value): Self.append(value.bitPattern, to: &data)
      case .string(let value): data.append(Self.string(value))
      }
    }
    return data
  }

  private static func string(_ value: String) -> Data {
    // OSC 1.0 strings are ASCII and cannot contain embedded nulls.
    var data = Data(value.unicodeScalars.map { $0.value > 0 && $0.value < 128 ? UInt8($0.value) : 63 })
    data.append(0)
    while data.count % 4 != 0 { data.append(0) }
    return data
  }

  private static func append(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
}

/// Split a frame into MTU-friendly immediate bundles, each carrying the frame ID.
/// Receivers must use the frame ID and counts; UDP can drop or reorder packets.
enum OSCPacketEncoder {
  static func packets(messages: [OSCMessage], frameID: Int32, maximumSize: Int = 1200) -> [Data] {
    let frame = OSCMessage(address: "/mediapipe/frame", arguments: [.int(frameID)]).encoded()
    let header = Data([35, 98, 117, 110, 100, 108, 101, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    func append(_ message: Data, to packet: inout Data) {
      var size = UInt32(message.count).bigEndian
      withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
      packet.append(message)
    }
    var packet = header
    append(frame, to: &packet)
    let base = packet
    var packets: [Data] = []
    for message in messages {
      let encoded = message.encoded()
      // A single message that cannot fit in a datagram (e.g. an unexpectedly long label)
      // is dropped rather than crashing the app; callers chunk the large payloads.
      guard base.count + 4 + encoded.count <= maximumSize else { continue }
      if packet.count + 4 + encoded.count > maximumSize {
        packets.append(packet)
        packet = base
      }
      append(encoded, to: &packet)
    }
    if packet.count > base.count { packets.append(packet) }
    return packets
  }
}

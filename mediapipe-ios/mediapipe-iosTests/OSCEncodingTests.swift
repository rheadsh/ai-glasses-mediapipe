/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import CoreGraphics
import XCTest

@testable import mediapipe_ios

final class OSCEncodingTests: XCTestCase {
  func testEncodesOSCTypesPaddingAndNetworkByteOrder() {
    let packet = OSCMessage(address: "/x", arguments: [.int(-1), .float(1), .string("hi")]).encoded()
    XCTAssertEqual(Array(packet), [
      47, 120, 0, 0, 44, 105, 102, 115, 0, 0, 0, 0,
      255, 255, 255, 255, 63, 128, 0, 0, 104, 105, 0, 0
    ])
  }

  func testChunksLargeFramesIntoImmediateBundlesWithFrameID() {
    let messages = (0..<100).map { index in
      OSCMessage(address: "/points", arguments: [.int(Int32(index))] + Array(repeating: .float(0.5), count: 64))
    }
    let packets = OSCPacketEncoder.packets(messages: messages, frameID: 42)
    XCTAssertGreaterThan(packets.count, 1)
    var decodedMessages = 0
    for packet in packets {
      XCTAssertLessThanOrEqual(packet.count, 1200)
      XCTAssertEqual(packet.count % 4, 0)
      XCTAssertEqual(Array(packet.prefix(16)), [35, 98, 117, 110, 100, 108, 101, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      var offset = 16
      var elements: [Data] = []
      while offset < packet.count {
        let size = packet[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        elements.append(packet.subdata(in: offset..<offset + size))
        offset += size
      }
      XCTAssertEqual(elements.first, OSCMessage(address: "/mediapipe/frame", arguments: [.int(42)]).encoded())
      decodedMessages += elements.count - 1
    }
    XCTAssertEqual(decodedMessages, messages.count)
  }

  func testEveryTaskHasZeroCountsForEmptyResults() {
    let empty = VisionAnalysisResult(detections: [], landmarkGroups: [], maskImage: nil, summary: "", resultCount: 0, inferenceTimeMilliseconds: 5)
    for task in MediaPipeVisionTask.allCases {
      let messages = OSCTrackingMessages.make(empty, task: task)
      let root = "/mediapipe/\(task.rawValue)"
      XCTAssertEqual(messages.first?.address, root + "/active")
      XCTAssertEqual(messages.first?.arguments, [.int(1)])
      XCTAssertEqual(messages.first { $0.address == root + "/counts" }?.arguments, [.int(0), .int(0), .int(0)])
    }
  }

  func testTrackingMessagesCarryGeometryAndTaskSpecificValues() {
    let result = VisionAnalysisResult(
      oscMessages: [OSCMessage(address: "/gesture/0", arguments: [.string("Open_Palm"), .float(0.9)])],
      detections: [ObjectDetection(label: "cup", score: 0.8, normalizedBoundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))],
      landmarkGroups: [VisionLandmarkGroup(points: Array(repeating: CGPoint(x: 0.25, y: 0.75), count: 70), connections: [], style: .green)],
      maskImage: nil, summary: "", resultCount: 1, inferenceTimeMilliseconds: 10)
    let messages = OSCTrackingMessages.make(result, task: .gestureRecognition)
    let root = "/mediapipe/gestureRecognition"
    XCTAssertEqual(messages.first { $0.address == root + "/detection/0" }?.arguments,
      [.string("cup"), .float(0.8), .float(0.1), .float(0.2), .float(0.3), .float(0.4)])
    let chunks = messages.filter { $0.address == root + "/landmarks/0/points" }
    XCTAssertEqual(chunks.map { $0.arguments[0] }, [.int(0), .int(32), .int(64)])
    XCTAssertEqual(chunks.map { $0.arguments.count }, [65, 65, 13])
    XCTAssertEqual(messages.last?.arguments, [.string("Open_Palm"), .float(0.9)])
  }

  @MainActor
  func testRejectsInvalidDestinations() {
    XCTAssertFalse(OSCOutput.isValid(host: "", port: 9000))
    XCTAssertFalse(OSCOutput.isValid(host: "http://localhost", port: 9000))
    XCTAssertFalse(OSCOutput.isValid(host: "localhost", port: 0))
    XCTAssertFalse(OSCOutput.isValid(host: "localhost", port: 65536))
    XCTAssertTrue(OSCOutput.isValid(host: "192.168.1.10", port: 9000))
  }
}

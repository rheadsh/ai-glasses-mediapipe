/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import MWDATMockDevice
import Observation
import SwiftUI
import XCTest

@testable import mediapipe_ios

@MainActor
final class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockGlasses?
  private var cameraKit: MockCameraKit?
  private var viewModel: StreamSessionViewModel?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()

    MockDeviceKit.shared.enable()

    // Pair mock device and set up camera kit
    let pairedMockDevice = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.services.camera

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()
    pairedMockDevice.don()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    viewModel?.endSession()
    viewModel = nil
    await MockDeviceKit.shared.disable()
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4")
    else {
      XCTFail("Test resources not found")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    self.viewModel = viewModel

    // Wait for the mock device to be detected
    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    await observeUntil(timeout: 10) {
      viewModel.isStreaming && viewModel.hasReceivedFirstFrame && viewModel.currentVideoFrame != nil
    }

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Stop streaming
    viewModel.stopSession()

    // Wait for session to stop
    await observeUntil(timeout: 5) { !viewModel.isStreaming }

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4"),
      let imageURL = Bundle.main.url(forResource: "plant", withExtension: "png")
    else {
      XCTFail("Test resources not found")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)
    camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    self.viewModel = viewModel

    // Wait for the mock device to be detected
    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    await observeUntil(timeout: 10) {
      viewModel.isStreaming && viewModel.hasReceivedFirstFrame && viewModel.currentVideoFrame != nil
    }

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    await observeUntil(timeout: 10) { viewModel.capturedPhoto != nil }

    // Verify photo captured while maintaining stream (allow for some timing flexibility)
    XCTAssertTrue(viewModel.capturedPhoto != nil)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    viewModel.stopSession()
    await observeUntil(timeout: 5) { !viewModel.isStreaming }

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }
}

final class DetectionGeometryTests: XCTestCase {
  func testNormalizesAndClipsBoundingBoxes() {
    let result = DetectionGeometry.normalized(
      CGRect(x: -10, y: 20, width: 70, height: 100),
      imageSize: CGSize(width: 100, height: 200)
    )

    XCTAssertEqual(result.minX, 0, accuracy: 0.0001)
    XCTAssertEqual(result.minY, 0.1, accuracy: 0.0001)
    XCTAssertEqual(result.width, 0.6, accuracy: 0.0001)
    XCTAssertEqual(result.height, 0.5, accuracy: 0.0001)
  }

  func testProjectsNormalizedBoxIntoAspectFillPreview() {
    let result = DetectionGeometry.aspectFillRect(
      normalizedBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
      imageSize: CGSize(width: 360, height: 640),
      containerSize: CGSize(width: 400, height: 400)
    )

    XCTAssertEqual(result.minX, 100, accuracy: 0.01)
    XCTAssertEqual(result.minY, 22.22, accuracy: 0.01)
    XCTAssertEqual(result.width, 200, accuracy: 0.01)
    XCTAssertEqual(result.height, 355.56, accuracy: 0.01)
  }

  func testVisionTaskCatalogMatchesMediaPipeTasksVisionForIOS() {
    XCTAssertEqual(MediaPipeVisionTask.allCases.count, 11)
    XCTAssertEqual(MediaPipeVisionTask.allCases.first, .objectDetection)
    XCTAssertEqual(MediaPipeVisionTask.allCases.last, .holisticLandmarkDetection)
    XCTAssertEqual(
      MediaPipeVisionTask.allCases.filter(\.isConfigured),
      MediaPipeVisionTask.allCases
    )
  }

  func testMapsAspectFillTouchBackToImageCoordinates() throws {
    let point = try XCTUnwrap(
      DetectionGeometry.normalizedImagePoint(
        aspectFillPoint: CGPoint(x: 200, y: 200),
        imageSize: CGSize(width: 360, height: 640),
        containerSize: CGSize(width: 400, height: 400)
      )
    )
    XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
  }

  func testAllBundledVisionTasksInitializeAndRunOneAtATime() async throws {
    let imagePath = try XCTUnwrap(Bundle.main.path(forResource: "plant", ofType: "png"))
    let image = try XCTUnwrap(UIImage(contentsOfFile: imagePath))
    let analyzer = MediaPipeVisionAnalyzer()

    for task in MediaPipeVisionTask.allCases {
      let modelPath: String?
      if task == .objectDetection {
        modelPath = MediaPipeObjectDetector.bundledModelPath(for: .efficientDetLite0)
      } else {
        modelPath = task.bundledModelPath
      }
      let path = try XCTUnwrap(modelPath, "Missing bundled model for \(task.displayName)")

      try await withCheckedThrowingContinuation { continuation in
        analyzer.configure(task: task, modelPath: path) { result in
          continuation.resume(with: result)
        }
      }

      let result: VisionAnalysisResult = try await withCheckedThrowingContinuation {
        continuation in
        analyzer.submit(image: image, interactionPoint: CGPoint(x: 0.5, y: 0.5)) { result in
          continuation.resume(with: result)
        }
      }
      XCTAssertGreaterThan(result.inferenceTimeMilliseconds, 0, task.displayName)
      let oscMessages = OSCTrackingMessages.make(result, task: task)
      XCTAssertFalse(OSCPacketEncoder.packets(messages: oscMessages, frameID: 1).isEmpty)
      switch task {
      case .imageClassification:
        XCTAssertTrue(result.oscMessages.contains { $0.address.hasPrefix("/category/") })
      case .imageEmbedding:
        let dimensions = result.oscMessages.first { $0.address == "/embedding/dimensions" }
        guard case .int(let count) = dimensions?.arguments.first else {
          XCTFail("Expected numeric embedding dimensions")
          continue
        }
        XCTAssertGreaterThan(count, 0)
        let values = result.oscMessages.filter { $0.address == "/embedding/values" }
        XCTAssertEqual(values.reduce(0) { $0 + $1.arguments.count - 1 }, Int(count))
      case .imageSegmentation, .interactiveSegmentation:
        XCTAssertEqual(result.oscMessages.first { $0.address == "/mask/size" }?.arguments, [.int(16), .int(16)])
        XCTAssertEqual(result.oscMessages.filter { $0.address == "/mask/row" }.count, 16)
      default: break
      }

    }

    analyzer.reset()
  }

  func testMediaPipeProcessesBundledFixture() async throws {
    for model in ObjectDetectionModel.allCases {
      XCTAssertNotNil(
        MediaPipeObjectDetector.bundledModelPath(for: model),
        "Missing bundled model: \(model.resourceName).tflite"
      )
    }

    let modelPath = try XCTUnwrap(
      MediaPipeObjectDetector.bundledModelPath(for: .efficientDetLite0)
    )
    let imagePath = try XCTUnwrap(Bundle.main.path(forResource: "plant", ofType: "png"))
    let image = try XCTUnwrap(UIImage(contentsOfFile: imagePath))
    let detector = MediaPipeObjectDetector(
      modelPath: modelPath,
      scoreThreshold: 0.2,
      maxResults: 5
    )

    try await withCheckedThrowingContinuation { continuation in
      detector.prepare { result in
        continuation.resume(with: result)
      }
    }

    let result: ObjectDetectionResult = try await withCheckedThrowingContinuation { continuation in
      detector.submit(image: image) { result in
        continuation.resume(with: result)
      }
    }

    XCTAssertGreaterThan(result.inferenceTimeMilliseconds, 0)
    for detection in result.detections {
      XCTAssertGreaterThanOrEqual(detection.normalizedBoundingBox.minX, 0)
      XCTAssertGreaterThanOrEqual(detection.normalizedBoundingBox.minY, 0)
      XCTAssertLessThanOrEqual(detection.normalizedBoundingBox.maxX, 1)
      XCTAssertLessThanOrEqual(detection.normalizedBoundingBox.maxY, 1)
    }
  }
}

// MARK: - Test Helpers

/// Thread-safe one-shot flag for protecting continuation resumption.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  func tryResume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return false }
    resumed = true
    return true
  }
}

/// Reactively waits for a condition on @Observable objects to become true.
/// Uses `withObservationTracking` to wake up immediately on property changes
/// instead of polling on a fixed interval.
@MainActor
private func observeUntil(
  timeout: TimeInterval,
  file: StaticString = #filePath,
  line: UInt = #line,
  condition: @escaping () -> Bool
) async {
  guard !condition() else { return }

  let deadline = ContinuousClock.now + .seconds(timeout)

  while !condition() {
    guard ContinuousClock.now < deadline else {
      XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
      return
    }

    await withUnsafeContinuation { cont in
      let once = ResumeOnce()

      withObservationTracking {
        _ = condition()
      } onChange: {
        if once.tryResume() { cont.resume() }
      }

      // Periodic fallback so we can re-evaluate the deadline
      Task {
        try? await Task.sleep(for: .milliseconds(100))
        if once.tryResume() { cont.resume() }
      }
    }
  }
}

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

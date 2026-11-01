/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 * This source code is licensed under the license found in the root LICENSE file.
 */

import MWDATCore
import MWDATMockDevice
import XCTest

@testable import mediapipe_ios

/// DAT 1.0.1 uses process-global SDK/mock state. Run this suite serially,
/// with the app's normal simulator signing (not CODE_SIGNING_ALLOWED=NO).
@MainActor
final class DATStreamingIntegrationTests: XCTestCase {
  private var mockDevice: MockGlasses?
  private var camera: MockCameraKit?
  private var viewModel: StreamSessionViewModel?
  private var didEnableMocks = false

  override func setUp() async throws {
    try await super.setUp()
    do {
      try Wearables.configure()
    } catch WearablesError.alreadyConfigured {
      // The host app configures DAT at launch. This is the only expected error.
    } catch {
      // Never access Wearables.shared or enable mocks after configuration fails.
      throw error
    }

    MockDeviceKit.shared.enable(config: MockDeviceKitConfig(
      initiallyRegistered: true, initialPermissionsGranted: true))
    didEnableMocks = true
    let device = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mockDevice = device
    camera = device.services.camera
    device.powerOn()
    device.unfold()
    device.don()
  }

  override func tearDown() async throws {
    var cleanupError: Error?
    if let viewModel {
      viewModel.stopSession()
      do {
        try await waitUntil("Stream must reach stopped before releasing the session") {
          viewModel.streamingStatus == .stopped
        }
      } catch { cleanupError = error }
      viewModel.endSession()
      viewModel.oscOutput.shutdown()
    }
    viewModel = nil
    if didEnableMocks {
      // The async overload waits for SDK teardown, preventing cross-test races.
      await MockDeviceKit.shared.disable()
    }
    didEnableMocks = false
    mockDevice = nil
    camera = nil
    try await super.tearDown()
    if let cleanupError { throw cleanupError }
  }

  func testVideoStreamingStartsAndStops() async throws {
    let viewModel = try await startStreaming()
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)

    viewModel.stopSession()
    try await waitUntil("Stopping must reach the terminal stream state") {
      viewModel.streamingStatus == .stopped
    }
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertNil(viewModel.currentVideoFrame)
  }

  func testPhotoCaptureKeepsStreamActive() async throws {
    let camera = try XCTUnwrap(camera)
    camera.setCapturedImage(fileURL: try fixtureURL("plant", extension: "png"))
    let viewModel = try await startStreaming()

    viewModel.capturePhoto()
    try await waitUntil("Photo capture must produce a preview", timeout: 10) {
      viewModel.capturedPhoto != nil || viewModel.showPhotoCaptureError
    }
    XCTAssertFalse(viewModel.showPhotoCaptureError)
    XCTAssertNotNil(viewModel.capturedPhoto)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertEqual(viewModel.streamingStatus, .streaming)

    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)
  }

  private func startStreaming() async throws -> StreamSessionViewModel {
    let camera = try XCTUnwrap(camera)
    camera.setCameraFeed(fileURL: try fixtureURL("plant", extension: "mp4"))
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    self.viewModel = viewModel
    // Streaming tests exercise DAT; actual inference is covered by MediaPipePipelineTests.
    viewModel.isVisionAnalysisEnabled = false
    try await waitUntil("Mock glasses must become available") { viewModel.hasActiveDevice }
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertNil(viewModel.currentVideoFrame)

    await viewModel.handleStartStreaming()
    XCTAssertFalse(viewModel.showError, viewModel.errorMessage)
    try await waitUntil("Mock camera must deliver a frame", timeout: 10) {
      viewModel.streamingStatus == .streaming && viewModel.hasReceivedFirstFrame
    }
    return viewModel
  }
}

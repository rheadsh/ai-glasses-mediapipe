/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 * This source code is licensed under the license found in the root LICENSE file.
 */

import MWDATCamera
import MWDATCore
import MWDATMockDevice
import UIKit
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

  func testStopImmediatelyRejectsQueuedNonterminalEvents() async throws {
    let viewModel = try await startStreaming()
    let generation = viewModel.streamGeneration
    let previewBeforeStop = viewModel.currentVideoFrame
    let imageData = try Data(contentsOf: fixtureURL("plant", extension: "png"))
    let queuedImage = try XCTUnwrap(UIImage(data: imageData))
    let photoData = try XCTUnwrap(queuedImage.jpegData(compressionQuality: 0.9))
    let queuedResult = VisionAnalysisResult(detections: [], landmarkGroups: [],
      maskImage: queuedImage, summary: "Queued after stop", resultCount: 1,
      inferenceTimeMilliseconds: 12)
    viewModel.isVisionAnalysisEnabled = true
    viewModel.stopSession()

    // Deliberately do not yield: the DAT terminal callback has not crossed MainActor
    // yet. Events already queued by the listener must not revive this stopping stream.
    viewModel.handleStateChange(.streaming, generation: generation)
    viewModel.handleVideoFrame(queuedImage, generation: generation)
    viewModel.handleAnalysisResult(.success(queuedResult), generation: viewModel.analysisGeneration)
    viewModel.handleStreamError(.videoStreamingError, generation: generation)
    viewModel.handleStreamError(.thermalHot, generation: generation)
    viewModel.handlePhotoData(PhotoData(data: photoData, format: .jpeg), generation: generation)
    XCTAssertEqual(viewModel.streamingStatus, .waiting)
    XCTAssertTrue(viewModel.currentVideoFrame === previewBeforeStop)
    XCTAssertNil(viewModel.segmentationMask)
    XCTAssertEqual(viewModel.analyzedFrameCount, 0)
    XCTAssertEqual(viewModel.analysisResultCount, 0)
    XCTAssertFalse(viewModel.showError)
    XCTAssertNil(viewModel.capturedPhoto)
    XCTAssertFalse(viewModel.showPhotoPreview)

    try await waitUntil("Terminal cleanup must still be accepted after stop") {
      viewModel.streamingStatus == .stopped
    }
    XCTAssertNil(viewModel.currentVideoFrame)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
  }

  func testAnalysisToggleDuringPreparationStillBecomesReady() async throws {
    let viewModel = try makeViewModel()
    // Configuration runs on the serial inference queue; enabling/disabling must invalidate
    // inference callbacks without invalidating the independent configuration completion.
    viewModel.isVisionAnalysisEnabled = false
    viewModel.isVisionAnalysisEnabled = true
    try await waitUntil("Model preparation must finish after toggling analysis", timeout: 20) {
      viewModel.visionAnalysisStatus != .preparing
    }
    XCTAssertEqual(viewModel.visionAnalysisStatus, .ready)
  }

  func testEndSessionDuringStartCannotRestoreStream() async throws {
    let viewModel = try makeViewModel()
    viewModel.isVisionAnalysisEnabled = false
    try await waitUntil("Mock glasses must become available") { viewModel.hasActiveDevice }
    let start = Task { await viewModel.handleStartStreaming() }
    await Task.yield()
    viewModel.endSession()
    await start.value
    // Drain callbacks already queued by the old publisher before checking terminal state.
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertNil(viewModel.currentVideoFrame)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertFalse(viewModel.showError, viewModel.errorMessage)
  }

  func testEndSessionAllowsFreshStreamWithoutOldCallbacks() async throws {
    let viewModel = try await startStreaming()
    viewModel.endSession()
    XCTAssertNil(viewModel.currentVideoFrame)
    await viewModel.handleStartStreaming()
    try await waitUntil("A fresh session must deliver frames after cleanup", timeout: 10) {
      viewModel.streamingStatus == .streaming && viewModel.hasReceivedFirstFrame
    }
    XCTAssertFalse(viewModel.showError, viewModel.errorMessage)
    XCTAssertNotNil(viewModel.currentVideoFrame)
  }

  func testPauseClearsOverlaysAndRejectsInferenceCompletedAfterResume() async throws {
    let viewModel = try await startStreaming()
    let image = try XCTUnwrap(viewModel.currentVideoFrame)
    let result = VisionAnalysisResult(
      detections: [ObjectDetection(label: "plant", score: 0.9,
        normalizedBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))],
      landmarkGroups: [VisionLandmarkGroup(points: [.zero], connections: [], style: .green)],
      maskImage: image, summary: "Previous frame", resultCount: 1,
      inferenceTimeMilliseconds: 12)
    viewModel.isVisionAnalysisEnabled = true
    let oldAnalysisGeneration = viewModel.analysisGeneration
    let streamGeneration = viewModel.streamGeneration
    viewModel.handleAnalysisResult(.success(result), generation: oldAnalysisGeneration)
    XCTAssertEqual(viewModel.objectDetections.count, 1)
    XCTAssertNotNil(viewModel.segmentationMask)

    // Deliver the same actor-boundary events as DAT, without relying on hardware
    // timing to place a queued inference completion after pause and resume.
    viewModel.handleStateChange(.paused, generation: streamGeneration)
    XCTAssertEqual(viewModel.streamingStatus, .waiting)
    XCTAssertTrue(viewModel.objectDetections.isEmpty)
    XCTAssertTrue(viewModel.landmarkGroups.isEmpty)
    XCTAssertNil(viewModel.segmentationMask)
    XCTAssertNil(viewModel.currentVideoFrame)
    XCTAssertEqual(viewModel.analysisResultCount, 0)
    XCTAssertNil(viewModel.inferenceTimeMilliseconds)

    viewModel.handleStateChange(.streaming, generation: streamGeneration)
    viewModel.handleAnalysisResult(.success(result), generation: oldAnalysisGeneration)
    XCTAssertTrue(viewModel.objectDetections.isEmpty,
      "An inference started before pause cannot restore stale overlays after resume")
    XCTAssertNil(viewModel.segmentationMask)
    XCTAssertEqual(viewModel.analyzedFrameCount, 0)
    // A new inference is accepted, proving pause did not permanently disable analysis.
    viewModel.handleAnalysisResult(.success(result), generation: viewModel.analysisGeneration)
    XCTAssertEqual(viewModel.objectDetections.count, 1)
    viewModel.isVisionAnalysisEnabled = false
  }

  func testQueuedEventsFromEndedStreamCannotMutateReplacementStream() async throws {
    let viewModel = try await startStreaming()
    let oldGeneration = viewModel.streamGeneration
    let oldImage = try XCTUnwrap(viewModel.currentVideoFrame)
    viewModel.endSession()
    await viewModel.handleStartStreaming()
    try await waitUntil("Replacement stream must deliver frames", timeout: 10) {
      viewModel.streamingStatus == .streaming && viewModel.hasReceivedFirstFrame
    }
    let replacementImage = viewModel.currentVideoFrame

    // Replay callbacks captured by the old listener before its token was released.
    viewModel.handleStateChange(.stopped, generation: oldGeneration)
    viewModel.handleStreamError(.thermalHot, generation: oldGeneration)
    viewModel.handleVideoFrame(oldImage, generation: oldGeneration)
    XCTAssertEqual(viewModel.streamingStatus, .streaming)
    XCTAssertTrue(viewModel.currentVideoFrame === replacementImage)
    XCTAssertFalse(viewModel.showError, "An old stream must not raise errors on its replacement")
  }

  func testVideoErrorWatchdogDetectsSilenceAfterAnInitiallyHealthyWindow() async throws {
    let viewModel = try await startStreaming()
    let generation = viewModel.streamGeneration
    // Exercise the actual timer-window decision with controlled counts. The camera
    // remains streaming; no pause or SDK terminal event is used to simulate silence.
    let baseline = viewModel.checkFrameWatchdogWindow(
      previousFrameCount: 1, currentFrameCount: 2, generation: generation,
      error: .videoStreamingError)
    XCTAssertEqual(baseline, 2)
    XCTAssertFalse(viewModel.showError)
    XCTAssertEqual(viewModel.streamingStatus, .streaming)
    _ = viewModel.checkFrameWatchdogWindow(
      previousFrameCount: baseline, currentFrameCount: 2, generation: generation,
      error: .videoStreamingError)
    XCTAssertTrue(viewModel.showError)
    XCTAssertEqual(viewModel.errorMessage, StreamError.videoStreamingError.localizedDescription)
    try await waitUntil("Silence during streaming must end the stream") {
      viewModel.streamingStatus == .stopped
    }
  }

  func testTemporaryPauseSurvivesPreviousVideoErrorAndResetsGrace() async throws {
    let viewModel = try await startStreaming()
    let generation = viewModel.streamGeneration
    viewModel.handleStreamError(.videoStreamingError)
    viewModel.handleStateChange(.paused, generation: generation)
    var baseline: Int? = 10
    for _ in 0..<3 {
      baseline = viewModel.checkFrameWatchdogWindow(
        previousFrameCount: baseline, currentFrameCount: 10, generation: generation,
        error: .videoStreamingError)
      XCTAssertNil(baseline)
      XCTAssertFalse(viewModel.showError)
      XCTAssertEqual(viewModel.streamingStatus, .waiting)
    }
    viewModel.handleStateChange(.streaming, generation: generation)
    baseline = viewModel.checkFrameWatchdogWindow(
      previousFrameCount: baseline, currentFrameCount: 10, generation: generation,
      error: .videoStreamingError)
    XCTAssertEqual(baseline, 10, "Resume starts a fresh grace window")
    XCTAssertFalse(viewModel.showError)
    XCTAssertEqual(viewModel.streamingStatus, .streaming)
    baseline = viewModel.checkFrameWatchdogWindow(
      previousFrameCount: baseline, currentFrameCount: 11, generation: generation,
      error: .videoStreamingError)
    XCTAssertEqual(baseline, 11)
    XCTAssertFalse(viewModel.showError)
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

  func testCompressedStreamKeepsDeliveringFramesInBackground() async throws {
    let viewModel = try await startStreaming(keepsRunningWhenLocked: true)
    XCTAssertTrue(viewModel.keepsRunningWhenLocked)

    // Phone locked: the stream stays up and the preview is no longer updated.
    viewModel.appActivityChanged(isActive: false)
    XCTAssertEqual(viewModel.streamingStatus, .streaming)
    let previewWhileLocked = viewModel.currentVideoFrame
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(viewModel.currentVideoFrame === previewWhileLocked,
      "Preview must not be refreshed while the app is not active")
    XCTAssertEqual(viewModel.streamingStatus, .streaming)

    // Unlocked again: new frames reach the preview.
    viewModel.appActivityChanged(isActive: true)
    try await waitUntil("Preview must resume after unlocking", timeout: 10) {
      viewModel.currentVideoFrame !== previewWhileLocked
    }
  }

  func testVideoErrorWhileLockedDoesNotInterruptStreamWhileFramesFlow() async throws {
    let viewModel = try await startStreaming(keepsRunningWhenLocked: true)
    viewModel.backgroundErrorGrace = .milliseconds(500)
    viewModel.appActivityChanged(isActive: false)

    viewModel.handleStreamError(.videoStreamingError)
    XCTAssertFalse(viewModel.showError, "No alert while the phone is locked")
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertEqual(viewModel.streamingStatus, .streaming, "Frames keep flowing, so the stream stays up")
    XCTAssertFalse(viewModel.showError)
  }

  func testVideoErrorWithFlowingFramesIsNotShownEvenInForeground() async throws {
    let viewModel = try await startStreaming(keepsRunningWhenLocked: true)
    viewModel.backgroundErrorGrace = .milliseconds(500)
    viewModel.handleStreamError(.videoStreamingError)
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertEqual(viewModel.streamingStatus, .streaming)
    XCTAssertFalse(viewModel.showError)
  }

  func testOtherStreamErrorsAreStillReported() async throws {
    let viewModel = try await startStreaming()
    viewModel.handleStreamError(.thermalHot)
    XCTAssertTrue(viewModel.showError)
    XCTAssertEqual(viewModel.errorMessage, StreamError.thermalHot.localizedDescription)
  }

  private func makeViewModel() throws -> StreamSessionViewModel {
    // Isolated defaults include OSC output: never use the developer's destination.
    let suite = "DATStreamingTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared, defaults: defaults)
    self.viewModel = viewModel
    return viewModel
  }

  private func startStreaming(keepsRunningWhenLocked: Bool = false) async throws -> StreamSessionViewModel {
    let camera = try XCTUnwrap(camera)
    camera.setCameraFeed(fileURL: try fixtureURL("plant", extension: "mp4"))
    let viewModel = try makeViewModel()
    viewModel.keepsRunningWhenLocked = keepsRunningWhenLocked
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

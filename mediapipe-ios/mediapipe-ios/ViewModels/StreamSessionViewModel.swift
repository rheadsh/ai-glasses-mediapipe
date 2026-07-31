/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCamera
import MWDATCore
import Observation
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@Observable
@MainActor
final class StreamSessionViewModel {
  // MARK: - State

  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false
  var streamingStatus: StreamingStatus = .stopped
  var showError: Bool = false
  var errorMessage: String = ""
  var requiresDATAppUpdate: Bool = false

  var selectedVisionTask: MediaPipeVisionTask = .objectDetection
  var visionAnalysisStatus: VisionAnalysisStatus = .preparing
  var selectedObjectDetectionModel: ObjectDetectionModel = .efficientDetLite0
  var objectDetections: [ObjectDetection] = []
  var landmarkGroups: [VisionLandmarkGroup] = []
  var segmentationMask: UIImage?
  var analysisSummary: String = ""
  var analysisResultCount: Int = 0
  var interactiveSegmentationPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
  var inferenceTimeMilliseconds: Double?
  var analyzedFrameCount: Int = 0
  var isVisionAnalysisEnabled: Bool = true {
    didSet {
      analysisGeneration += 1
      if !isVisionAnalysisEnabled {
        resetVisionAnalysisResults()
      }
    }
  }

  var capturedPhoto: UIImage?
  var showPhotoPreview: Bool = false
  var showPhotoCaptureError: Bool = false
  var isCapturingPhoto: Bool = false

  var hasActiveDevice: Bool { sessionManager.hasActiveDevice }
  var isDeviceSessionReady: Bool { sessionManager.isReady }

  var isStreaming: Bool { streamingStatus != .stopped }
  var isSelectedVisionTaskConfigured: Bool { selectedVisionTask.isConfigured }
  var isVisionAnalysisActive: Bool {
    isSelectedVisionTaskConfigured && isVisionAnalysisEnabled
  }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private let visionAnalyzer = MediaPipeVisionAnalyzer()
  private var analysisGeneration: Int = 0
  private var stream: MWDATCamera.Stream?

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
    #if DEBUG
      // UI automation validates controls while MockDeviceKit continuously emits frames.
      // Real MediaPipe inference is covered independently by the unit/integration suite.
      if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
        isVisionAnalysisEnabled = false
      }
    #endif
    prepareSelectedVisionTask()
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      await startSession()
    } catch {
      // Use `localizedDescription` for user-facing text — `description` is
      // always English and intended for logs.
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func stopSession() {
    stream?.stop()
  }

  /// Stops both the stream and the underlying device session. Call in test tearDown.
  func endSession() {
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    analysisGeneration += 1
    resetVisionAnalysisResults()
    visionAnalyzer.reset()
    sessionManager.cleanup()
  }

  func toggleVisionAnalysis() {
    guard isSelectedVisionTaskConfigured else { return }
    isVisionAnalysisEnabled.toggle()
  }

  func selectVisionTask(_ task: MediaPipeVisionTask) {
    guard task != selectedVisionTask else { return }
    selectedVisionTask = task
    analysisGeneration += 1
    resetVisionAnalysisResults()
    visionAnalyzer.reset()
    prepareSelectedVisionTask()
  }

  func selectObjectDetectionModel(_ model: ObjectDetectionModel) {
    guard model != selectedObjectDetectionModel else { return }
    selectedObjectDetectionModel = model
    guard selectedVisionTask == .objectDetection else { return }
    analysisGeneration += 1
    resetVisionAnalysisResults()
    visionAnalyzer.reset()
    guard MediaPipeObjectDetector.bundledModelPath(for: model) != nil else {
      visionAnalysisStatus = .unavailable(
        "No se encontró \(model.resourceName).tflite en el bundle."
      )
      return
    }
    prepareSelectedVisionTask()
  }

  func selectInteractiveSegmentationPoint(_ point: CGPoint) {
    guard selectedVisionTask == .interactiveSegmentation else { return }
    interactiveSegmentationPoint = point
    resetVisionAnalysisResults()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  // MARK: - Private

  private func startSession() async {
    let deviceSession: DeviceSession
    do {
      deviceSession = try await sessionManager.getSession()
      requiresDATAppUpdate = false
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
      return
    } catch {
      showError("Failed to start session: \(error.localizedDescription)")
      return
    }

    guard deviceSession.state == .started else {
      showError("Device session is not ready. Please try again.")
      return
    }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      guard let newStream = try deviceSession.addStream(config: config) else {
        showError("Unable to create stream. Please try again.")
        return
      }
      stream = newStream
      streamingStatus = .waiting
      setupListeners(for: newStream)
      newStream.start()
    } catch {
      showError("Failed to start stream: \(error.localizedDescription)")
    }
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in self?.handleVideoFrame(frame) }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      stream = nil
      clearListeners()
      hasReceivedFirstFrame = false
      analysisGeneration += 1
      resetVisionAnalysisResults()
      sessionManager.stopCurrentSession()
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
      analyzeFrameIfNeeded(image)
    }
  }

  private func prepareSelectedVisionTask() {
    visionAnalysisStatus = .preparing
    let generation = analysisGeneration
    let modelPath: String?
    if selectedVisionTask == .objectDetection {
      modelPath = MediaPipeObjectDetector.bundledModelPath(for: selectedObjectDetectionModel)
    } else {
      modelPath = selectedVisionTask.bundledModelPath
    }
    guard let modelPath else {
      visionAnalysisStatus = .unavailable(selectedVisionTask.configurationMessage)
      return
    }

    visionAnalyzer.configure(task: selectedVisionTask, modelPath: modelPath) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, self.analysisGeneration == generation else { return }
        switch result {
        case .success:
          self.visionAnalysisStatus = .ready
        case .failure(let error):
          self.visionAnalysisStatus = .unavailable(error.localizedDescription)
          self.resetVisionAnalysisResults()
        }
      }
    }
  }

  private func analyzeFrameIfNeeded(_ image: UIImage) {
    guard isVisionAnalysisEnabled,
      visionAnalysisStatus == .ready
    else {
      return
    }
    let generation = analysisGeneration
    let interactionPoint =
      selectedVisionTask == .interactiveSegmentation
      ? interactiveSegmentationPoint : nil

    visionAnalyzer.submit(image: image, interactionPoint: interactionPoint) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self,
          self.isVisionAnalysisEnabled,
          self.analysisGeneration == generation
        else {
          return
        }
        switch result {
        case .success(let result):
          self.objectDetections = result.detections
          self.landmarkGroups = result.landmarkGroups
          self.segmentationMask = result.maskImage
          self.analysisSummary = result.summary
          self.analysisResultCount = result.resultCount
          self.inferenceTimeMilliseconds = result.inferenceTimeMilliseconds
          self.analyzedFrameCount += 1
        case .failure(let error):
          if error is MediaPipeVisionAnalyzerError { return }
          self.visionAnalysisStatus = .unavailable(error.localizedDescription)
          self.resetVisionAnalysisResults()
        }
      }
    }
  }

  private func resetVisionAnalysisResults() {
    objectDetections = []
    landmarkGroups = []
    segmentationMask = nil
    analysisSummary = ""
    analysisResultCount = 0
    inferenceTimeMilliseconds = nil
    analyzedFrameCount = 0
  }

  private func handleError(_ error: StreamError) {
    let message = error.localizedDescription
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }
}

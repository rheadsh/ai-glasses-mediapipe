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

  let oscOutput: OSCOutput

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
      guard oldValue != isVisionAnalysisEnabled else { return }
      analysisGeneration += 1
      if !isVisionAnalysisEnabled {
        resetVisionAnalysisResults()
      }
    }
  }

  /// Opt-in: stream with compressed HEVC so DAT keeps delivering frames while the app is in the
  /// background or the phone is locked. DAT pauses `VideoCodec.raw` streams in the background.
  /// Applies to the next stream; it cannot change while streaming.
  var keepsRunningWhenLocked: Bool = false {
    didSet { defaults.set(keepsRunningWhenLocked, forKey: Self.keepRunningWhenLockedKey) }
  }

  var capturedPhoto: UIImage?
  var showPhotoPreview: Bool = false
  var showPhotoCaptureError: Bool = false
  var isCapturingPhoto: Bool = false

  var hasActiveDevice: Bool { sessionManager.hasActiveDevice }

  var isStreaming: Bool { streamingStatus != .stopped }
  var isSelectedVisionTaskConfigured: Bool { selectedVisionTask.isConfigured }
  var isVisionAnalysisActive: Bool {
    isSelectedVisionTaskConfigured && isVisionAnalysisEnabled
  }

  // MARK: - Private

  #if DEBUG
  private let freezesPreviewForUITesting = ProcessInfo.processInfo.arguments.contains("--freeze-preview-for-ui-testing")
  #endif
  private static let keepRunningWhenLockedKey = "background.keepRunningWhenLocked"
  private let defaults: UserDefaults
  private var streamUsesCompressedVideo = false
  private var isAppActive = true
  private var deliveredFrameCount = 0
  private var frameWatchdog: Task<Void, Never>?
  private var supervisedVideoError: StreamError?
  /// How long frames may stop after a video error while locked before the stream is ended.
  var backgroundErrorGrace: Duration = .seconds(5)
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private let visionAnalyzer = MediaPipeVisionAnalyzer()
  private(set) var analysisGeneration: Int = 0
  private var preparationGeneration: Int = 0
  private(set) var streamGeneration: Int = 0
  private var startGeneration: Int = 0
  private var isStartingSession = false
  private var isStoppingStream = false
  private var needsAnalyzerPrepare = false
  private var photoCaptureTimeout: Task<Void, Never>?
  private var stream: MWDATCamera.Stream?
  private var camera: MWDATCamera.Camera?

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(wearables: WearablesInterface, defaults: UserDefaults = .standard) {
    self.wearables = wearables
    self.defaults = defaults
    self.oscOutput = OSCOutput(defaults: defaults)
    self.keepsRunningWhenLocked = defaults.bool(forKey: Self.keepRunningWhenLockedKey)
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
    // A second tap while permissions or the session are still resolving must not
    // create a second Camera.
    guard !isStartingSession, streamingStatus == .stopped else { return }
    isStartingSession = true
    startGeneration += 1
    let generation = startGeneration
    defer { if startGeneration == generation { isStartingSession = false } }
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      guard startGeneration == generation, !Task.isCancelled else { return }
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard startGeneration == generation, !Task.isCancelled else { return }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      await startSession(generation: generation)
    } catch {
      guard startGeneration == generation, !Task.isCancelled else { return }
      // Use `localizedDescription` for user-facing text — `description` is
      // always English and intended for logs.
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func stopSession() {
    isStoppingStream = true
    if stream != nil { streamingStatus = .waiting }
    supervisedVideoError = nil
    frameWatchdog?.cancel()
    startGeneration += 1
    isStartingSession = false
    analysisGeneration += 1
    resetVisionAnalysisResults()
    if let stream {
      stream.stop()
    } else {
      sessionManager.stopCurrentSession()
    }
  }

  /// Stops both the stream and the underlying device session. Call in test tearDown.
  func endSession() {
    isStoppingStream = false
    supervisedVideoError = nil
    startGeneration += 1
    streamGeneration += 1
    preparationGeneration += 1
    isStartingSession = false
    camera?.stop()
    camera = nil
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    analysisGeneration += 1
    resetVisionAnalysisResults()
    visionAnalyzer.reset()
    // The runtime was released: reload it before the next stream starts.
    visionAnalysisStatus = .preparing
    needsAnalyzerPrepare = true
    finishPhotoCapture()
    endBackgroundTask()
    frameWatchdog?.cancel()
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
    preparationGeneration += 1
    guard model.bundledModelPath != nil else {
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
    // Results computed with the previous point must not be published.
    analysisGeneration += 1
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
      return
    }
    // The SDK may never answer (stream lost, capture dropped): do not block later captures.
    photoCaptureTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled, let self, self.isCapturingPhoto else { return }
      self.finishPhotoCapture()
      self.showPhotoCaptureError = true
    }
  }

  private func finishPhotoCapture() {
    photoCaptureTimeout?.cancel()
    photoCaptureTimeout = nil
    isCapturingPhoto = false
  }

  /// Called from the scene phase. While streaming with `keepsRunningWhenLocked`, the app asks
  /// iOS for background execution time; the bluetooth / external-accessory background modes
  /// keep it running while the glasses stream.
  func appActivityChanged(isActive: Bool) {
    isAppActive = isActive
    if isActive {
      endBackgroundTask()
    } else if isStreaming && streamUsesCompressedVideo {
      beginBackgroundTask()
    }
  }

  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "mediapipe-ios.stream") {
      [weak self] in
      Task { @MainActor in self?.endBackgroundTask() }
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
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

  private func startSession(generation: Int) async {
    if needsAnalyzerPrepare {
      needsAnalyzerPrepare = false
      prepareSelectedVisionTask()
    }
    let deviceSession: DeviceSession
    do {
      deviceSession = try await sessionManager.getSession()
      guard startGeneration == generation, !Task.isCancelled else {
        // Cancellation after getSession succeeds must release the session owned by
        // this start, without touching a replacement created after endSession.
        if startGeneration == generation {
          sessionManager.stopSessionIfCurrent(deviceSession)
        }
        return
      }
      requiresDATAppUpdate = false
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      guard startGeneration == generation, !Task.isCancelled else { return }
      requiresDATAppUpdate = true
      showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
      return
    } catch {
      guard startGeneration == generation, !Task.isCancelled else { return }
      showError("Failed to start session: \(error.localizedDescription)")
      return
    }

    guard deviceSession.state == .started else {
      showError("Device session is not ready. Please try again.")
      return
    }

    streamUsesCompressedVideo = keepsRunningWhenLocked
    let config = StreamConfiguration(
      videoCodec: streamUsesCompressedVideo ? VideoCodec.hvc1 : VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      guard let newCamera = try deviceSession.addCamera(config: config) else {
        showError("Unable to create stream. Please try again.")
        return
      }
      camera = newCamera
      let newStream = newCamera.stream
      stream = newStream
      streamingStatus = .waiting
      setupListeners(for: newStream)
      newStream.start()
    } catch {
      showError("Failed to start stream: \(error.localizedDescription)")
    }
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    isStoppingStream = false
    streamGeneration += 1
    let generation = streamGeneration
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        self?.handleStateChange(state, generation: generation)
      }
    }

    // Convert off the main actor and drop frames while the main actor is still
    // consuming the previous one, so preview work cannot pile up.
    // Each stream owns its decoder history and gate; callbacks still unwinding from a
    // previous stream cannot alter the new stream's HEVC references or back pressure.
    let gate = FrameGate()
    let converter = VideoFrameImageConverter()
    let compressed = streamUsesCompressedVideo
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      // Compressed frames are decoded on the CPU/VideoToolbox: the GPU is off limits in the
      // background. `makeUIImage()` is only used for the foreground-only raw stream.
      // Every compressed sample must reach the decoder, including reference frames whose
      // preview is dropped. Back pressure applies only after decoding.
      let image: UIImage?
      if compressed {
        guard let pixels = converter.pixelBuffer(
          from: frame.sampleBuffer, acceptingDecodedFrame: { gate.tryEnter() }) else { return }
        image = VideoFrameImageConverter.image(from: pixels)
      } else {
        guard gate.tryEnter() else { return }
        image = frame.makeUIImage()
      }
      Task { @MainActor in
        gate.leave()
        self?.handleVideoFrame(image, generation: generation)
      }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.handleStreamError(error, generation: generation)
      }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in
        self?.handlePhotoData(data, generation: generation)
      }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  func handleStateChange(_ state: StreamState, generation: Int) {
    guard streamGeneration == generation else { return }
    guard !isStoppingStream || state == .stopped else { return }
    switch state {
    case .stopped:
      isStoppingStream = false
      supervisedVideoError = nil
      streamGeneration += 1
      currentVideoFrame = nil
      streamingStatus = .stopped
      camera?.stop()
      camera = nil
      stream = nil
      clearListeners()
      hasReceivedFirstFrame = false
      analysisGeneration += 1
      resetVisionAnalysisResults()
      finishPhotoCapture()
      endBackgroundTask()
      frameWatchdog?.cancel()
      sessionManager.stopCurrentSession()
    case .waitingForDevice, .starting, .stopping, .paused:
      frameWatchdog?.cancel()
      frameWatchdog = nil
      analysisGeneration += 1
      resetVisionAnalysisResults()
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .waiting
    case .streaming:
      let wasStreaming = streamingStatus == .streaming
      streamingStatus = .streaming
      if !wasStreaming, let error = supervisedVideoError {
        superviseFrames(after: error)
      }
    }
  }

  func handleVideoFrame(_ image: UIImage?, generation: Int) {
    guard !isStoppingStream else { return }
    guard streamGeneration == generation else { return }
    guard streamingStatus == .streaming else { return }
    #if DEBUG
    // Keep the accessibility tree stable for control tests. Native streaming continues;
    // DAT integration and pipeline tests do not pass this flag and process live frames.
    if freezesPreviewForUITesting && hasReceivedFirstFrame { return }
    #endif
    if let image {
      deliveredFrameCount += 1
      // No SwiftUI preview work while the app is not on screen (e.g. phone locked);
      // analysis and OSC keep running.
      if isAppActive { currentVideoFrame = image }
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
      analyzeFrameIfNeeded(image)
    }
  }

  private func prepareSelectedVisionTask() {
    visionAnalysisStatus = .preparing
    preparationGeneration += 1
    let generation = preparationGeneration
    let modelPath: String?
    if selectedVisionTask == .objectDetection {
      modelPath = selectedObjectDetectionModel.bundledModelPath
    } else {
      modelPath = selectedVisionTask.bundledModelPath
    }
    guard let modelPath else {
      visionAnalysisStatus = .unavailable(selectedVisionTask.configurationMessage)
      return
    }

    visionAnalyzer.configure(task: selectedVisionTask, modelPath: modelPath) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, self.preparationGeneration == generation else { return }
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

    visionAnalyzer.submit(image: image, interactionPoint: interactionPoint, makePreview: isAppActive) { [weak self] result in
      Task { @MainActor [weak self] in
        self?.handleAnalysisResult(result, generation: generation)
      }
    }
  }

  /// Accept results at the actor boundary, where a pause/task change can invalidate
  /// inference that was already queued on the serial worker.
  func handleAnalysisResult(_ result: Result<VisionAnalysisResult, Error>, generation: Int) {
    guard !isStoppingStream, isVisionAnalysisEnabled,
      streamingStatus == .streaming,
      analysisGeneration == generation
    else {
      return
    }
    switch result {
    case .success(let result):
      oscOutput.publish(result, task: selectedVisionTask)
      objectDetections = result.detections
      landmarkGroups = result.landmarkGroups
      segmentationMask = result.maskImage
      analysisSummary = result.summary
      analysisResultCount = result.resultCount
      inferenceTimeMilliseconds = result.inferenceTimeMilliseconds
      analyzedFrameCount += 1
    case .failure(let error):
      if error is MediaPipeVisionAnalyzerError { return }
      visionAnalysisStatus = .unavailable(error.localizedDescription)
      resetVisionAnalysisResults()
    }
  }

  private func resetVisionAnalysisResults() {
    oscOutput.clear()
    objectDetections = []
    landmarkGroups = []
    segmentationMask = nil
    analysisSummary = ""
    analysisResultCount = 0
    inferenceTimeMilliseconds = nil
    analyzedFrameCount = 0
  }

  func handleStreamError(_ error: StreamError, generation: Int? = nil) {
    guard !isStoppingStream else { return }
    if let generation, streamGeneration != generation { return }
    let message = error.localizedDescription
    NSLog("[mediapipe-ios] DAT stream error: \(error) (appActive=\(isAppActive), compressed=\(streamUsesCompressedVideo))")
    // A failed photo capture is reported here; unblock the capture button.
    finishPhotoCapture()

    // DAT can report `videoStreamingError` ("the stream should end") when the phone locks
    // or the app comes back, although frames keep arriving. Judge by the frames, not the
    // message: keep going while they flow; end the stream (and tell the user) if they stop.
    if error == .videoStreamingError, isStreaming {
      superviseFrames(after: error)
      return
    }
    if message != errorMessage {
      showError(message)
    }
  }

  private func superviseFrames(after error: StreamError) {
    supervisedVideoError = error
    frameWatchdog?.cancel()
    let generation = streamGeneration
    let initialFrameCount = deliveredFrameCount
    frameWatchdog = Task { [weak self, grace = backgroundErrorGrace] in
      var baseline: Int? = initialFrameCount
      while !Task.isCancelled {
        do { try await Task.sleep(for: grace) } catch { return }
        guard let self, self.isStreaming, self.streamGeneration == generation else { return }
        baseline = self.checkFrameWatchdogWindow(
          previousFrameCount: baseline, currentFrameCount: self.deliveredFrameCount,
          generation: generation, error: error)
      }
    }
  }

  /// A window starts only while streaming. DAT pauses are temporary and reset the
  /// baseline, so returning to streaming receives a fresh grace window.
  func checkFrameWatchdogWindow(
    previousFrameCount: Int?, currentFrameCount: Int, generation: Int, error: StreamError
  ) -> Int? {
    guard streamGeneration == generation, streamingStatus == .streaming else { return nil }
    if let previousFrameCount, currentFrameCount == previousFrameCount {
      NSLog("[mediapipe-ios] No frames after a video error; ending the stream")
      stopSession()
      showError(error.localizedDescription)
      return nil
    }
    return currentFrameCount
  }

  func handlePhotoData(_ data: PhotoData, generation: Int) {
    guard !isStoppingStream else { return }
    guard streamGeneration == generation else { return }
    finishPhotoCapture()
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

/// Lets one frame at a time cross from the DAT callback thread to the main actor.
private final class FrameGate: @unchecked Sendable {
  private let lock = NSLock()
  private var busy = false

  func tryEnter() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if busy { return false }
    busy = true
    return true
  }

  func leave() {
    lock.lock()
    busy = false
    lock.unlock()
  }
}

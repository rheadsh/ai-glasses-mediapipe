/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class MediaPipeIOSUITests: XCTestCase {
  var portFilePath: String {
    NSTemporaryDirectory() + "mwdat_test_server_port.txt"
  }
  private let app = XCUIApplication()
  // swiftlint:disable implicitly_unwrapped_optional
  private var mockClient: MockDeviceTestClient!
  private var pairedDeviceId: String!
  // swiftlint:enable implicitly_unwrapped_optional

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false

    // Remove any stale port file from a previous run so readPort() waits
    // for the new server to write its port instead of returning the old one.
    try? FileManager.default.removeItem(atPath: portFilePath)

    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()

    // Initialize the client *after* launch so the server has time to write the port file.
    mockClient = MockDeviceTestClient(portFilePath: portFilePath)
    let commandSucceeded = await mockClient.waitForServer(timeout: 10)
    XCTAssertTrue(commandSucceeded, "Test server should be running")
  }

  override func tearDown() async throws {
    defer { mockClient = nil }
    if pairedDeviceId != nil {
      await mockClient.unpairDevice(deviceId: pairedDeviceId)
      pairedDeviceId = nil
    }
    try await super.tearDown()
  }

  // MARK: - Helpers

  /// Taps "Connect my glasses" to trigger registration via the fake handler,
  /// dismisses the getting-started sheet, and waits for the streaming screen
  /// to be fully ready for device connections.
  private func registerViaUI() {
    let connectButton = app.buttons["Conectar mis gafas"]
    XCTAssertTrue(connectButton.waitForExistence(timeout: 10), "Should start on HomeScreenView")
    connectButton.tap()

    // Dismiss the getting-started sheet if it appears after registration.
    // In some environments (e.g. RE) the sheet may be skipped and the app
    // transitions directly to the stream screen.
    let continueButton = app.buttons["Continue"]
    if continueButton.waitForExistence(timeout: 5) {
      continueButton.tap()
    }

    // Wait for the NonStreamView to be fully rendered with device monitoring active
    let waitingText = app.staticTexts["Waiting for an active device"]
    XCTAssertTrue(
      waitingText.waitForExistence(timeout: 15),
      "Should show waiting state before a device is paired")
  }

  /// Pairs a device with default camera resources via the test server.
  private func pairDeviceWithCameraResources() async {
    registerViaUI()

    let deviceId = await mockClient.pairDevice()
    XCTAssertNotNil(deviceId, "pairDevice should return a deviceId")
    pairedDeviceId = deviceId

    await mockClient.setCameraFeed(deviceId: pairedDeviceId, resourceName: "plant", ext: "mp4")
    await mockClient.setCapturedImage(deviceId: pairedDeviceId, resourceName: "plant", ext: "png")
  }

  /// Waits for the "Start streaming" button to exist and be enabled (mock device active).
  @discardableResult
  private func waitForStartStreamingEnabled(timeout: TimeInterval = 15) -> XCUIElement {
    let startButton = app.buttons["Iniciar stream y análisis"]
    XCTAssertTrue(
      startButton.waitForExistence(timeout: timeout), "Start streaming button should appear")

    let predicate = NSPredicate(format: "isEnabled == true")
    expectation(for: predicate, evaluatedWith: startButton)
    waitForExpectations(timeout: timeout)

    return startButton
  }

  /// Waits for the "Start streaming" button to exist and be disabled (device inactive).
  @discardableResult
  private func waitForStartStreamingDisabled(timeout: TimeInterval = 15) -> XCUIElement {
    let startButton = app.buttons["Iniciar stream y análisis"]
    XCTAssertTrue(
      startButton.waitForExistence(timeout: timeout), "Start streaming button should appear")

    let predicate = NSPredicate(format: "isEnabled == false")
    expectation(for: predicate, evaluatedWith: startButton)
    waitForExpectations(timeout: timeout)

    return startButton
  }

  /// Starts streaming and waits for the StreamView to appear.
  private func startStreaming(timeout: TimeInterval = 15) {
    let startButton = waitForStartStreamingEnabled(timeout: timeout)
    startButton.tap()

    let stopButton = app.buttons["Stop streaming"]
    XCTAssertTrue(
      stopButton.waitForExistence(timeout: timeout),
      "Stop streaming button should appear after starting")
  }

  // MARK: - Device Pairing & Navigation Tests

  /// Verifies that launching without pairing a device shows the home screen.
  @MainActor
  func testLaunchWithoutDeviceShowsHomeScreen() async {
    let connectButton = app.buttons["Conectar mis gafas"]
    XCTAssertTrue(
      connectButton.waitForExistence(timeout: 10),
      "HomeScreenView should show 'Connect my glasses' when no device is paired"
    )
  }

  /// Verifies that registering and pairing a device transitions the UI from the home screen
  /// to the stream screen with an active device.
  @MainActor
  func testRegisterAndPairTransitionsToStreamScreen() async {
    await pairDeviceWithCameraResources()
    waitForStartStreamingEnabled()
  }

  /// Verifies that the device state query reflects the correct number of paired devices.
  @MainActor
  func testDeviceStateReflectsPairedDevices() async {
    // Initially no devices paired
    let state0 = await mockClient.getDeviceState()
    XCTAssertNotNil(state0, "getDeviceState should return a response")
    XCTAssertEqual(
      state0?["pairedDeviceCount"] as? Int, 0, "Should have 0 paired devices initially")

    // Register and pair a device
    await pairDeviceWithCameraResources()

    let state1 = await mockClient.getDeviceState()
    XCTAssertNotNil(state1, "getDeviceState should return a response after pairing")
    XCTAssertEqual(state1?["pairedDeviceCount"] as? Int, 1, "Should have 1 paired device")

    // Unpair
    await mockClient.unpairDevice(deviceId: pairedDeviceId)
    pairedDeviceId = nil

    let state2 = await mockClient.getDeviceState()
    XCTAssertNotNil(state2, "getDeviceState should return a response after unpairing")
    XCTAssertEqual(
      state2?["pairedDeviceCount"] as? Int, 0, "Should have 0 paired devices after unpairing")
  }

  // MARK: - Device Activity Tests

  /// Verifies that doff makes the device inactive (disables streaming button)
  /// and don reactivates it.
  @MainActor
  func testDoffMakesDeviceInactiveAndDonReactivates() async {
    await pairDeviceWithCameraResources()
    waitForStartStreamingEnabled()

    // Doff the device → should become inactive
    await mockClient.doff(deviceId: pairedDeviceId)
    waitForStartStreamingDisabled()

    // Don the device → should become active again
    await mockClient.don(deviceId: pairedDeviceId)
    waitForStartStreamingEnabled()
  }

  /// Verifies that powering off makes the device inactive and powering on
  /// with don reactivates it.
  @MainActor
  func testPowerCycleAffectsDeviceActivity() async {
    await pairDeviceWithCameraResources()
    waitForStartStreamingEnabled()

    // Power off → device becomes inactive
    let powerOffSucceeded = await mockClient.powerOff(deviceId: pairedDeviceId)
    XCTAssertTrue(powerOffSucceeded, "Power off should succeed")
    waitForStartStreamingDisabled()

    // Power on + don → device becomes active again
    let powerOnSucceeded = await mockClient.powerOn(deviceId: pairedDeviceId)
    XCTAssertTrue(powerOnSucceeded, "Power on should succeed")
    let commandSucceeded = await mockClient.don(deviceId: pairedDeviceId)
    XCTAssertTrue(commandSucceeded, "Don should succeed")
    waitForStartStreamingEnabled()
  }

  // MARK: - Streaming Tests

  /// Verifies the complete start → stop streaming flow.
  // TestRail: C1599889064, C1602923640, C1602923646
  @MainActor
  func testStartAndStopStreaming() async {
    await pairDeviceWithCameraResources()
    startStreaming()

    // Stop streaming
    let stopButton = app.buttons["Stop streaming"]
    stopButton.tap()

    // Should return to NonStreamView
    let startButton = app.buttons["Iniciar stream y análisis"]
    XCTAssertTrue(
      startButton.waitForExistence(timeout: 10), "Should return to NonStreamView after stopping")
    XCTAssertTrue(
      app.staticTexts["Visión con Ray-Ban Meta"].exists, "NonStreamView title should reappear")
  }

  /// Verifies photo capture shows a preview and can be dismissed while continuing to stream.
  // TestRail: C1619609872, C1619610952
  @MainActor
  func testPhotoCaptureAndDismiss() async {
    await pairDeviceWithCameraResources()
    startStreaming()

    // Tap the capture button
    let captureButton = app.buttons["capture_photo_button"]
    XCTAssertTrue(
      captureButton.waitForExistence(timeout: 10),
      "Capture button should be visible during streaming")
    captureButton.tap()

    // Photo preview should appear
    let closeButton = app.buttons["close_preview_button"]
    XCTAssertTrue(
      closeButton.waitForExistence(timeout: 15),
      "Photo preview close button should appear after capture")

    // Dismiss the preview
    closeButton.tap()

    // Should still be streaming after dismissing preview
    let stopButton = app.buttons["Stop streaming"]
    XCTAssertTrue(
      stopButton.waitForExistence(timeout: 10),
      "Should still be streaming after dismissing photo preview")

    // Stop streaming
    stopButton.tap()

    // Should return to NonStreamView
    let startButton = app.buttons["Iniciar stream y análisis"]
    XCTAssertTrue(
      startButton.waitForExistence(timeout: 10), "Should return to NonStreamView after stopping")
  }

  /// Verifies that the MediaPipe model menu switches the live detector.
  @MainActor
  func testChangeMediaPipeModel() async {
    await pairDeviceWithCameraResources()
    waitForStartStreamingEnabled()

    let modelButton = app.buttons["select_mediapipe_model_button"]
    XCTAssertTrue(
      modelButton.waitForExistence(timeout: 10), "MediaPipe model button should be visible")
    XCTAssertEqual(modelButton.value as? String, "EfficientDet Lite0")
    modelButton.tap()

    let lite2Option = app.buttons["EfficientDet Lite2 · Mayor precisión"]
    XCTAssertTrue(lite2Option.waitForExistence(timeout: 5), "Lite2 option should be available")
    lite2Option.tap()

    let lite2Value = NSPredicate(format: "value == %@", "EfficientDet Lite2")
    let modelExpectation = expectation(for: lite2Value, evaluatedWith: modelButton)
    await fulfillment(of: [modelExpectation], timeout: 10)
  }

  /// Verifies that the MediaPipe menu exposes the complete iOS Vision task catalog.
  @MainActor
  func testChangeMediaPipeVisionTask() async {
    await pairDeviceWithCameraResources()
    waitForStartStreamingEnabled()

    let taskButton = app.buttons["select_mediapipe_task_button"]
    XCTAssertTrue(
      taskButton.waitForExistence(timeout: 10), "MediaPipe task button should be visible")
    XCTAssertEqual(taskButton.value as? String, "Object detection")
    taskButton.tap()

    let holisticOption = app.buttons["Holistic landmark detection · Configurada"]
    XCTAssertTrue(
      holisticOption.waitForExistence(timeout: 5), "Holistic Landmarker should be available")
    holisticOption.tap()

    let holisticValue = NSPredicate(format: "value == %@", "Holistic landmark detection")
    let taskExpectation = expectation(for: holisticValue, evaluatedWith: taskButton)
    await fulfillment(of: [taskExpectation], timeout: 10)

    XCTAssertFalse(app.otherElements["vision_task_configuration_message"].exists)
  }

  /// Verifies that folding the glasses while streaming causes streaming to stop.
  @MainActor
  func testFoldDuringStreamingStopsStream() async {
    await pairDeviceWithCameraResources()
    startStreaming()

    // Fold the glasses → streaming should stop (hinges closed)
    let commandSucceeded = await mockClient.fold(deviceId: pairedDeviceId)
    XCTAssertTrue(commandSucceeded, "Fold command should succeed")

    // Fold triggers a hingesClosed error alert — dismiss it so the view hierarchy settles.
    let alertOK = app.alerts.buttons["OK"]
    if alertOK.waitForExistence(timeout: 15) {
      alertOK.tap()
    }

    // Should return to NonStreamView with the button disabled (device is folded).
    waitForStartStreamingDisabled()
  }
}

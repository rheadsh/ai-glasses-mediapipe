/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 * This source code is licensed under the license found in the root LICENSE file.
 */

import MWDATMockDeviceTestClient
import XCTest

/// Product flows against DAT 1.0.1's async mock client. Run serially.
@MainActor
final class MediaPipeIOSUITests: XCTestCase {
  private let app = XCUIApplication()
  private let portFilePath = NSTemporaryDirectory() + "mwdat-\(UUID().uuidString).txt"
  private var mockClient: MockDeviceTestClient?
  private var pairedDeviceID: String?

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    app.launchArguments = ["--ui-testing", "--freeze-preview-for-ui-testing"]
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()

    let client = MockDeviceTestClient(portFilePath: portFilePath)
    mockClient = client
    let ready = await client.waitForServer(timeout: 10)
    XCTAssertTrue(ready,
      "Mock server must start. Keep simulator signing enabled and check the app's DAT configuration error.")
  }

  override func tearDown() async throws {
    if let pairedDeviceID, let mockClient {
      let removed = await mockClient.unpairDevice(deviceId: pairedDeviceID)
      XCTAssertTrue(removed, "Mock teardown must finish before the next test")
    }
    pairedDeviceID = nil
    mockClient = nil
    app.terminate()
    try? FileManager.default.removeItem(atPath: portFilePath)
    try await super.tearDown()
  }

  func testLaunchWithoutDeviceShowsHomeScreen() {
    XCTAssertTrue(app.buttons["Conectar mis lentes"].waitForExistence(timeout: 10))
  }

  func testRegisterPairStartAndStopStream() async throws {
    try await pairDeviceWithCameraResources()
    try await startStreaming()
    app.buttons["Stop streaming"].tap()
    let startButton = try await streamingButton(enabled: true)
    XCTAssertTrue(startButton.exists)
    XCTAssertTrue(app.staticTexts["Visión con Ray-Ban Meta"].exists)
  }

  func testPhotoCaptureAndDismissKeepsStreaming() async throws {
    try await pairDeviceWithCameraResources()
    try await startStreaming()
    let capture = app.buttons["capture_photo_button"]
    XCTAssertTrue(capture.waitForExistence(timeout: 10))
    capture.tap()
    let close = app.buttons["close_preview_button"]
    XCTAssertTrue(close.waitForExistence(timeout: 15))
    close.tap()
    XCTAssertTrue(app.buttons["Stop streaming"].waitForExistence(timeout: 10))
  }

  func testChangeObjectDetectionModel() async throws {
    try await pairDeviceWithCameraResources()
    _ = try await streamingButton(enabled: true)
    let menu = app.buttons["select_mediapipe_model_button"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    XCTAssertEqual(menu.value as? String, "EfficientDet Lite0")
    menu.tap()
    let option = app.buttons["EfficientDet Lite2 · Mayor precisión"]
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    option.tap()
    try await waitForValue("EfficientDet Lite2", of: menu)
  }

  func testChangeVisionTask() async throws {
    try await pairDeviceWithCameraResources()
    _ = try await streamingButton(enabled: true)
    let menu = app.buttons["select_mediapipe_task_button"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    XCTAssertEqual(menu.value as? String, "Object detection")
    menu.tap()
    let option = app.buttons["Holistic landmark detection · Configurada"]
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    option.tap()
    try await waitForValue("Holistic landmark detection", of: menu)
    XCTAssertFalse(app.otherElements["vision_task_configuration_message"].exists)
  }

  func testPowerCycleUpdatesStreamingAvailability() async throws {
    try await pairDeviceWithCameraResources()
    _ = try await streamingButton(enabled: true)
    let client = try XCTUnwrap(mockClient)
    let id = try XCTUnwrap(pairedDeviceID)
    let poweredOff = await client.powerOff(deviceId: id)
    XCTAssertTrue(poweredOff)
    _ = try await streamingButton(enabled: false)
    let poweredOn = await client.powerOn(deviceId: id)
    let unfolded = await client.unfold(deviceId: id)
    let donned = await client.don(deviceId: id)
    XCTAssertTrue(poweredOn && unfolded && donned)
    _ = try await streamingButton(enabled: true)
  }

  func testFoldDuringStreamingStopsStream() async throws {
    try await pairDeviceWithCameraResources()
    try await startStreaming()
    let client = try XCTUnwrap(mockClient)
    let folded = await client.fold(deviceId: try XCTUnwrap(pairedDeviceID))
    XCTAssertTrue(folded)
    let alert = app.alerts.buttons["OK"]
    if alert.waitForExistence(timeout: 5) { alert.tap() }
    _ = try await streamingButton(enabled: false)
  }

  func testScreensRemainUsableInLightAndDarkAppearance() async throws {
    let original = XCUIDevice.shared.appearance
    defer { XCUIDevice.shared.appearance = original }
    let appearances: [(String, XCUIDevice.Appearance)] = [("light", .light), ("dark", .dark)]

    // Home screen (before registration).
    for (name, appearance) in appearances {
      XCUIDevice.shared.appearance = appearance
      let connect = app.buttons["Conectar mis lentes"]
      XCTAssertTrue(connect.waitForExistence(timeout: 10), "Connect button missing in \(name)")
      XCTAssertTrue(connect.isHittable, "Connect button not hittable in \(name)")
      attachScreenshot("home-\(name)")
    }

    try await pairDeviceWithCameraResources()
    for (name, appearance) in appearances {
      XCUIDevice.shared.appearance = appearance
      let start = try await streamingButton(enabled: true)
      XCTAssertTrue(start.isHittable, "Start button not hittable in \(name)")
      for id in ["select_mediapipe_task_button", "select_mediapipe_model_button",
                 "osc_settings_button", "background_mode_toggle"] {
        let element = app.descendants(matching: .any)[id]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(id) missing in \(name)")
        XCTAssertTrue(element.isHittable, "\(id) not hittable in \(name)")
      }
      attachScreenshot("setup-\(name)")
    }

    try await startStreaming()
    for (name, appearance) in appearances {
      XCUIDevice.shared.appearance = appearance
      for id in ["capture_photo_button"] {
        let element = app.buttons[id]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(id) missing in \(name)")
        XCTAssertTrue(element.isHittable, "\(id) not hittable in \(name)")
      }
      XCTAssertTrue(app.buttons["Stop streaming"].isHittable, "Stop button not hittable in \(name)")
      attachScreenshot("streaming-\(name)")
    }
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testOSCSettingsValidateAndPersistDestination() async throws {
    try registerViaUI()
    let settings = app.buttons["osc_settings_button"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.tap()
    let host = app.textFields["osc_host"]
    let port = app.textFields["osc_port"]
    XCTAssertTrue(host.waitForExistence(timeout: 5))
    replaceText(in: host, with: "127.0.0.1")
    replaceText(in: port, with: "0")
    XCTAssertFalse(app.buttons["Aplicar"].isEnabled)
    replaceText(in: port, with: "9001")
    XCTAssertTrue(app.buttons["Aplicar"].isEnabled)
    app.buttons["Aplicar"].tap()
    settings.tap()
    XCTAssertEqual(app.textFields["osc_host"].value as? String, "127.0.0.1")
    XCTAssertEqual(app.textFields["osc_port"].value as? String, "9001")
    app.buttons["Cancelar"].tap()
  }

  // MARK: - Async helpers

  private func registerViaUI() throws {
    let connect = app.buttons["Conectar mis lentes"]
    XCTAssertTrue(connect.waitForExistence(timeout: 10))
    connect.tap()
    let next = app.buttons["Continue"]
    if next.waitForExistence(timeout: 2) { next.tap() }
    XCTAssertTrue(app.staticTexts["Waiting for an active device"].waitForExistence(timeout: 10))
  }

  private func pairDeviceWithCameraResources() async throws {
    try registerViaUI()
    let client = try XCTUnwrap(mockClient)
    let pairedID = await client.pairDevice()
    let id = try XCTUnwrap(pairedID, "Mock glasses must pair")
    pairedDeviceID = id
    let videoReady = await client.setCameraFeed(deviceId: id, resourceName: "plant", ext: "mp4")
    let photoReady = await client.setCapturedImage(deviceId: id, resourceName: "plant", ext: "png")
    XCTAssertTrue(videoReady && photoReady, "Mock media resources must load")
  }

  private func streamingButton(enabled: Bool) async throws -> XCUIElement {
    let button = app.buttons["Iniciar stream y análisis"]
    XCTAssertTrue(button.waitForExistence(timeout: 15))
    let ready = expectation(for: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), evaluatedWith: button)
    await fulfillment(of: [ready], timeout: 15)
    return button
  }

  private func startStreaming() async throws {
    let button = try await streamingButton(enabled: true)
    button.tap()
    XCTAssertTrue(app.buttons["Stop streaming"].waitForExistence(timeout: 15))
  }

  private func waitForValue(_ value: String, of element: XCUIElement) async throws {
    let changed = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
    await fulfillment(of: [changed], timeout: 10)
  }

  private func replaceText(in field: XCUIElement, with value: String) {
    field.tap()
    let current = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + value)
  }
}

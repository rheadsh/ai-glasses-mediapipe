/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MediaPipeIOSApp.swift
//
// Main entry point for the mediapipe-ios sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct MediaPipeIOSApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development
  @State private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface?
  private let configurationError: String?
  @State private var wearablesViewModel: WearablesViewModel?

  init() {
    let configuredWearables: WearablesInterface?
    let configurationError: String?

    do {
      try Wearables.configure()
      configuredWearables = Wearables.shared
      configurationError = nil
    } catch {
      configuredWearables = nil
      configurationError = error.localizedDescription
      NSLog("[mediapipe-ios] Failed to configure Wearables SDK: \(error)")
    }

    #if DEBUG
    // Start the test server when launched by XCUITests so tests can control
    // mock device setup via HTTP commands from the test process.
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: false))

      let portFilePath = ProcessInfo.processInfo.environment["MWDAT_TEST_SERVER_PORT_FILE"]
      Task {
        try await MockDeviceKit.shared.startTestServer(portFilePath: portFilePath)
      }
    }
    #endif

    self.wearables = configuredWearables
    self.configurationError = configurationError
    self._wearablesViewModel = State(
      wrappedValue: configuredWearables.map { WearablesViewModel(wearables: $0) }
    )
  }

  var body: some Scene {
    WindowGroup {
      if let wearables, let wearablesViewModel {
        MainAppView(wearables: wearables, viewModel: wearablesViewModel)
          .alert("Error", isPresented: Binding(
            get: { wearablesViewModel.showError },
            set: { if !$0 { wearablesViewModel.dismissError() } }
          )) {
            Button("OK") {
              wearablesViewModel.dismissError()
            }
          } message: {
            Text(wearablesViewModel.errorMessage)
          }
          #if DEBUG
          .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
            MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
          }
          .overlay {
            DebugMenuView(debugMenuViewModel: debugMenuViewModel)
          }
          #endif

        RegistrationView(viewModel: wearablesViewModel)
      } else {
        ContentUnavailableView(
          "No se pudo iniciar Meta Wearables",
          systemImage: "exclamationmark.triangle",
          description: Text(configurationError ?? "Revisa la configuración MWDAT del bundle.")
        )
        .padding()
      }
    }
  }
}

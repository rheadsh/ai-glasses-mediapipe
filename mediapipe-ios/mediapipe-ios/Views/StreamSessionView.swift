/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  let wearables: WearablesInterface
  var wearablesViewModel: WearablesViewModel
  // Created once in `.task`. `State(wrappedValue:)` would evaluate its argument on every
  // re-init of this view and build (then discard) a view model with live DAT observers.
  @State private var viewModel: StreamSessionViewModel?

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
  }

  var body: some View {
    ZStack {
      if let viewModel {
        StreamSessionContent(viewModel: viewModel, wearablesViewModel: wearablesViewModel)
      }
    }
    .task {
      if viewModel == nil {
        viewModel = StreamSessionViewModel(wearables: wearables)
      }
    }
    .onDisappear {
      // Leaving the flow ends the stream, the device session and OSC output.
      viewModel?.endSession()
      viewModel?.oscOutput.shutdown()
    }
  }
}

private struct StreamSessionContent: View {
  @Bindable var viewModel: StreamSessionViewModel
  var wearablesViewModel: WearablesViewModel
  @State private var showOSCSettings = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        // Pre-streaming setup view with permissions and start button
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 8) {
        Button {
          showOSCSettings = true
        } label: {
          Label(viewModel.oscOutput.enabled ? "OSC activo" : "Configurar OSC", systemImage: "antenna.radiowaves.left.and.right")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityIdentifier("osc_settings_button")

        // The codec is fixed when the stream starts, so it can only change while stopped.
        Toggle(isOn: $viewModel.keepsRunningWhenLocked) {
          Label("Con pantalla bloqueada", systemImage: "lock.iphone")
            .font(.subheadline.weight(.semibold))
        }
        .toggleStyle(.button)
        .disabled(viewModel.isStreaming)
        .accessibilityIdentifier("background_mode_toggle")
      }
      .padding(.bottom, 8)
    }
    // The camera screens are drawn on black; a dark scheme keeps the status bar, menus,
    // sheets and system text legible in both system appearances.
    .preferredColorScheme(.dark)
    .onChange(of: scenePhase) { _, phase in
      viewModel.appActivityChanged(isActive: phase == .active)
    }
    .sheet(isPresented: $showOSCSettings) {
      OSCSettingsView(output: viewModel.oscOutput)
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    .alert("Photo capture failed", isPresented: $viewModel.showPhotoCaptureError) {
      Button("OK") {
        viewModel.dismissPhotoCaptureError()
      }
    } message: {
      Text("Unable to capture photo. This may be due to low storage on device or another capture already in progress. Please try again in a few moments.")
    }
  }
}

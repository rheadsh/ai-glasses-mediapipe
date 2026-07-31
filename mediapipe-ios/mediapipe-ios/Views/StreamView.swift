/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @Bindable var viewModel: StreamSessionViewModel
  var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          ZStack(alignment: .topLeading) {
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()

            if viewModel.isVisionAnalysisActive,
              let mask = viewModel.segmentationMask
            {
              Image(uiImage: mask)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .allowsHitTesting(false)
            }

            if viewModel.isVisionAnalysisActive {
              VisionOverlay(
                detections: viewModel.objectDetections,
                landmarkGroups: viewModel.landmarkGroups,
                imageSize: videoFrame.size,
                containerSize: geometry.size
              )
              .allowsHitTesting(false)
            }
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
          .contentShape(Rectangle())
          .onTapGesture { location in
            guard viewModel.selectedVisionTask == .interactiveSegmentation,
              let point = DetectionGeometry.normalizedImagePoint(
                aspectFillPoint: location,
                imageSize: videoFrame.size,
                containerSize: geometry.size
              )
            else { return }
            viewModel.selectInteractiveSegmentationPoint(point)
          }
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundStyle(.white)
      }

      VStack {
        AnalysisStatusView(viewModel: viewModel)
          .padding(.top, 8)
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      if viewModel.streamingStatus != .stopped {
        viewModel.stopSession()
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  var viewModel: StreamSessionViewModel

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        viewModel.stopSession()
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }
      .accessibilityIdentifier("capture_photo_button")

      Button {
        viewModel.toggleVisionAnalysis()
      } label: {
        Image(
          systemName: viewModel.isVisionAnalysisActive
            ? "viewfinder.circle.fill" : "viewfinder.circle"
        )
        .font(.title2)
        .foregroundStyle(viewModel.isVisionAnalysisActive ? .black : .white)
        .frame(width: 52, height: 52)
        .background(
          viewModel.isVisionAnalysisActive ? Color.green : Color.white.opacity(0.18),
          in: Circle()
        )
      }
      .disabled(!viewModel.isSelectedVisionTaskConfigured)
      .opacity(viewModel.isSelectedVisionTaskConfigured ? 1 : 0.45)
      .accessibilityLabel(
        viewModel.isVisionAnalysisActive
          ? "Desactivar análisis de MediaPipe"
          : "Activar análisis de MediaPipe"
      )
      .accessibilityIdentifier("toggle_object_detection_button")

      Menu {
        MediaPipeVisionTaskMenuContent(viewModel: viewModel)
      } label: {
        Image(systemName: "square.grid.2x2")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 52, height: 52)
          .background(Color.white.opacity(0.18), in: Circle())
      }
      .accessibilityLabel("Cambiar Vision Task de MediaPipe")
      .accessibilityValue(viewModel.selectedVisionTask.displayName)
      .accessibilityIdentifier("select_mediapipe_task_button")

      if viewModel.selectedVisionTask == .objectDetection {
        Menu {
          ObjectDetectionModelMenuContent(viewModel: viewModel)
        } label: {
          Image(systemName: "cpu")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.18), in: Circle())
        }
        .accessibilityLabel("Cambiar modelo de MediaPipe")
        .accessibilityValue(viewModel.selectedObjectDetectionModel.displayName)
        .accessibilityIdentifier("select_mediapipe_model_button")
      }
    }
  }
}

private struct AnalysisStatusView: View {
  var viewModel: StreamSessionViewModel

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(statusColor)
        .frame(width: 9, height: 9)

      VStack(alignment: .leading, spacing: 2) {
        Text(statusTitle)
          .font(.caption.weight(.semibold))
        if let detailText {
          Text(detailText)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 12)

      if viewModel.isVisionAnalysisActive {
        Text("\(viewModel.analysisResultCount) resultados")
          .font(.caption.monospacedDigit())
      } else if !viewModel.isSelectedVisionTaskConfigured {
        Text("Sin pipeline")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Pausado")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  private var statusColor: Color {
    guard viewModel.isSelectedVisionTaskConfigured else { return .orange }
    guard viewModel.isVisionAnalysisActive else { return .gray }
    switch viewModel.visionAnalysisStatus {
    case .preparing:
      return .yellow
    case .ready:
      return .green
    case .unavailable:
      return .red
    }
  }

  private var detailText: String? {
    guard viewModel.isSelectedVisionTaskConfigured else {
      return viewModel.selectedVisionTask.configurationMessage
    }
    switch viewModel.visionAnalysisStatus {
    case .preparing:
      return "Cargando \(selectedModelName)"
    case .ready:
      guard let inference = viewModel.inferenceTimeMilliseconds else {
        return "Esperando el primer resultado"
      }
      let performance = String(
        format: "%.0f ms · frame %d", inference, viewModel.analyzedFrameCount)
      return viewModel.analysisSummary.isEmpty
        ? performance : "\(viewModel.analysisSummary) · \(performance)"
    case .unavailable(let message):
      return message
    }
  }

  private var statusTitle: String {
    "\(viewModel.visionAnalysisStatus.title) · \(viewModel.selectedVisionTask.displayName)"
  }

  private var selectedModelName: String {
    viewModel.selectedVisionTask == .objectDetection
      ? viewModel.selectedObjectDetectionModel.displayName
      : viewModel.selectedVisionTask.modelDisplayName
  }
}

private struct VisionOverlay: View {
  let detections: [ObjectDetection]
  let landmarkGroups: [VisionLandmarkGroup]
  let imageSize: CGSize
  let containerSize: CGSize

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(detections) { detection in
        let box = DetectionGeometry.aspectFillRect(
          normalizedBox: detection.normalizedBoundingBox,
          imageSize: imageSize,
          containerSize: containerSize
        )

        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 6)
            .stroke(.green, lineWidth: 3)

          Text("\(detection.label) \(Int(detection.score * 100))%")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.black)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.green, in: RoundedRectangle(cornerRadius: 4))
            .offset(y: -1)
        }
        .frame(width: max(box.width, 1), height: max(box.height, 1))
        .position(x: box.midX, y: box.midY)
      }

      ForEach(landmarkGroups) { group in
        let color = overlayColor(group.style)
        Canvas { context, _ in
          for connection in group.connections
          where group.points.indices.contains(connection.start)
            && group.points.indices.contains(connection.end)
          {
            var path = Path()
            path.move(to: projected(group.points[connection.start]))
            path.addLine(to: projected(group.points[connection.end]))
            context.stroke(path, with: .color(color), lineWidth: 2)
          }
          for point in group.points {
            let center = projected(point)
            let rect = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: rect), with: .color(color))
          }
        }
      }
    }
  }

  private func projected(_ point: CGPoint) -> CGPoint {
    DetectionGeometry.aspectFillPoint(
      normalizedPoint: point,
      imageSize: imageSize,
      containerSize: containerSize
    )
  }

  private func overlayColor(_ style: VisionOverlayStyle) -> Color {
    switch style {
    case .green: return .green
    case .cyan: return .cyan
    case .orange: return .orange
    case .pink: return .pink
    case .purple: return .purple
    }
  }
}

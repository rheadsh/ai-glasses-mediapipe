/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import UIKit
import XCTest

@testable import mediapipe_ios

final class MediaPipePipelineTests: XCTestCase {
  func testVisionTaskCatalogMatchesMediaPipeTasksVisionForIOS() {
    XCTAssertEqual(MediaPipeVisionTask.allCases.count, 11)
    XCTAssertEqual(
      MediaPipeVisionTask.allCases.filter(\.isConfigured),
      MediaPipeVisionTask.allCases
    )
  }

  func testAllBundledVisionTasksInitializeAndRunOneAtATime() async throws {
    let imagePath = try XCTUnwrap(Bundle.main.path(forResource: "plant", ofType: "png"))
    let image = try XCTUnwrap(UIImage(contentsOfFile: imagePath))
    let analyzer = MediaPipeVisionAnalyzer()
    defer { analyzer.reset() }

    for task in MediaPipeVisionTask.allCases {
      let modelPath: String?
      if task == .objectDetection {
        modelPath = ObjectDetectionModel.efficientDetLite0.bundledModelPath
      } else {
        modelPath = task.bundledModelPath
      }
      let path = try XCTUnwrap(modelPath, "Missing bundled model for \(task.displayName)")

      let _: Void = try await callbackValue("Configure \(task.displayName)") { completion in
        analyzer.configure(task: task, modelPath: path, completion: completion)
      }
      let result: VisionAnalysisResult = try await callbackValue("Analyze \(task.displayName)") { completion in
        analyzer.submit(image: image, interactionPoint: CGPoint(x: 0.5, y: 0.5), completion: completion)
      }
      XCTAssertGreaterThan(result.inferenceTimeMilliseconds, 0, task.displayName)
      let oscMessages = OSCTrackingMessages.make(result, task: task)
      XCTAssertFalse(OSCPacketEncoder.packets(messages: oscMessages, frameID: 1).isEmpty)
      // The advertised group count must match the landmark groups actually sent.
      let root = "/mediapipe/\(task.rawValue)"
      let counts = oscMessages.first { $0.address == root + "/counts" }?.arguments
      XCTAssertEqual(counts?.count, 3, task.displayName)
      XCTAssertEqual(counts?[2], .int(Int32(result.landmarkGroups.count)), task.displayName)
      XCTAssertEqual(
        oscMessages.filter { $0.address.hasSuffix("/count") && $0.address.contains("/landmarks/") }.count,
        result.landmarkGroups.count, task.displayName)
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

  }

  func testBothObjectDetectionModelsProcessBundledFixture() async throws {
    let image = try XCTUnwrap(UIImage(contentsOfFile: try fixtureURL("plant", extension: "png").path))
    // Same analyzer the app uses, so both bundled models are checked through the real path.
    let analyzer = MediaPipeVisionAnalyzer()
    defer { analyzer.reset() }
    for model in ObjectDetectionModel.allCases {
      let modelPath = try XCTUnwrap(model.bundledModelPath,
        "Missing bundled model: \(model.resourceName).tflite")
      let _: Void = try await callbackValue("Configure \(model.displayName)") { completion in
        analyzer.configure(task: .objectDetection, modelPath: modelPath, completion: completion)
      }
      let result: VisionAnalysisResult = try await callbackValue("Detect \(model.displayName)") { completion in
        analyzer.submit(image: image, interactionPoint: nil, completion: completion)
      }
      XCTAssertGreaterThan(result.inferenceTimeMilliseconds, 0, model.displayName)
      for detection in result.detections {
        XCTAssertGreaterThanOrEqual(detection.score, 0)
        XCTAssertLessThanOrEqual(detection.score, 1)
        XCTAssertGreaterThanOrEqual(detection.normalizedBoundingBox.minX, 0)
        XCTAssertGreaterThanOrEqual(detection.normalizedBoundingBox.minY, 0)
        XCTAssertLessThanOrEqual(detection.normalizedBoundingBox.maxX, 1)
        XCTAssertLessThanOrEqual(detection.normalizedBoundingBox.maxY, 1)
      }
    }
  }
}

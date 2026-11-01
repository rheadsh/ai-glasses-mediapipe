/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import CoreGraphics
import XCTest

@testable import mediapipe_ios

final class DetectionGeometryTests: XCTestCase {
  func testNormalizesAndClipsBoundingBoxes() {
    let result = DetectionGeometry.normalized(
      CGRect(x: -10, y: 20, width: 70, height: 100),
      imageSize: CGSize(width: 100, height: 200)
    )

    XCTAssertEqual(result.minX, 0, accuracy: 0.0001)
    XCTAssertEqual(result.minY, 0.1, accuracy: 0.0001)
    XCTAssertEqual(result.width, 0.6, accuracy: 0.0001)
    XCTAssertEqual(result.height, 0.5, accuracy: 0.0001)
  }

  func testProjectsNormalizedBoxIntoAspectFillPreview() {
    let result = DetectionGeometry.aspectFillRect(
      normalizedBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
      imageSize: CGSize(width: 360, height: 640),
      containerSize: CGSize(width: 400, height: 400)
    )

    XCTAssertEqual(result.minX, 100, accuracy: 0.01)
    XCTAssertEqual(result.minY, 22.22, accuracy: 0.01)
    XCTAssertEqual(result.width, 200, accuracy: 0.01)
    XCTAssertEqual(result.height, 355.56, accuracy: 0.01)
  }

  func testMapsAspectFillTouchBackToImageCoordinates() throws {
    let point = try XCTUnwrap(
      DetectionGeometry.normalizedImagePoint(
        aspectFillPoint: CGPoint(x: 200, y: 200),
        imageSize: CGSize(width: 360, height: 640),
        containerSize: CGSize(width: 400, height: 400)
      )
    )
    XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
  }
}

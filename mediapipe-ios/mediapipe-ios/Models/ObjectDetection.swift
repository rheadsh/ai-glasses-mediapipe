import CoreGraphics
import Foundation
import UIKit

enum ObjectDetectionModel: String, CaseIterable, Identifiable, Sendable {
  case efficientDetLite0
  case efficientDetLite2

  var id: String { rawValue }

  var resourceName: String {
    switch self {
    case .efficientDetLite0:
      return "efficientdet_lite0"
    case .efficientDetLite2:
      return "efficientdet_lite2"
    }
  }

  var displayName: String {
    switch self {
    case .efficientDetLite0:
      return "EfficientDet Lite0"
    case .efficientDetLite2:
      return "EfficientDet Lite2"
    }
  }

  var detail: String {
    switch self {
    case .efficientDetLite0:
      return "Más rápido"
    case .efficientDetLite2:
      return "Mayor precisión"
    }
  }

  var bundledModelPath: String? {
    Bundle.main.path(forResource: resourceName, ofType: "tflite")
  }
}

/// A MediaPipe detection expressed in normalized image coordinates.
struct ObjectDetection: Identifiable, Equatable, Sendable {
  let id: UUID
  let label: String
  let score: Float
  let normalizedBoundingBox: CGRect

  init(
    id: UUID = UUID(),
    label: String,
    score: Float,
    normalizedBoundingBox: CGRect
  ) {
    self.id = id
    self.label = label
    self.score = score
    self.normalizedBoundingBox = normalizedBoundingBox
  }
}

enum VisionOverlayStyle: Int, Sendable {
  case green
  case cyan
  case orange
  case pink
  case purple
}

struct VisionLandmarkConnection: Hashable, Sendable {
  let start: Int
  let end: Int
}

struct VisionLandmarkGroup: Identifiable, Sendable {
  let id = UUID()
  let points: [CGPoint]
  let connections: [VisionLandmarkConnection]
  let style: VisionOverlayStyle
}

struct VisionAnalysisResult: @unchecked Sendable {
  var oscMessages: [OSCMessage] = []
  let detections: [ObjectDetection]
  let landmarkGroups: [VisionLandmarkGroup]
  let maskImage: UIImage?
  let summary: String
  let resultCount: Int
  let inferenceTimeMilliseconds: Double
}

enum VisionAnalysisStatus: Equatable {
  case preparing
  case ready
  case unavailable(String)

  var title: String {
    switch self {
    case .preparing: return "Preparando MediaPipe"
    case .ready: return "MediaPipe activo"
    case .unavailable: return "MediaPipe no disponible"
    }
  }
}

enum DetectionGeometry {
  /// Converts a pixel-space MediaPipe box to the normalized coordinate system used by SwiftUI.
  static func normalized(_ boundingBox: CGRect, imageSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

    let imageBounds = CGRect(origin: .zero, size: imageSize)
    let clipped = boundingBox.standardized.intersection(imageBounds)
    guard !clipped.isNull, !clipped.isEmpty else { return .zero }

    return CGRect(
      x: clipped.minX / imageSize.width,
      y: clipped.minY / imageSize.height,
      width: clipped.width / imageSize.width,
      height: clipped.height / imageSize.height
    )
  }

  /// Projects a normalized box onto an aspect-fill preview, including its cropped offsets.
  static func aspectFillRect(
    normalizedBox: CGRect,
    imageSize: CGSize,
    containerSize: CGSize
  ) -> CGRect {
    guard imageSize.width > 0,
      imageSize.height > 0,
      containerSize.width > 0,
      containerSize.height > 0
    else {
      return .zero
    }

    let scale = max(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height
    )
    let renderedSize = CGSize(
      width: imageSize.width * scale,
      height: imageSize.height * scale
    )
    let offset = CGPoint(
      x: (containerSize.width - renderedSize.width) / 2,
      y: (containerSize.height - renderedSize.height) / 2
    )

    return CGRect(
      x: offset.x + normalizedBox.minX * renderedSize.width,
      y: offset.y + normalizedBox.minY * renderedSize.height,
      width: normalizedBox.width * renderedSize.width,
      height: normalizedBox.height * renderedSize.height
    )
  }

  static func aspectFillPoint(
    normalizedPoint: CGPoint,
    imageSize: CGSize,
    containerSize: CGSize
  ) -> CGPoint {
    let projected = aspectFillRect(
      normalizedBox: CGRect(origin: normalizedPoint, size: .zero),
      imageSize: imageSize,
      containerSize: containerSize
    )
    return projected.origin
  }

  /// Maps a touch on an aspect-fill preview back to normalized image coordinates.
  static func normalizedImagePoint(
    aspectFillPoint point: CGPoint,
    imageSize: CGSize,
    containerSize: CGSize
  ) -> CGPoint? {
    guard imageSize.width > 0, imageSize.height > 0,
      containerSize.width > 0, containerSize.height > 0
    else { return nil }

    let scale = max(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height
    )
    let renderedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let offset = CGPoint(
      x: (containerSize.width - renderedSize.width) / 2,
      y: (containerSize.height - renderedSize.height) / 2
    )
    let normalized = CGPoint(
      x: (point.x - offset.x) / renderedSize.width,
      y: (point.y - offset.y) / renderedSize.height
    )
    guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
    return normalized
  }
}

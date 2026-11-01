import Foundation

/// Vision tasks exposed by MediaPipeTasksVision 0.10.35 on iOS.
enum MediaPipeVisionTask: String, CaseIterable, Identifiable, Sendable {
  case objectDetection
  case imageClassification
  case imageSegmentation
  case interactiveSegmentation
  case gestureRecognition
  case handLandmarkDetection
  case imageEmbedding
  case faceDetection
  case faceLandmarkDetection
  case poseLandmarkDetection
  case holisticLandmarkDetection

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .objectDetection:
      return "Object detection"
    case .imageClassification:
      return "Image classification"
    case .imageSegmentation:
      return "Image segmentation"
    case .interactiveSegmentation:
      return "Interactive segmentation"
    case .gestureRecognition:
      return "Gesture recognition"
    case .handLandmarkDetection:
      return "Hand landmark detection"
    case .imageEmbedding:
      return "Image embedding"
    case .faceDetection:
      return "Face detection"
    case .faceLandmarkDetection:
      return "Face landmark detection"
    case .poseLandmarkDetection:
      return "Pose landmark detection"
    case .holisticLandmarkDetection:
      return "Holistic landmark detection"
    }
  }

  var systemImage: String {
    switch self {
    case .objectDetection:
      return "viewfinder"
    case .imageClassification:
      return "tag"
    case .imageSegmentation:
      return "square.3.layers.3d"
    case .interactiveSegmentation:
      return "hand.tap"
    case .gestureRecognition:
      return "hand.raised"
    case .handLandmarkDetection:
      return "hand.point.up.left"
    case .imageEmbedding:
      return "point.3.connected.trianglepath.dotted"
    case .faceDetection:
      return "face.smiling"
    case .faceLandmarkDetection:
      return "face.dashed"
    case .poseLandmarkDetection:
      return "figure.stand"
    case .holisticLandmarkDetection:
      return "figure.arms.open"
    }
  }

  var resourceName: String {
    switch self {
    case .objectDetection: return "efficientdet_lite0"
    case .imageClassification: return "efficientnet_lite0"
    case .imageSegmentation: return "selfie_segmenter"
    case .interactiveSegmentation: return "magic_touch"
    case .gestureRecognition: return "gesture_recognizer"
    case .handLandmarkDetection: return "hand_landmarker"
    case .imageEmbedding: return "mobilenet_v3_small"
    case .faceDetection: return "blaze_face_short_range"
    case .faceLandmarkDetection: return "face_landmarker"
    case .poseLandmarkDetection: return "pose_landmarker_lite"
    case .holisticLandmarkDetection: return "holistic_landmarker"
    }
  }

  var resourceExtension: String {
    switch self {
    case .gestureRecognition, .handLandmarkDetection, .faceLandmarkDetection,
      .poseLandmarkDetection, .holisticLandmarkDetection:
      return "task"
    default:
      return "tflite"
    }
  }

  var modelDisplayName: String {
    switch self {
    case .objectDetection: return "EfficientDet Lite0"
    case .imageClassification: return "EfficientNet Lite0"
    case .imageSegmentation: return "Selfie Segmenter"
    case .interactiveSegmentation: return "Magic Touch"
    case .gestureRecognition: return "Gesture Recognizer"
    case .handLandmarkDetection: return "Hand Landmarker"
    case .imageEmbedding: return "MobileNet V3 Small"
    case .faceDetection: return "BlazeFace Short Range"
    case .faceLandmarkDetection: return "Face Landmarker"
    case .poseLandmarkDetection: return "Pose Landmarker Lite"
    case .holisticLandmarkDetection: return "Holistic Landmarker"
    }
  }

  var bundledModelPath: String? {
    Bundle.main.path(forResource: resourceName, ofType: resourceExtension)
  }

  var isConfigured: Bool {
    bundledModelPath != nil
  }

  var availabilityLabel: String {
    isConfigured ? "Configurada" : "Requiere modelo"
  }

  var configurationMessage: String {
    if isConfigured {
      return "\(modelDisplayName) está listo para el stream de los lentes."
    }
    return
      "No se encontró \(resourceName).\(resourceExtension) en el bundle de la app."
  }
}

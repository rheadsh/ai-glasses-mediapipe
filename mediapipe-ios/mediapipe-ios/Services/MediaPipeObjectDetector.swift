import Foundation
import MediaPipeTasksVision
import UIKit

enum MediaPipeObjectDetectorError: LocalizedError {
  case modelNotFound
  case imageConversionFailed
  case detectorUnavailable

  var errorDescription: String? {
    switch self {
    case .modelNotFound:
      return "No se encontró el modelo .tflite solicitado en el bundle de la app."
    case .imageConversionFailed:
      return "MediaPipe no pudo convertir el frame recibido desde las gafas."
    case .detectorUnavailable:
      return "El detector de objetos de MediaPipe no está preparado."
    }
  }
}

/// Serial, back-pressure-aware adapter between DAT camera frames and MediaPipe Tasks.
///
/// ObjectDetector in image mode blocks the calling thread. All work therefore runs on a
/// dedicated queue, and incoming frames are dropped while an inference is already in flight.
final class MediaPipeObjectDetector: ObjectDetecting, @unchecked Sendable {
  private let modelPath: String
  private let scoreThreshold: Float
  private let maxResults: Int
  private let inferenceQueue = DispatchQueue(
    label: "com.rheadsh.mediapipe-ios.object-detector",
    qos: .userInitiated
  )
  private let stateLock = NSLock()

  private var detector: ObjectDetector?
  private var isPreparing = false
  private var isProcessingFrame = false

  init(
    modelPath: String,
    scoreThreshold: Float = 0.45,
    maxResults: Int = 5
  ) {
    self.modelPath = modelPath
    self.scoreThreshold = scoreThreshold
    self.maxResults = maxResults
  }

  static func bundledModelPath(for model: ObjectDetectionModel) -> String? {
    Bundle.main.path(forResource: model.resourceName, ofType: "tflite")
  }

  func prepare(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    stateLock.lock()
    if detector != nil {
      stateLock.unlock()
      completion(.success(()))
      return
    }
    guard !isPreparing else {
      stateLock.unlock()
      return
    }
    isPreparing = true
    stateLock.unlock()

    inferenceQueue.async { [weak self] in
      guard let self else { return }
      let result: Result<Void, Error>

      do {
        guard FileManager.default.fileExists(atPath: self.modelPath) else {
          throw MediaPipeObjectDetectorError.modelNotFound
        }

        let options = ObjectDetectorOptions()
        options.baseOptions.modelAssetPath = self.modelPath
        options.runningMode = .image
        options.scoreThreshold = self.scoreThreshold
        options.maxResults = self.maxResults
        let detector = try ObjectDetector(options: options)

        self.stateLock.lock()
        self.detector = detector
        self.isPreparing = false
        self.stateLock.unlock()
        result = .success(())
      } catch {
        self.stateLock.lock()
        self.isPreparing = false
        self.stateLock.unlock()
        result = .failure(error)
      }

      completion(result)
    }
  }

  func submit(
    image: UIImage,
    completion: @escaping @Sendable (Result<ObjectDetectionResult, Error>) -> Void
  ) {
    stateLock.lock()
    guard detector != nil else {
      stateLock.unlock()
      completion(.failure(MediaPipeObjectDetectorError.detectorUnavailable))
      return
    }
    guard !isProcessingFrame else {
      stateLock.unlock()
      return
    }
    isProcessingFrame = true
    stateLock.unlock()

    inferenceQueue.async { [weak self] in
      guard let self else { return }
      defer {
        self.stateLock.lock()
        self.isProcessingFrame = false
        self.stateLock.unlock()
      }

      autoreleasepool {
        do {
          guard let detector = self.detector else {
            throw MediaPipeObjectDetectorError.detectorUnavailable
          }

          let mediaPipeImage = try MPImage(uiImage: image)
          let start = ContinuousClock.now
          let result = try detector.detect(image: mediaPipeImage)
          let elapsed = start.duration(to: .now)
          let inferenceMilliseconds =
            Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

          let detections = result.detections.compactMap { detection -> ObjectDetection? in
            guard let category = detection.categories.first else { return nil }
            let normalizedBox = DetectionGeometry.normalized(
              detection.boundingBox,
              imageSize: image.size
            )
            guard !normalizedBox.isEmpty else { return nil }

            return ObjectDetection(
              label: category.displayName ?? category.categoryName ?? "Objeto",
              score: category.score,
              normalizedBoundingBox: normalizedBox
            )
          }

          completion(
            .success(
              ObjectDetectionResult(
                detections: detections,
                inferenceTimeMilliseconds: inferenceMilliseconds
              )
            )
          )
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  func reset() {}
}

enum MediaPipeVisionAnalyzerError: LocalizedError {
  case modelNotFound(String)
  case analyzerUnavailable
  case unsupportedTask

  var errorDescription: String? {
    switch self {
    case .modelNotFound(let filename):
      return "No se encontró \(filename) en el bundle."
    case .analyzerUnavailable:
      return "La tarea de MediaPipe todavía no está preparada."
    case .unsupportedTask:
      return "La tarea seleccionada no está disponible en esta versión de MediaPipe."
    }
  }
}

/// Owns exactly one MediaPipe task at a time.
///
/// Configuration and inference share one serial queue. A model switch first releases the old
/// runtime and only then initializes the new one, so two models are never executing concurrently.
final class MediaPipeVisionAnalyzer: @unchecked Sendable {
  private enum Runtime {
    case objectDetector(ObjectDetector)
    case imageClassifier(ImageClassifier)
    case imageSegmenter(ImageSegmenter)
    case interactiveSegmenter(InteractiveSegmenter)
    case gestureRecognizer(GestureRecognizer)
    case handLandmarker(HandLandmarker)
    case imageEmbedder(ImageEmbedder)
    case faceDetector(FaceDetector)
    case faceLandmarker(FaceLandmarker)
    case poseLandmarker(PoseLandmarker)
    case holisticLandmarker(HolisticLandmarker)
  }

  private let inferenceQueue = DispatchQueue(
    label: "com.rheadsh.mediapipe-ios.vision-analyzer",
    qos: .userInitiated
  )
  private let stateLock = NSLock()
  private var runtime: Runtime?
  private var configuredTask: MediaPipeVisionTask?
  private var isProcessingFrame = false
  private var generation = 0

  func configure(
    task: MediaPipeVisionTask,
    modelPath: String,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    stateLock.lock()
    generation += 1
    let requestedGeneration = generation
    stateLock.unlock()

    inferenceQueue.async { [weak self] in
      guard let self else { return }
      autoreleasepool {
        do {
          guard FileManager.default.fileExists(atPath: modelPath) else {
            throw MediaPipeVisionAnalyzerError.modelNotFound(
              URL(fileURLWithPath: modelPath).lastPathComponent
            )
          }

          // This assignment releases the previous model before creating the next one.
          self.runtime = nil
          self.configuredTask = nil
          let runtime = try Self.makeRuntime(task: task, modelPath: modelPath)

          self.stateLock.lock()
          let isCurrent = self.generation == requestedGeneration
          self.stateLock.unlock()
          guard isCurrent else { return }

          self.runtime = runtime
          self.configuredTask = task
          completion(.success(()))
        } catch {
          self.runtime = nil
          self.configuredTask = nil
          completion(.failure(error))
        }
      }
    }
  }

  func submit(
    image: UIImage,
    interactionPoint: CGPoint?,
    completion: @escaping @Sendable (Result<VisionAnalysisResult, Error>) -> Void
  ) {
    stateLock.lock()
    guard !isProcessingFrame else {
      stateLock.unlock()
      return
    }
    isProcessingFrame = true
    let requestedGeneration = generation
    stateLock.unlock()

    inferenceQueue.async { [weak self] in
      guard let self else { return }
      defer {
        self.stateLock.lock()
        self.isProcessingFrame = false
        self.stateLock.unlock()
      }

      autoreleasepool {
        do {
          guard let runtime = self.runtime else {
            throw MediaPipeVisionAnalyzerError.analyzerUnavailable
          }
          let mediaPipeImage = try MPImage(uiImage: image)
          let start = ContinuousClock.now
          let result = try Self.analyze(
            runtime: runtime,
            image: mediaPipeImage,
            imageSize: image.size,
            interactionPoint: interactionPoint
          )
          let elapsed = start.duration(to: .now)
          let milliseconds =
            Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

          self.stateLock.lock()
          let isCurrent = self.generation == requestedGeneration
          self.stateLock.unlock()
          guard isCurrent else { return }

          completion(
            .success(
              VisionAnalysisResult(
                detections: result.detections,
                landmarkGroups: result.landmarkGroups,
                maskImage: result.maskImage,
                summary: result.summary,
                resultCount: result.resultCount,
                inferenceTimeMilliseconds: milliseconds
              )
            )
          )
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  func reset() {
    stateLock.lock()
    generation += 1
    stateLock.unlock()
    inferenceQueue.async { [weak self] in
      self?.runtime = nil
      self?.configuredTask = nil
    }
  }

  private static func makeRuntime(
    task: MediaPipeVisionTask,
    modelPath: String
  ) throws -> Runtime {
    switch task {
    case .objectDetection:
      let options = ObjectDetectorOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.scoreThreshold = 0.45
      options.maxResults = 5
      return .objectDetector(try ObjectDetector(options: options))

    case .imageClassification:
      let options = ImageClassifierOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.scoreThreshold = 0.15
      options.maxResults = 3
      return .imageClassifier(try ImageClassifier(options: options))

    case .imageSegmentation:
      let options = ImageSegmenterOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.shouldOutputConfidenceMasks = true
      return .imageSegmenter(try ImageSegmenter(options: options))

    case .interactiveSegmentation:
      let options = InteractiveSegmenterOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.shouldOutputConfidenceMasks = true
      return .interactiveSegmenter(try InteractiveSegmenter(options: options))

    case .gestureRecognition:
      let options = GestureRecognizerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.numHands = 2
      return .gestureRecognizer(try GestureRecognizer(options: options))

    case .handLandmarkDetection:
      let options = HandLandmarkerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.numHands = 2
      return .handLandmarker(try HandLandmarker(options: options))

    case .imageEmbedding:
      let options = ImageEmbedderOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      return .imageEmbedder(try ImageEmbedder(options: options))

    case .faceDetection:
      let options = FaceDetectorOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      return .faceDetector(try FaceDetector(options: options))

    case .faceLandmarkDetection:
      let options = FaceLandmarkerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.numFaces = 2
      return .faceLandmarker(try FaceLandmarker(options: options))

    case .poseLandmarkDetection:
      let options = PoseLandmarkerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      options.numPoses = 2
      return .poseLandmarker(try PoseLandmarker(options: options))

    case .holisticLandmarkDetection:
      let options = HolisticLandmarkerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.runningMode = .image
      return .holisticLandmarker(try HolisticLandmarker(options: options))
    }
  }

  private static func analyze(
    runtime: Runtime,
    image: MPImage,
    imageSize: CGSize,
    interactionPoint: CGPoint?
  ) throws -> VisionAnalysisResult {
    switch runtime {
    case .objectDetector(let detector):
      let result = try detector.detect(image: image)
      let detections = detections(from: result.detections, imageSize: imageSize)
      return makeResult(
        detections: detections, summary: detections.isEmpty ? "Sin objetos" : "Objetos detectados",
        count: detections.count)

    case .imageClassifier(let classifier):
      let result = try classifier.classify(image: image)
      let categories = result.classificationResult.classifications.first?.categories ?? []
      let summary = categories.prefix(3).map {
        "\($0.displayName ?? $0.categoryName ?? "Clase") \(Int($0.score * 100))%"
      }.joined(separator: " · ")
      return VisionAnalysisResult(
        detections: [],
        landmarkGroups: [],
        maskImage: nil,
        summary: summary.isEmpty ? "Sin clasificación" : summary,
        resultCount: categories.count,
        inferenceTimeMilliseconds: 0
      )

    case .imageSegmenter(let segmenter):
      let result = try segmenter.segment(image: image)
      let mask = result.confidenceMasks?.first.flatMap { maskImage(from: $0, style: .cyan) }
      return VisionAnalysisResult(
        detections: [], landmarkGroups: [], maskImage: mask,
        summary: mask == nil ? "Sin máscara" : "Persona segmentada",
        resultCount: mask == nil ? 0 : 1, inferenceTimeMilliseconds: 0)

    case .interactiveSegmenter(let segmenter):
      let point = interactionPoint ?? CGPoint(x: 0.5, y: 0.5)
      let keypoint = NormalizedKeypoint(location: point, label: nil, score: 0)
      let roi = RegionOfInterest(normalizedKeyPoint: keypoint)
      let result = try segmenter.segment(image: image, regionOfInterest: roi)
      let mask = result.confidenceMasks?.first.flatMap { maskImage(from: $0, style: .purple) }
      let pointGroup = VisionLandmarkGroup(points: [point], connections: [], style: .orange)
      return VisionAnalysisResult(
        detections: [], landmarkGroups: [pointGroup], maskImage: mask,
        summary: mask == nil
          ? "Toca el objeto a segmentar" : "Segmentación en el punto seleccionado",
        resultCount: mask == nil ? 0 : 1, inferenceTimeMilliseconds: 0)

    case .gestureRecognizer(let recognizer):
      let result = try recognizer.recognize(image: image)
      let groups = landmarkGroups(
        result.landmarks, connections: HandLandmarker.handConnections, style: .green)
      let gestures = result.gestures.compactMap { $0.first }.map {
        "\($0.categoryName ?? "Gesto") \(Int($0.score * 100))%"
      }
      return VisionAnalysisResult(
        detections: [], landmarkGroups: groups, maskImage: nil,
        summary: gestures.isEmpty ? "Sin gestos" : gestures.joined(separator: " · "),
        resultCount: gestures.count, inferenceTimeMilliseconds: 0)

    case .handLandmarker(let landmarker):
      let result = try landmarker.detect(image: image)
      let groups = landmarkGroups(
        result.landmarks, connections: HandLandmarker.handConnections, style: .green)
      let hands = result.handedness.compactMap { $0.first?.displayName ?? $0.first?.categoryName }
      return VisionAnalysisResult(
        detections: [], landmarkGroups: groups, maskImage: nil,
        summary: hands.isEmpty ? "Sin manos" : hands.joined(separator: " · "),
        resultCount: groups.count, inferenceTimeMilliseconds: 0)

    case .imageEmbedder(let embedder):
      let result = try embedder.embed(image: image)
      let embedding = result.embeddingResult.embeddings.first
      let dimensions = embedding?.floatEmbedding?.count ?? embedding?.quantizedEmbedding?.count ?? 0
      return VisionAnalysisResult(
        detections: [],
        landmarkGroups: [],
        maskImage: nil,
        summary: dimensions == 0 ? "Sin embedding" : "Vector de \(dimensions) dimensiones",
        resultCount: dimensions == 0 ? 0 : 1,
        inferenceTimeMilliseconds: 0
      )

    case .faceDetector(let detector):
      let result = try detector.detect(image: image)
      let detections = detections(
        from: result.detections, imageSize: imageSize, fallbackLabel: "Rostro")
      let keypointGroups = result.detections.compactMap { detection -> VisionLandmarkGroup? in
        guard let points = detection.keypoints?.map({ $0.location }), !points.isEmpty else {
          return nil
        }
        return VisionLandmarkGroup(points: points, connections: [], style: .cyan)
      }
      return VisionAnalysisResult(
        detections: detections, landmarkGroups: keypointGroups, maskImage: nil,
        summary: detections.isEmpty ? "Sin rostros" : "\(detections.count) rostro(s)",
        resultCount: detections.count, inferenceTimeMilliseconds: 0)

    case .faceLandmarker(let landmarker):
      let result = try landmarker.detect(image: image)
      let groups = landmarkGroups(result.faceLandmarks, connections: [], style: .pink)
      return VisionAnalysisResult(
        detections: [], landmarkGroups: groups, maskImage: nil,
        summary: groups.isEmpty
          ? "Sin rostros" : "Malla facial: \(groups.first?.points.count ?? 0) puntos",
        resultCount: groups.count, inferenceTimeMilliseconds: 0)

    case .poseLandmarker(let landmarker):
      let result = try landmarker.detect(image: image)
      let groups = landmarkGroups(
        result.landmarks, connections: PoseLandmarker.poseLandmarks, style: .orange)
      return VisionAnalysisResult(
        detections: [], landmarkGroups: groups, maskImage: nil,
        summary: groups.isEmpty ? "Sin poses" : "\(groups.count) pose(s)",
        resultCount: groups.count, inferenceTimeMilliseconds: 0)

    case .holisticLandmarker(let landmarker):
      let result = try landmarker.detect(image: image)
      var groups: [VisionLandmarkGroup] = []
      if !result.faceLandmarks.isEmpty {
        groups.append(group(result.faceLandmarks, connections: [], style: .pink))
      }
      if !result.poseLandmarks.isEmpty {
        groups.append(
          group(result.poseLandmarks, connections: PoseLandmarker.poseLandmarks, style: .orange))
      }
      if !result.leftHandLandmarks.isEmpty {
        groups.append(
          group(result.leftHandLandmarks, connections: HandLandmarker.handConnections, style: .cyan)
        )
      }
      if !result.rightHandLandmarks.isEmpty {
        groups.append(
          group(
            result.rightHandLandmarks, connections: HandLandmarker.handConnections, style: .green))
      }
      return VisionAnalysisResult(
        detections: [], landmarkGroups: groups, maskImage: nil,
        summary: groups.isEmpty ? "Sin landmarks" : "Rostro, pose y manos",
        resultCount: groups.count, inferenceTimeMilliseconds: 0)
    }
  }

  private static func makeResult(
    detections: [ObjectDetection],
    summary: String,
    count: Int
  ) -> VisionAnalysisResult {
    VisionAnalysisResult(
      detections: detections, landmarkGroups: [], maskImage: nil, summary: summary,
      resultCount: count, inferenceTimeMilliseconds: 0)
  }

  private static func detections(
    from values: [Detection],
    imageSize: CGSize,
    fallbackLabel: String = "Objeto"
  ) -> [ObjectDetection] {
    values.compactMap { detection in
      guard let category = detection.categories.first else { return nil }
      let normalizedBox = DetectionGeometry.normalized(detection.boundingBox, imageSize: imageSize)
      guard !normalizedBox.isEmpty else { return nil }
      return ObjectDetection(
        label: category.displayName ?? category.categoryName ?? fallbackLabel,
        score: category.score,
        normalizedBoundingBox: normalizedBox
      )
    }
  }

  private static func landmarkGroups(
    _ values: [[NormalizedLandmark]],
    connections: [Connection],
    style: VisionOverlayStyle
  ) -> [VisionLandmarkGroup] {
    values.map { group($0, connections: connections, style: style) }
  }

  private static func group(
    _ values: [NormalizedLandmark],
    connections: [Connection],
    style: VisionOverlayStyle
  ) -> VisionLandmarkGroup {
    VisionLandmarkGroup(
      points: values.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
      connections: connections.map {
        VisionLandmarkConnection(start: Int($0.start), end: Int($0.end))
      },
      style: style
    )
  }

  private static func maskImage(
    from mask: Mask,
    style: VisionOverlayStyle
  ) -> UIImage? {
    let width = mask.width
    let height = mask.height
    guard width > 0, height > 0 else { return nil }

    let color: (UInt8, UInt8, UInt8)
    switch style {
    case .cyan: color = (0, 220, 255)
    case .purple: color = (175, 90, 255)
    case .green: color = (55, 230, 130)
    case .orange: color = (255, 160, 40)
    case .pink: color = (255, 75, 165)
    }

    let confidence = mask.float32Data
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<(width * height) {
      let value = max(0, min(1, confidence[index]))
      let alpha = UInt8(value * 150)
      let offset = index * 4
      pixels[offset] = UInt8((UInt16(color.0) * UInt16(alpha)) / 255)
      pixels[offset + 1] = UInt8((UInt16(color.1) * UInt16(alpha)) / 255)
      pixels[offset + 2] = UInt8((UInt16(color.2) * UInt16(alpha)) / 255)
      pixels[offset + 3] = alpha
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let cgImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else { return nil }

    return UIImage(cgImage: cgImage)
  }
}

import UIKit

protocol ObjectDetecting: AnyObject {
  func prepare(completion: @escaping @Sendable (Result<Void, Error>) -> Void)
  func submit(
    image: UIImage,
    completion: @escaping @Sendable (Result<ObjectDetectionResult, Error>) -> Void
  )
  func reset()
}


import CoreMedia
import UIKit
import VideoToolbox

/// Converts DAT video frames into `UIImage`s on the CPU / VideoToolbox, never on the GPU.
///
/// iOS does not allow GPU work while the app is in the background or the phone is locked,
/// so `VideoFrame.makeUIImage()` cannot be relied on there. With `VideoCodec.hvc1` DAT keeps
/// streaming in the background but hands over compressed HEVC samples, which this class
/// decodes with a `VTDecompressionSession`. Samples that already carry a pixel buffer are
/// converted directly.
final class VideoFrameImageConverter: @unchecked Sendable {
  private let lock = NSLock()
  private var session: VTDecompressionSession?
  private var sessionFormat: CMFormatDescription?

  deinit { invalidateSession() }

  func image(from sampleBuffer: CMSampleBuffer) -> UIImage? {
    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      return Self.image(from: pixelBuffer)
    }
    guard let pixelBuffer = decode(sampleBuffer) else { return nil }
    return Self.image(from: pixelBuffer)
  }

  private func decode(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    lock.lock()
    defer { lock.unlock() }

    if let sessionFormat, !CMFormatDescriptionEqual(sessionFormat, otherFormatDescription: format) {
      invalidateSessionLocked()
    }
    if session == nil {
      var newSession: VTDecompressionSession?
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
      ]
      let status = VTDecompressionSessionCreate(
        allocator: nil,
        formatDescription: format,
        decoderSpecification: nil,
        imageBufferAttributes: attributes as CFDictionary,
        outputCallback: nil,
        decompressionSessionOut: &newSession)
      guard status == noErr, let newSession else { return nil }
      session = newSession
      sessionFormat = format
    }
    guard let session else { return nil }

    let output = DecodedFrame()
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
    ) { status, _, imageBuffer, _, _ in
      if status == noErr { output.pixelBuffer = imageBuffer }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    if status != noErr {
      // A broken session (e.g. after a stream restart) is rebuilt on the next frame.
      invalidateSessionLocked()
      return nil
    }
    return output.pixelBuffer
  }

  private func invalidateSession() {
    lock.lock()
    invalidateSessionLocked()
    lock.unlock()
  }

  private func invalidateSessionLocked() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    sessionFormat = nil
  }

  private static func image(from pixelBuffer: CVPixelBuffer) -> UIImage? {
    var cgImage: CGImage?
    guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage) == noErr,
      let cgImage
    else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

private final class DecodedFrame: @unchecked Sendable {
  var pixelBuffer: CVPixelBuffer?
}

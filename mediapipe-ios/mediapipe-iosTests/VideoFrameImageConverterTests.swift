/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import UIKit
import VideoToolbox
import XCTest

@testable import mediapipe_ios

/// The converter must work without the GPU, because that is the only path available while the
/// phone is locked. These tests use real CoreMedia/VideoToolbox buffers, no stubs.
final class VideoFrameImageConverterTests: XCTestCase {
  private let width = 128
  private let height = 96

  func testConvertsSampleBufferThatAlreadyHasPixels() throws {
    let sample = try makeSampleBuffer(pixelBuffer: try makePixelBuffer())
    let image = try XCTUnwrap(VideoFrameImageConverter().image(from: sample))
    XCTAssertEqual(Int(image.size.width * image.scale), width)
    XCTAssertEqual(Int(image.size.height * image.scale), height)
  }

  func testDecodesCompressedHEVCSampleBuffer() throws {
    let compressed = try encodeHEVC(try makePixelBuffer())
    XCTAssertNil(CMSampleBufferGetImageBuffer(compressed), "The fixture must be compressed")
    let converter = VideoFrameImageConverter()
    let image = try XCTUnwrap(converter.image(from: compressed), "HEVC frame was not decoded")
    XCTAssertEqual(Int(image.size.width * image.scale), width)
    XCTAssertEqual(Int(image.size.height * image.scale), height)
    // The decoder session is reused for the next frame of the same stream.
    XCTAssertNotNil(converter.image(from: compressed))
  }

  // MARK: - Fixtures

  private func makePixelBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let pixelBuffer = try XCTUnwrap(buffer, "CVPixelBufferCreate failed: \(status)")
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for x in 0..<width {
        row[x * 4] = UInt8(x * 2)  // B
        row[x * 4 + 1] = UInt8(y * 2)  // G
        row[x * 4 + 2] = 128  // R
        row[x * 4 + 3] = 255  // A
      }
    }
    return pixelBuffer
  }

  private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: pixelBuffer,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
    return try XCTUnwrap(sample, "CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
  }

  private func encodeHEVC(_ pixelBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
    var created: VTCompressionSession?
    let createStatus = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil, imageBufferAttributes: nil,
      compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
      compressionSessionOut: &created)
    let session = try XCTUnwrap(created, "HEVC encoder unavailable: \(createStatus)")
    defer { VTCompressionSessionInvalidate(session) }

    let output = EncodedFrame()
    let encodeStatus = VTCompressionSessionEncodeFrame(
      session, imageBuffer: pixelBuffer, presentationTimeStamp: .zero, duration: .invalid,
      frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
      infoFlagsOut: nil
    ) { status, _, sample in
      if status == noErr { output.sample = sample }
    }
    XCTAssertEqual(encodeStatus, noErr)
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    return try XCTUnwrap(output.sample, "HEVC encoder produced no frame")
  }
}

private final class EncodedFrame: @unchecked Sendable {
  var sample: CMSampleBuffer?
}

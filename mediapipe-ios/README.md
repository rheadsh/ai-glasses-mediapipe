# mediapipe-ios

A SwiftUI iOS app that receives first-person video from Meta Ray-Ban glasses through the Device Access Toolkit (DAT) and runs MediaPipe Vision Tasks locally on the device.

The app UI is in Spanish. Labels are shown here in English with the Spanish label in parentheses.

## What it includes

- Registration and permissions through the Meta AI app.
- Camera session and stream with `MWDATCore` and `MWDATCamera` 1.0.1.
- All 11 on-device Vision Tasks from `MediaPipeTasksVision` 0.10.35.
- Live switching between:
  - **EfficientDet Lite0**: lower latency.
  - **EfficientDet Lite2**: higher accuracy.
- A menu with the 11 Vision Tasks that MediaPipe Tasks exposes for iOS:
  Object Detection, Image Classification, Image Segmentation, Interactive Segmentation,
  Gesture Recognition, Hand Landmark Detection, Image Embedding, Face Detection,
  Face Landmark Detection, Pose Landmark Detection, and Holistic Landmark Detection.
- Official models pinned by SHA-256 for every task.
- Boxes, masks, landmarks, classification, gestures, embeddings, latency, and a frame counter drawn over the preview.
- A single active model: switching tasks releases the previous runtime before creating the next one.
- Back pressure: if MediaPipe is still busy, the new frame is dropped instead of queueing work.
- Photo capture and `MWDATMockDevice` support in Debug builds.

## Architecture

```text
Meta Ray-Ban
    │ DAT camera stream
    ▼
MWDATCamera.VideoFrame
    ├──► UIImage ──► SwiftUI preview
    └──► serial inference queue ──► MediaPipeVisionAnalyzer
                                      │ one Runtime
                                      ▼
                        boxes / masks / landmarks / text
                                      │
                                      ▼
                               SwiftUI overlay
```

`StreamSessionViewModel` coordinates the session and the observable state. `MediaPipeVisionAnalyzer` wraps the Tasks, runs everything on a serial queue, and keeps exactly one runtime. `DetectionGeometry` keeps the conversion between model coordinates and the `aspectFill` preview separate and testable.

## Requirements

- macOS with an Xcode and Swift compiler compatible with the project (validated with Xcode 27.1).
- iOS 17.2 or later (required by DAT 1.0.1).
- Ruby and Bundler, to install the CocoaPods version pinned in `Gemfile`.
- For real hardware: the Meta AI app, Developer Mode, and compatible glasses.
- For the simulator: `MWDATMockDevice`, included in Debug builds.

MediaPipe Tasks is integrated through CocoaPods and DAT through Swift Package Manager. Always open the workspace so both dependencies load.

## Setup

From this directory:

```bash
# Install the pinned CocoaPods version
bundle install

# Verify or recover every official model pinned by SHA-256
./Scripts/download_models.sh

# Generate the workspace and resolve MediaPipe
bundle exec pod install

# Always open the workspace, not the .xcodeproj
open mediapipe-ios.xcworkspace
```

The models ship in `mediapipe-ios/Models` so inference works without a network connection. The script only accepts binaries whose hashes match the pinned versions. It is a setup step: the app never downloads models at runtime.

## DAT configuration

`mediapipe-ios/Info.plist` already contains:

- the `mediapipe-ios://` callback;
- the `com.meta.ar.wearable` protocol;
- Bluetooth and external-accessory background modes;
- the `fb-viewapp` allowlist;
- Bluetooth, local network, camera, and photo library usage descriptions.

Debug and Release both use `META_APP_ID = 0`, the bundle ID `com.rheadsh.mediapipe-ios`, and the original developer's team, which works for Developer Mode only. For distribution, or to build with a different team, replace `META_APP_ID`, `CLIENT_TOKEN`, the bundle identifier, and the Team ID with the values from your project in the Wearables Developer Center and Signing & Capabilities.

## Usage

1. Enable Developer Mode for the glasses in Meta AI.
2. Open the app and tap **Connect my glasses** (`Conectar mis lentes`).
3. With the glasses active, tap **Start stream and analysis** (`Iniciar stream y análisis`).
4. Use the model picker before streaming, or the `cpu` button while streaming, to choose EfficientDet Lite0 or Lite2.
5. Use the **Vision task** picker, or the grid button while streaming, to change tasks.
6. In **Interactive segmentation**, tap the object in the preview that you want to segment.
7. Use the viewfinder button to pause or resume MediaPipe without stopping the stream.
8. Use the camera button to capture a photo and **Stop streaming** to end the session.

Switching tasks invalidates pending results, releases the previous model, and prepares a single new instance on the inference queue while the DAT stream stays up.

## Build and test

```bash
xcodebuild \
  -workspace mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild test \
  -workspace mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:mediapipe-iosTests
```

Choose an installed simulator with `xcrun simctl list devices available`. **Do not add `CODE_SIGNING_ALLOWED=NO` when running DAT tests**: the host app needs the simulator's normal signing to initialize the SDK. The unsigned build above only checks that the project compiles.

The tests are split by responsibility:

- `DetectionGeometryTests`: normalization, clipping, and preview coordinates.
- `MediaPipePipelineTests`: model catalog, real models for all 11 tasks, and their OSC data.
- `OSCEncodingTests`: packet format, chunking, frame IDs, and mappings.
- `OSCOutputIntegrationTests`: isolated persistent destination and loopback UDP receipt, including the clear message.
- `DATStreamingIntegrationTests`: streaming and photo capture with MockDeviceKit 1.0.1.

DAT uses global state, so the suite runs its tests serially, waits for states with a timeout, and uses `await MockDeviceKit.shared.disable()` to finish cleanup.

For the UI flows (registration, streaming, photo capture, selection, device availability, and OSC settings), use the same command with `-only-testing:mediapipe-iosUITests`. The app launches with `--ui-testing`, uses a unique port file per test, disables inference, and keeps the first frame in the preview with `--freeze-preview-for-ui-testing` during control automation. The native stream stays active; the streaming and inference tests do not use that flag.

## OSC output

All 11 Vision Tasks can send their results over OSC/UDP to interactive installations. Use **Configure OSC** (`Configurar OSC`) to set the IP, port, and rate, enable sending, and test the receiver. See [OSC.md](OSC.md) for routes, arguments, and receiver setup examples.

## Performance

- The stream requests low resolution (`360 × 640`) at 24 FPS to balance Bluetooth and CPU load.
- MediaPipe runs one inference at a time on a `userInitiated` queue.
- Lite0 is the default for real-time use; Lite2 can be slower, especially in the simulator.
- The UI receives only finished results, delivered through the `MainActor`.

## References

- [MediaPipe iOS setup](https://developers.google.com/edge/mediapipe/solutions/setup_ios)
- [MediaPipe Object Detector for iOS](https://developers.google.com/edge/mediapipe/solutions/vision/object_detector/ios)
- [MediaPipe Framework for iOS](https://developers.google.com/edge/mediapipe/framework/getting_started/ios)
- [Meta Wearables DAT](https://wearables.developer.meta.com/docs/develop/)
- [Meta Wearables DAT iOS](https://github.com/facebook/meta-wearables-dat-ios)

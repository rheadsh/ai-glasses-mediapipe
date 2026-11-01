# mediapipe-tests: Meta Ray-Ban, MediaPipe and OSC

## Scope and current versions

This repository contains the SwiftUI app in `mediapipe-ios/`. Preserve unrelated
working-tree changes. Use the repository's pinned dependencies rather than examples
from an older DAT release or unversioned documentation.

- Meta Wearables DAT **1.0.1**, installed through Swift Package Manager.
- `MediaPipeTasksVision` **0.10.35**, installed through CocoaPods.
- App and test deployment targets: **iOS 17.2** or newer.
- The current project has been validated with **Xcode 27.1**. Its package and Swift
  syntax require a modern Swift compiler; do not retain the old Xcode 15 requirement.
- Open **`mediapipe-ios/mediapipe-ios.xcworkspace`**, which contains the app and Pods.
  Opening only the `.xcodeproj` can produce `No such module 'MediaPipeTasksVision'`.
- Keep both shared `Package.resolved` files and `Podfile.lock` consistent when
  deliberately changing dependencies. Do not update versions as part of routine fixes.
- Use Conventional Commits if a commit is requested. Do not commit unless requested.

## Project map

Paths below are relative to `mediapipe-ios/`:

| Location | Responsibility |
|---|---|
| `mediapipe-ios/MediaPipeIOSApp.swift` | DAT configuration, app entry, debug UI-test bootstrap |
| `mediapipe-ios/ViewModels/WearablesViewModel.swift` | Registration, devices, update flows |
| `mediapipe-ios/ViewModels/DeviceSessionManager.swift` | Device selection and session lifecycle |
| `mediapipe-ios/ViewModels/StreamSessionViewModel.swift` | Camera, streaming, task selection, accepted results and OSC |
| `mediapipe-ios/Services/MediaPipeObjectDetector.swift` | Serial MediaPipe inference and task-specific OSC values |
| `mediapipe-ios/Models/MediaPipeVisionTask.swift` | The 11 supported tasks and bundled model metadata |
| `mediapipe-ios/Models/ObjectDetection.swift` | Analysis results and preview coordinate conversions |
| `mediapipe-ios/Services/OSCMessage.swift` | OSC 1.0 encoding and bounded UDP bundles |
| `mediapipe-ios/Services/OSCOutput.swift` | OSC configuration UI, rate limiting and UDP transport |
| `OSC.md` | Public OSC routes, argument order, coordinates and receiver setup |
| `Scripts/download_models.sh` | Official model downloads with pinned SHA-256 checks |

The app uses manually registered source files in `project.pbxproj`. Add new app files
to the appropriate group and Sources phase. Test directories use synchronized groups,
so new test files are discovered automatically; do not also register them manually.

## Dependency workflow

Always build through the workspace. Run `pod install` from `mediapipe-ios/` when the
Podfile changes or Pods are missing; prefer `pod install` over `pod update` for setup.
Do not edit generated Pods files. Use the installed CocoaPods/Gemfile workflow.

DAT products currently linked are `MWDATCore`, `MWDATCamera`, `MWDATDisplay` and, in
Debug/test contexts, `MWDATMockDevice` / `MWDATMockDeviceTestClient`. OSC uses Apple's
`Network.framework`; it does not need another package. Do not replace the existing
MediaPipe integration or add an OSC dependency without a concrete requirement.

## DAT 1.0.1 lifecycle

1. Call `try Wearables.configure()` once at app launch. Surface configuration failures.
   Do not access `Wearables.shared` after configuration failed.
2. Route app-open URLs to `try await Wearables.shared.handleUrl(url)`.
3. Complete Meta AI registration, then check/request the camera permission.
4. Create the device selector early enough to observe an available device.
5. Create and start a `DeviceSession`; observe state/errors and wait for `.started`.
6. Add a **Camera**, retain it, and use its child stream:

```swift
let configuration = StreamConfiguration(
  videoCodec: .raw, resolution: .low, frameRate: 24)
guard let camera = try session.addCamera(config: configuration) else {
  // The session must be started before adding the camera.
  return
}
let stream = camera.stream
// Retain camera, stream and publisher listener tokens in their owner.
// Attach listeners before starting the child stream.
stream.start()
```

`DeviceSession.addStream` was removed. Do not restore it. `Camera.stop()` detaches
the capability and stops its children; `stream.stop()` stops the preview. Keep their
lifetimes explicit, and finish session cleanup when the flow ends.

- `VideoCodec.raw` pauses when the app is backgrounded. The opt-in "Con pantalla bloqueada"
  mode uses `.hvc1`, which keeps streaming, but frames arrive compressed: decode them with
  `VideoFrameImageConverter` (CPU/VideoToolbox). Never use `makeUIImage()`, CIContext or
  Metal for frames in that mode, and do no SwiftUI preview work while the app is not active.
  Real-glasses behavior with a locked iPhone needs hardware validation.
- Registration, permission checks/requests, URL handling and update navigation are
  async/throwing. Use the exact signatures from the pinned SDK.
- `DeviceSession.start()` and `addCamera(config:)` are synchronous/throwing;
  camera/stream start and stop methods are synchronous. Do not add `await` blindly.
- Observe states using AsyncSequence or publisher `.listen {}`. Retain tokens and
  cancel observation tasks on cleanup; avoid discarding tokens immediately.
- `.paused` is temporary: do not create a replacement session while paused.
  `.stopped` is terminal: a restart needs a new session.
- Since DAT 0.9, session state/error streams finish at `.stopped`. Handle streams
  that finish without yielding `.started`; do not wait forever for a past event.
- Device state belongs to `Device`: `addDeviceStateListener` and accessors such as
  battery, charging, don, hinge and thermal state. Do not use removed
  `Wearables.deviceStateStream(for:)` APIs.
- Handle typed errors. In tests, only `WearablesError.alreadyConfigured` is an
  expected configuration error when the host app already initialized DAT.
- Use `localizedDescription` for user messages. Do not infer disconnect causes from
  a generic state; rely on explicit errors or device state.

Keep the URL scheme `mediapipe-ios://`, `fb-viewapp` query allowlist, accessory
protocol `com.meta.ar.wearable`, Bluetooth/local-network descriptions, background
modes and MWDAT app configuration intact. `META_APP_ID = 0` is a Developer Mode
setting, not production registration. Never insert real client secrets into tests.

## Capabilities available for future work

DAT 1.0.1 also ships Display, Inputs, Motion and Speech modules. A dependency being
available does not mean this app already implements the capability or every glasses
model supports it. Check the pinned changelog, API interface, permissions and hardware
before adding a feature.

- `MWDATDisplay`: only target display-capable hardware. Wait for session and Display
  readiness before sending content; use a single root `FlexBox` or `VideoPlayer`.
  Qualify Display DSL names if SwiftUI's `Text`, `Button` or `Image` conflict.
- `MWDATInputs`: device input events for supported interactions.
- `MWDATMotion`: motion/orientation data with explicit lifecycle management.
- Speech, voice invocations, standalone high-quality photo capture (`Camera.photo`)
  and camera audio streaming are marked **experimental** in the pinned 1.0 changelog.
  Check publishing restrictions before promising production support. Microphone
  features require their own permission flow.
- Do not describe camera orientation as eye tracking, infer metric depth from a
  normalized box, or promise world anchoring from the current 2D landmarks.

## MediaPipe and concurrency

The app supports object detection (EfficientDet Lite0 and Lite2), image classification,
image segmentation, interactive segmentation, gesture recognition, hand landmarks,
image embeddings, face detection, face landmarks, pose and holistic landmarks.

- Keep SDK/UI ownership on `@MainActor`; use `@Observable` and `@Bindable` as in the app.
- Run model preparation and inference on the existing serial background queue.
  Never block MainActor with inference, synchronous waiting, or a semaphore.
- Own exactly one active MediaPipe runtime. Release the old runtime before loading
  the next model. Keep back pressure: drop a new frame if analysis is busy.
- Invalidate pending callbacks when task/model/enabled state changes. Publish only
  results from the current generation and a streaming session.
- Preserve structured `VisionAnalysisResult.oscMessages` when wrapping/copying results;
  do not lose category, gesture, mask or embedding data while adding inference timing.
- Keep model files bundled and hash-pinned. Do not silently fetch models at runtime.
- `DetectionGeometry` owns aspect-fill mapping. OSC coordinates refer to the source
  camera image; preview cropping must not change their meaning.
- Current landmarks are 2D and indexed within each result. They are not persistent
  person IDs or 3D world coordinates. Segmentation confidence is not a binary area.

## OSC contract

Treat [mediapipe-ios/OSC.md](mediapipe-ios/OSC.md) as the receiver-facing contract.
Update it and protocol tests together if addresses, argument types or ordering change.

- Send only the selected task under `/mediapipe/<task>/...`.
- Remain disabled by default. Persist destination/rate, not an automatic opt-in.
- Keep int32/float32 big-endian encoding, ASCII null-terminated strings padded to
  four bytes, immediate bundles, frame IDs and the 1200-byte datagram limit.
- Chunk landmarks/embeddings/mask grids; do not send video or full-resolution masks
  through OSC. Preserve offsets, counts and group labels needed for reconstruction.
- Encode and submit packets off MainActor; bound in-flight work and transmission rate.
- Clear task state on pause, stop, task/model change or analysis disable. Attempt a
  final clear before closing/replacing the connection. Drop stale inference results.
- UDP acceptance is not proof of remote reception. Receivers need frame handling and
  an expiry timeout because packets and clears may be lost or reordered.
- Tests must use loopback/ephemeral ports, not a developer's installed receiver or
  saved destination. Keep network tests bounded and defaults isolated.
- Local-network usage descriptions must cover both glasses connectivity and OSC.

## Tests and validation

Test suites under `mediapipe-ios/mediapipe-iosTests/`:

- `DetectionGeometryTests`: normalized boxes, clipping and aspect-fill/touch mapping.
- `MediaPipePipelineTests`: model catalog, bundled resources, real sequential inference
  for all 11 tasks, task-specific OSC data and detector fixtures.
- `OSCEncodingTests`: wire bytes, padding, endian order, packet size, frame IDs and
  tracking payload mapping/validation.
- `OSCOutputIntegrationTests`: isolated defaults, loopback UDP receipt and terminal clear.
- `DATStreamingIntegrationTests`: signed host app, MockDeviceKit streaming and capture.
- `VideoFrameImageConverterTests`: pixel-buffer and real HEVC decoding without the GPU.
- `TestSupport.swift`: required fixtures and cancellable, deadline-bounded state waits.

`mediapipe-iosUITests/MediaPipeIOSUITests.swift` covers app flows using the async
`MockDeviceTestClient`: registration, pairing, streaming, photo preview, model/task
selection, device availability and OSC settings.

Testing rules:

- DAT and MockDeviceKit hold process-global state. Keep SDK/mock suites serial;
  the shared scheme marks test targets nonparallel. Use `-parallel-testing-enabled NO`.
- **Run tests with normal simulator signing.** Do not use `CODE_SIGNING_ALLOWED=NO`
  for runtime DAT tests: this environment's unsigned host fails `Wearables.configure()`
  with `.internalError`. The normally signed simulator host runs successfully.
- An unsigned generic simulator/device build is a compile check only. Never report
  it as proof of SDK initialization, real-device streaming or delivery to an OSC peer.
- Configure DAT successfully before enabling mocks. Set `MockDeviceKitConfig` explicitly
  for registration/permission expectations. Power on, unfold and don mock glasses.
- Wait for observable state/frame availability instead of fixed startup sleeps.
  Every wait must have a deadline and honor cancellation. Avoid `try?` on setup paths,
  forced unwraps, unsafe continuations and tests that continue after setup failed.
- In async cleanup, stop the stream, release the session, then
  `await MockDeviceKit.shared.disable()`; the async overload completes teardown.
  Use awaited unpair operations where needed. Cleanup must run even after assertions.
- DAT 1.0.1's `MockCameraKit.setCameraFeed(cameraFacing:)` is synchronous.
  Permission controls are exposed through `MockDeviceKit.shared.permissions`.
- UI tests use `--ui-testing`, a unique port-file path per test and the async
  `MockDeviceTestClient`. Await network commands before XCTest assertions; assertion
  autoclosures cannot await. Prefer `await fulfillment(of:timeout:)` over blocking waits.
- Keep real inference tests separate from UI control tests. Disable inference in UI
  automation while the mock supplies frames. UI control tests also pass
  `--freeze-preview-for-ui-testing` to display only the first real mock frame and
  stabilize accessibility snapshots; native streaming stays active. Streaming and
  pipeline tests must not use this flag or replace real inference with stubs.
- Fail clearly on configuration/resource/protocol errors. Do not delete useful coverage
  or convert failures to skips merely to make the suite green.

Commands from the repository root (choose an installed simulator):

```bash
xcrun simctl list devices available

# Compile-only validation; this does not run DAT.
xcodebuild -workspace mediapipe-ios/mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# Unit, real-model, OSC and mock-stream integration tests, with normal signing.
xcodebuild -workspace mediapipe-ios/mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:mediapipe-iosTests test

# UI flows, also signed and serial.
xcodebuild -workspace mediapipe-ios/mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:mediapipe-iosUITests test
```

After code changes, run the relevant suites and a build for the affected platform.
Report passed, failed and untested paths accurately. Real glasses, remote OSC reception
and device-specific experimental features require separate hardware validation.

## Authoritative references

Check the resolved **1.0.1** checkout's `CHANGELOG.md` and public `.swiftinterface`
files when resolving API ambiguities. Latest docs can describe newer APIs.

- [DAT 1.0.1 changelog](https://github.com/meta/meta-wearables-dat-ios/blob/1.0.1/CHANGELOG.md)
- [DAT developer docs](https://wearables.developer.meta.com/docs/develop/)
- [Full static reference](https://wearables.developer.meta.com/llms.txt?full=true)
- Public DAT docs MCP: `https://mcp.developer.meta.com/wearables`, using
  `search_dat_docs` if available. It needs no token, OAuth or custom auth header.
- [MediaPipe iOS setup](https://ai.google.dev/edge/mediapipe/solutions/setup_ios)
- [OSC 1.0 specification](https://opensoundcontrol.stanford.edu/spec-1_0.html)
- Local [app README](mediapipe-ios/README.md) and [OSC contract](mediapipe-ios/OSC.md).

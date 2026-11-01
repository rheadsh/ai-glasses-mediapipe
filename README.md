# Meta Ray-Ban · MediaPipe · OSC

An iOS app that processes the first-person camera stream from Meta Ray-Ban glasses with MediaPipe Vision Tasks and sends structured tracking results to interactive installations over OSC/UDP.

The repository also includes a ready-to-open TouchDesigner project for inspecting the messages, visualizing tracking data, and mapping numeric channels to visuals, lighting, or sound.

## Privacy and network scope

Camera frames are analyzed **on the iPhone**. Only numeric results (boxes, landmarks, scores, reduced masks, embeddings) leave the device, and only when you explicitly enable OSC. No video is sent. OSC over UDP has no authentication or encryption: use it on a network you trust.

```text
Meta Ray-Ban glasses
        │ Meta Wearables DAT
        ▼
iPhone: camera preview → MediaPipe inference → OSC/UDP
                                                 │ local network
                                                 ▼
TouchDesigner: receiver → frame reconstruction → tables → CHOP/TOP outputs
```

## Features

- Camera streaming and photo capture from Meta Ray-Ban glasses (Meta Wearables DAT 1.0.1).
- All 11 MediaPipe Vision Tasks running on-device with bundled models, switchable live, with overlays, inference timing, and pause/resume.
- Configurable OSC destination, UDP port, transmission rate, and test message.
- Structured OSC output for detections, landmarks, classifications, gestures, embeddings, and reduced segmentation masks.
- Optional background mode: keep analysis and OSC running with the iPhone locked ([details](#keep-running-with-the-iphone-locked)).
- Light and dark appearance support; the camera screens are always drawn on black with a dark system scheme.
- MockDeviceKit support for development and testing without physical glasses.
- A TouchDesigner receiver, reusable component, visual monitor, and synthetic demo sender.

Implementation details (serial inference, back pressure, one active model) are in [Development notes](#development-notes).

## Supported vision tasks

Only the selected task runs and sends results at a time.

| Task | Output |
|---|---|
| Object detection | Labels, confidence scores, and normalized bounding boxes; Lite0 or Lite2 |
| Image classification | Category labels and scores |
| Image segmentation | Per-pixel confidence for the first mask channel (how likely each pixel belongs to the segmented class), reduced to a 16×16 grid for OSC |
| Interactive segmentation | The point you tap in the preview, plus the sampled confidence mask around it |
| Gesture recognition | Gesture labels, scores, hand landmarks, and handedness |
| Hand landmark detection | Hand landmarks and handedness |
| Image embedding | Float embedding vector, transmitted in chunks |
| Face detection | Face bounding boxes and keypoints |
| Face landmark detection | 2D facial landmarks |
| Pose landmark detection | 2D pose landmarks |
| Holistic landmark detection | Available face, pose, and hand landmark groups, with group labels |

Landmarks use source-image coordinates. They are not metric depth, eye tracking, or world-space tracking. Group indices are local to each result rather than persistent identities.

## Requirements and pinned dependencies

| Component | Version / requirement |
|---|---|
| iOS deployment target | 17.2 or newer |
| Xcode | Validated with Xcode 27.1. The pinned DAT package and Swift syntax need a modern Swift compiler; Xcode 15 is not supported |
| Ruby / Bundler | Needed to install the pinned CocoaPods (`bundle install`) |
| Meta Wearables DAT | 1.0.1, through Swift Package Manager |
| MediaPipeTasksVision | 0.10.35, through CocoaPods |
| CocoaPods | 1.16.2, pinned in `mediapipe-ios/Gemfile` |
| TouchDesigner example | Built and validated with 2025.33230 |
| Demo sender and parser tests | Python 3; standard library only |

For physical glasses, install the Meta AI companion app, pair compatible glasses, and enable their Developer Mode. TouchDesigner is optional for the iOS app; any compatible OSC receiver can consume the documented messages.

## Repository layout

```text
.
├── README.md
├── AGENTS.md                         # Development conventions and DAT 1.0.1 guidance
├── mediapipe-ios/
│   ├── mediapipe-ios.xcworkspace      # Open this workspace in Xcode
│   ├── mediapipe-ios/                # SwiftUI app, models, services, and view models
│   ├── mediapipe-iosTests/           # Geometry, inference, OSC, and mock streaming tests
│   ├── mediapipe-iosUITests/         # App workflow tests
│   ├── Scripts/download_models.sh   # SHA-256-pinned model downloads
│   ├── Gemfile
│   ├── Podfile
│   ├── README.md                    # App architecture, setup, and testing
│   └── OSC.md                       # Full OSC address and argument contract
└── TouchDesigner/
    ├── RayBan_MediaPipe_OSC.toe      # Complete receiver project
    ├── RayBan_OSC.tox               # Reusable receiver component
    ├── demo_sender.py              # Synthetic OSC data for all 11 tasks
    ├── osc_protocol.py             # Standalone frame reconstruction and validation
    ├── td_runtime.py               # Tables, numeric controls, and visualization
    ├── build_project.py            # Rebuild the embedded TouchDesigner component
    ├── validate_project.py         # Validate reception inside TouchDesigner
    ├── test_protocol.py            # Standalone receiver tests
    └── README.md                   # Detailed TouchDesigner guide
```

## Set up the iOS app

From the repository root:

```bash
cd mediapipe-ios

# Install the pinned CocoaPods version using Ruby/Bundler.
bundle install

# Setup-time step: verify bundled models and download missing or mismatched
# files from official sources (SHA-256 checked). The app never downloads
# models at runtime.
./Scripts/download_models.sh

# Install MediaPipe and prepare the workspace without upgrading dependencies.
bundle exec pod install

open mediapipe-ios.xcworkspace
```

**Always open the `.xcworkspace`, not just the `.xcodeproj`.** The workspace includes the Pods project required to resolve `MediaPipeTasksVision`; DAT is resolved through Swift Package Manager (the first resolution can take a few minutes).

Select the `mediapipe-ios` scheme and your iPhone. Set your development team in Signing & Capabilities before building for a physical device. The project uses development settings, including `META_APP_ID = 0`. This value works only with glasses in **Developer Mode**; it is not a production registration. Distributing the app requires your own Meta project configuration and release setup.

The app already includes its callback URL scheme, external accessory protocol, URL query allowlist, and usage descriptions. Keep these settings consistent if you change the bundle identifier or registration configuration. Do not commit private credentials.

### Run with glasses

1. Enable Developer Mode for the paired glasses in Meta AI.
2. Launch the app and tap **Connect my glasses** (`Conectar mis lentes`).
3. Complete registration and grant camera access when requested.
4. With the glasses available, tap **Start stream and analysis** (`Iniciar stream y análisis`).
5. Select a Vision Task or object detection model. For interactive segmentation, tap a point in the preview.
6. Use the analysis control to pause/resume inference, the camera control to capture a photo, and **Stop streaming** to end the stream.

### Keep running with the iPhone locked

By default the app streams with DAT's `raw` codec, which DAT **pauses when the app goes to the background**. To keep analysis and OSC running while the phone is locked or another app is in front:

1. Before starting the stream, turn on **Locked screen** (`Pantalla bloqueada`), next to the OSC button. The setting is remembered and cannot change while streaming.
2. Start the stream and, if you use OSC, enable it as usual. Then lock the phone.

In this mode the app streams compressed HEVC (`VideoCodec.hvc1`), decodes it on the CPU with VideoToolbox, stops refreshing the preview while it is not on screen, and keeps running MediaPipe and sending OSC. The Bluetooth and external-accessory background modes already declared in `Info.plist` are what let iOS keep the app alive while the glasses stream.

Limits to know about:

- DAT may report `Critical error, the stream should end` (`StreamError.videoStreamingError`) when the phone locks. The app does not show that alert as long as frames keep arriving after it (locked or not); if they stop for 5 seconds it ends the stream and shows the error. Each DAT error is logged with `NSLog` (`[mediapipe-ios] DAT stream error: ...`).
- iOS may still suspend or terminate a background app (memory pressure, battery saver, thermal state). Stream interruptions are reported by DAT and clear the OSC state as usual.
- Use the same Wi-Fi network; locking the phone does not change local-network access, but some networks put sleeping devices to sleep.
- Inference runs on the CPU only (no GPU in the background), so rates can be lower than in the foreground.
- This was verified with MockDeviceKit and with real HEVC samples decoded by `VideoFrameImageConverter`. It has **not** been verified on real glasses with a locked iPhone; validate it with your hardware before relying on it in an installation.

For development without glasses, use the Debug menu to enable MockDeviceKit, pair mock glasses, power them on, unfold them, and simulate wearing them. Configure a video/image feed for streaming and photo capture.

## Connect OSC to TouchDesigner

1. Open [RayBan_MediaPipe_OSC.toe](TouchDesigner/RayBan_MediaPipe_OSC.toe). The receiver listens on UDP **9000** by default.
2. Connect the iPhone and receiver computer to the same local network.
3. In the iOS app, open **Configure OSC** (`Configurar OSC`).
4. Enter the **computer's current LAN IP address**, such as `192.168.x.x`, and the matching UDP port. On macOS, find it with `ipconfig getifaddr en0` (Wi-Fi) or in System Settings → Network.
5. Turn on **Send tracking over OSC** (`Enviar tracking por OSC`) and tap **Apply** (`Aplicar`). Entering an IP and port alone does not enable transmission.
6. Open the OSC settings again and tap **Send test** (`Enviar prueba`). It uses the destination you already applied, so apply first. The receiver should register `/mediapipe/test` with the arguments `"rayban"` and `1`.
7. Start streaming with analysis enabled. The selected task's results will update the monitor, data tables, and outputs.

Each result is a set of OSC messages in one bundle, tagged with a frame ID. For example, a hand-landmark result looks like this (simplified):

```text
/mediapipe/frame                                   42
/mediapipe/handLandmarkDetection/active            1
/mediapipe/handLandmarkDetection/counts            1 0 1        # results, detections, groups
/mediapipe/handLandmarkDetection/inferenceMs       18.4
/mediapipe/handLandmarkDetection/landmarks/0/count 21
/mediapipe/handLandmarkDetection/landmarks/0/points 0  x0 y0 x1 y1 …   # offset, then x/y pairs
/mediapipe/handLandmarkDetection/hand/0/handedness "Right" 0.97
```

Coordinates are normalized (0…1) with the origin at the top left of the camera image. See [OSC.md](mediapipe-ios/OSC.md) for every address and argument.

Allow the app's local-network access when iOS requests it. `127.0.0.1` on the iPhone refers to the phone itself, not the computer. The destination and rate persist, but **sending starts disabled on each app launch** and must be enabled explicitly.

The default maximum transmission rate is 15 results/s, configurable from 1 to 30. Actual throughput also depends on inference speed. OSC carries analysis data, not camera video.

### TouchDesigner workflow

The main network is organized into five stages:

```text
input_osc → decode_frames → tracking_data → outputs → monitor
                                              ├─ OUT_CONTROLS (CHOP)
                                              └─ OUT_PREVIEW  (TOP)
```

Each stage reads the previous stage's output (the stages are wired through DAT callbacks and operator references). Open `tracking_data` to inspect detections, landmarks, categories, gestures, handedness, embeddings, and mask rows. Use `OUT_CONTROLS` for numeric mappings and `OUT_PREVIEW` for the rendered 2D tracking view.

`OUT_CONTROLS` provides one sample per channel:

| Channel | Meaning |
|---|---|
| `active` | `1` while a complete, current frame exists; `0` after stop or timeout |
| `frame`, `results`, `detections`, `groups` | Frame ID and counts for the current result |
| `inference_ms` | Inference time on the iPhone |
| `mask_confidence` | Mean confidence of the 16×16 mask samples (not a binary area) |
| `hand_x`, `hand_y` | Landmark 8 (index fingertip) of group 0; hand tasks only |
| `pinch_distance` | 2D distance between landmarks 4 and 8; hand tasks only |
| `first_score` | Score of the first detection or category, if any |

Hand channels stay at zero for non-hand tasks. See the [TouchDesigner guide](TouchDesigner/README.md) for details.

For example, select `pinch_distance`, remap it with a Math CHOP, and use it to control particle size or another installation parameter. Use `active` to gate the response when tracking is unavailable.

The `.toe` and `.tox` embed the receiver code; external Python source files are not needed for normal operation. Use the `.tox` when importing the component into another project. Avoid opening two receivers on the same port.

### Try the receiver without glasses

With the TouchDesigner project open and listening on port 9000, run these commands from the repository root:

```bash
# Cycle through all 11 tasks using synthetic data.
python3 TouchDesigner/demo_sender.py --seconds 24

# Send a single task for experimenting with controls.
python3 TouchDesigner/demo_sender.py --task handLandmarkDetection --seconds 30
```

The demo sends to `127.0.0.1:9000` by default and does not run MediaPipe or read the glasses. Stop it and allow one second without traffic before switching to the iPhone: the receiver locks onto one source at a time and releases it after one second of silence.

### OSC details and troubleshooting

See [the OSC contract](mediapipe-ios/OSC.md) for addresses, argument types, chunk offsets, frame IDs, and coordinate conventions. The [TouchDesigner guide](TouchDesigner/README.md) describes the tables and output channels in detail.

If no messages arrive:

- Confirm that the iOS switch is on, **Apply** has been pressed, and the state is not `Desactivado` (Disabled).
- Check the applied IP/port and the local send counter. A locally completed UDP send does not confirm delivery.
- Send the test message first to separate network issues from tracking/inference issues.
- Check that iOS local-network access is allowed: Settings → Privacy & Security → Local Network → this app.
- Make sure the iPhone and the computer are on the **same subnet**. Campus, guest, and some public Wi-Fi networks enable *client isolation*, which silently blocks device-to-device UDP. Use a private router, a phone hotspot, or an Ethernet-connected receiver if the test message never arrives.
- Ensure the receiver is active and uses the matching port. If a firewall blocks reception, allow TouchDesigner or the relevant UDP traffic.
- Check that the IP is still correct: DHCP can change the computer's address between sessions.
- For continuous tracking, keep the stream and analysis active.

UDP packets may be lost or reordered. The receiver reconstructs complete frames and clears stale tracking after one second. Its monitor is a visualization of received coordinates and confidence values, not the camera feed.

## Build and test

Run the following commands from the repository root. Choose an installed simulator using `xcrun simctl list devices available`.

```bash
# Compile-only check. Does not validate runtime DAT initialization.
xcodebuild \
  -workspace mediapipe-ios/mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# Unit, model inference, OSC, and mock streaming tests.
xcodebuild \
  -workspace mediapipe-ios/mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:mediapipe-iosTests test

# UI workflow tests.
xcodebuild \
  -workspace mediapipe-ios/mediapipe-ios.xcworkspace \
  -scheme mediapipe-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:mediapipe-iosUITests test

# Standalone TouchDesigner receiver/parser tests; TouchDesigner need not be open.
python3 -m unittest discover -s TouchDesigner -p 'test_*.py' -v
```

**Keep normal simulator signing enabled for runtime DAT tests.** With Xcode 27.1 and the simulator, an unsigned host app fails DAT initialization (`Wearables.configure()` returns `.internalError`). `CODE_SIGNING_ALLOWED=NO` is appropriate only for the compile check above.

The model and pipeline tests run real inference on all 11 tasks, so they take noticeably longer than the unit tests.

The test suites cover:

- Geometry normalization, clipping, and aspect-fill coordinate mapping.
- Real inference with all 11 bundled tasks and both object detection models, through the same analyzer the app uses.
- OSC encoding, packet bounds, task payloads, isolated configuration, and loopback delivery/cleanup.
- MockDeviceKit streaming and photo capture with deterministic async teardown, including the compressed (`hvc1`) stream, the preview pausing while the app is not active, and DAT video errors.
- `VideoFrameImageConverter` decoding pixel buffers and real HEVC samples on the CPU, without the GPU.
- UI registration, model/task selection, capture, device availability, and OSC settings.
- UI controls staying visible and tappable in light and dark appearance (screenshots are attached to the test result).
- Receiver handling of incomplete frames, old packets, timeouts, resets, conflicting sources, and demo packet sizes.

DAT and MockDeviceKit tests run serially because they share SDK state. UI control tests disable inference and freeze the displayed preview after the first real mock frame using `--freeze-preview-for-ui-testing`; native streaming remains active. Streaming and model tests do not use that preview-freezing flag.

Mock and synthetic-data tests do not establish physical-glasses performance or delivery across a real installation network. Validate those paths with the intended hardware and network.

## Development notes

- Read [AGENTS.md](AGENTS.md) before changing the integration.
- Use `DeviceSession.addCamera(config:)` and retain its `Camera`; the stream is `camera.stream`. The old `addStream` API is not available in DAT 1.0.1.
- Keep model initialization and inference off the main thread, with one active runtime and bounded pending work.
- Preserve task-specific OSC payloads when copying analysis results or changing inference timing.
- Update the OSC contract, receiver, and protocol tests together when changing message formats.
- Frames in the locked-screen (`hvc1`) mode must be decoded with `VideoFrameImageConverter` (CPU/VideoToolbox), never with the GPU, and no SwiftUI preview work should run while the app is not active.
- Colors must work in both appearances: use system colors or asset colors with both variants. A white card on the black camera screens must set a light color scheme for its text.
- DAT's `videoStreamingError` is judged by whether frames keep arriving, not by its message (see [Keep running with the iPhone locked](#keep-running-with-the-iphone-locked)).
- DAT also ships Display, Inputs, Motion, and Speech capabilities. These are not all implemented by this app. Check the pinned SDK, hardware support, permissions, and experimental-feature restrictions before extending it.

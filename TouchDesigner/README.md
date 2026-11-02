# Ray-Ban / MediaPipe / OSC for TouchDesigner

Receive the iOS app's tracking data in TouchDesigner and map it to visuals, light, or
sound. No Python packages, no external files: everything lives inside one component.

The iOS app UI is in Spanish, so app labels appear here in English with the Spanish
label in parentheses.

## What to use

```text
TouchDesigner/
├── RayBan_OSC.tox                   ← drag this into YOUR project
├── RayBan_MediaPipe_OSC.toe         ← example project to explore first
├── examples/
│   ├── RayBan_Easy_CHOPs.tox        ← beginner example: CHOPs + expressions only
│   └── RayBan_Points_Instancing.tox ← one shape on every landmark
├── demo/
│   └── demo_sender.py               ← fake data over the network (optional)
└── dev/                             ← only to modify or rebuild the component
```

You only need `RayBan_OSC.tox`. Copy that single file wherever you like.

## Start in 2 minutes, no glasses needed

1. Open **RayBan_MediaPipe_OSC.toe**. The monitor opens with the receiver status.
2. Select `rayban_osc`, go to the **Receiver** page and turn on **Demo (Fake Data)**.
   Set **Demo Task** to `gestureRecognition`.
3. Open the viewer of `easy_example`: a circle follows a fake fingertip, grows with
   the pinch, and changes colour with the gesture.
4. Turn **Demo** off when you connect the iPhone.

## Add it to your project

1. Drag **RayBan_OSC.tox** into your network. It appears as one component.
2. Set **Receiver → UDP Port** (default `9000`).
3. Wire its outputs:

   | Output | Type | Contents |
   |---|---|---|
   | `controls` (first CHOP output) | CHOP | One value per channel, ready to map (table below). |
   | `points` (second CHOP output) | CHOP | Every landmark as one sample: `tx`, `ty`, `group`, `index`, `scale`. For Geometry COMP instancing. |
   | `preview` | TOP | 960×540 drawing of the received boxes, landmarks and mask. Not camera video. |

4. Optionally drag in `examples/RayBan_Easy_CHOPs.tox` and wire `controls` into its
   input, or `examples/RayBan_Points_Instancing.tox` and wire `points` into its input.

Build your logic outside the component; changes inside it are replaced when it is
updated. Use **one receiver per port**: do not run the example `.toe` and your own
project on the same port, or two copies of the `.tox`.

## Parameters

| Page | Parameter | What it does |
|---|---|---|
| Receiver | **UDP Port** | Port the iPhone sends to. |
| | **Clear After (s)** | Clears everything after this long without a complete frame. Keep it above the app's interval (1 s works from 2 sends/s). |
| | **Demo (Fake Data)** | Generates synthetic results inside TouchDesigner, no network. Ignores the iPhone while on. |
| | **Demo Task** | One task, or all of them for 2 s each. |
| | **Reset Receiver** | Forgets the current sender and data. |
| Outputs | **Track Point** | Landmark used for `point_x`/`point_y`: hand (21 points), pose (33) or face (nose, mouth, eyes). |
| | **Coordinates** | `Image` 0…1 with origin top-left; `0…1 bottom-left`; or `Centered` −1…1 with y up. |
| | **Smooth (s)** | Smoothing time for continuous channels. `0` = raw. |
| | **Hold Position On Loss** | Keeps the last position instead of jumping to 0 when tracking is lost. |
| Display | **Open Monitor On Start** | On in the example `.toe`, off in the `.tox`. |
| | **Help** | Opens the short help inside TouchDesigner. |

## Controls (`controls` output)

| Channel | Meaning |
|---|---|
| `active` | `1` while a complete, current frame exists; `0` after stop or timeout. |
| `present` | `1` while something is tracked (results, detections or groups above 0). |
| `presence` | Smoothed `present`, 0…1: use it for fades. |
| `point_x`, `point_y`, `point_found` | The **Track Point**, in the chosen **Coordinates**; `point_found` is `1` when it exists in this frame. |
| `hand_x`, `hand_y` | Index fingertip of the first hand (hand tasks). |
| `pinch_distance` | Distance between thumb and index tips, in image units. |
| `gesture_open_palm`, `gesture_closed_fist`, `gesture_pointing_up`, `gesture_thumb_up`, `gesture_thumb_down`, `gesture_victory`, `gesture_iloveyou` | `1` while that gesture is seen (`gestureRecognition`). |
| `class_<label>` | `1` while an object with that label is detected, e.g. `class_person`, `class_cup`. A channel appears the first time its label is seen. |
| `results`, `detections`, `groups` | Counts for the frame. |
| `frame`, `inference_ms` | Sender's frame number and inference time on the iPhone. |
| `mask_confidence` | Mean confidence of the 256 mask samples; not a binary area. |
| `first_score` | Score of the first detection or category. |

Smoothing applies to `presence`, positions, `pinch_distance`, `mask_confidence` and
`first_score`. Triggers (`present`, `gesture_*`, `class_*`) stay 0/1.

Coordinates refer to the camera image, not the cropped preview on the phone. Groups are
indices within one frame, not persistent people or hands. There is no depth. The camera
looks out from the wearer's face, so hand tasks mostly see the wearer's own hands.
MediaPipe's `Left`/`Right` handedness assumes a mirrored selfie image; check the labels
with your own hands before relying on them.

## Beginner example: `easy_example`

Only Select CHOPs, one Math CHOP and expressions. Each node has a comment and the
`READ_ME` DAT repeats the steps.

```text
from_rayban ─┬─ presence  ──────────────────────────→ fade (Level TOP opacity)
             ├─ finger    (point_x point_y) ────────→ dot (Circle TOP centre)
             ├─ pinch → pinch_size (Math CHOP) ─────→ dot radius
             └─ gestures  (open_palm closed_fist) ──→ dot colour
                                            dot → fade → out
```

The expressions you can copy into any parameter:

| Parameter | Expression |
|---|---|
| Circle centre X | `op('finger')['point_x'] - 0.5` |
| Circle centre Y | `0.5 - op('finger')['point_y']` |
| Circle radius | `op('pinch_size')['pinch_distance']` |
| Level opacity | `op('presence')['presence']` |
| Red when the fist closes | `1 - 0.8 * op('gestures')['gesture_closed_fist']` |

To use it in your project, replace the Circle TOP with your own visual and keep the
expressions. To change which point moves the circle, change **Outputs → Track Point**
on `rayban_osc`; nothing in the example needs to change.

## Instancing example: `points_example`

A Geometry COMP draws a sphere on every sample of the `points` output (Instance page:
Translate X = `tx`, Translate Y = `ty`, Scale = `scale`). Points are always centered
−1…1 with y up. When nothing is tracked, `points` has one sample with `scale = 0`, so
nothing is drawn. Try Demo with `faceLandmarkDetection` or `poseLandmarkDetection`.

## Connect the iPhone

1. Connect the iPhone and the computer to the same local network.
2. The monitor shows **the IP and port to type on the iPhone**.
3. In the iOS app, open **Configure OSC** (`Configurar OSC`), enter them, turn sending on,
   and tap **Apply** (`Aplicar`). Sending is off each time the app opens.
4. Send the test message: the monitor shows **PRUEBA OK**.
5. Start the stream and choose one of the 11 tasks: the monitor shows **RECIBIENDO**.

Monitor states: **ESPERANDO** (waiting), **PRUEBA OK** (test received), **RECIBIENDO**
(live data), **SIN DATOS** (timeout), **DETENIDO** (sender stopped), **DEMO**.

`127.0.0.1` on the iPhone points to the phone itself. If the firewall blocks traffic,
allow TouchDesigner or the UDP port rather than disabling the firewall. Some networks
(campus, guest Wi-Fi) block device-to-device UDP; a private router or a phone hotspot
usually works.

## Fake data over the network

The built-in **Demo** is the easiest test. To test the network path itself, run this
from the `TouchDesigner/` folder with Demo off:

```bash
python3 demo/demo_sender.py --task handLandmarkDetection --seconds 30
```

`demo_sender.py` is self-contained: copy it anywhere and run it with `python3`. Add
`--host` and `--port` to target another computer. Without `--task` it cycles through
the 11 tasks. Wait one second before connecting the iPhone, because the receiver
accepts one source at a time. Neither demo runs MediaPipe or represents real data.

## Inside the component

```text
input_osc → decode_frames → tracking_data → outputs → monitor
```

1. **input_osc**: OSC In DAT; splits bundles into messages.
2. **decode_frames**: groups chunks by frame, validates counts, discards old packets,
   clears after **Clear After** seconds, runs the demo and the parameter callbacks.
3. **tracking_data**: `summary`, `detections`, `landmarks`, `categories`, `gestures`,
   `hands`, `embedding` and `mask` tables. Read them with a Select DAT, e.g.
   `rayban_osc/tracking_data/landmarks`.
4. **outputs**: the `controls`, `points` and `preview` operators behind the outputs.
5. **monitor**: status, IP, port and the 2D drawing.

## Robustness and limits

- Incomplete frames never replace the last complete one; chunks from different frames
  are never mixed. Hand and gesture frames wait for their handedness.
- Controls follow every complete frame; tables and monitor text refresh up to 10 times
  per second.
- Frame IDs are local to a sender session: after the app restarts, leave one second
  without traffic so the receiver accepts the new sequence, or press **Reset Receiver**.
- OSC over UDP does not guarantee delivery or order. This receiver handles one sender
  and synchronizes by IDs and counts; it adds no reliability to the transport.
- Masks arrive as a 16×16 grid from the first channel.

See [the app's OSC contract](../mediapipe-ios/OSC.md) for every address and argument.

## For developers (`dev/`)

| File | Role |
|---|---|
| `osc_protocol.py` | Receiver, frame reconstruction, named points, controls and smoothing; no TouchDesigner needed. |
| `td_runtime.py` | Tables, outputs, demo, monitor and drawing inside TouchDesigner. |
| `build_project.py` | Rebuilds `rayban_osc` and the two examples; saves the `.toe`, `.tox` and `examples/*.tox`. |
| `validate_project.py` | Checks reception of `demo_sender.py` inside TouchDesigner. |
| `test_protocol.py` | Receiver and output tests without TouchDesigner. |

The `.toe` and `.tox` embed copies of `osc_protocol.py`, `td_runtime.py` and
`demo/demo_sender.py`. After changing them, open `RayBan_MediaPipe_OSC.toe` and run in
the Textport:

```python
exec(open(project.folder + '/dev/build_project.py').read())
```

It rebuilds only `/project1/rayban_osc`, `/project1/easy_example` and
`/project1/points_example`. Paths come from the open project, so the repository can
live anywhere.

Validate the receiver without TouchDesigner, from this folder:

```bash
python3 -m unittest discover -s dev -p 'test_*.py' -v
```

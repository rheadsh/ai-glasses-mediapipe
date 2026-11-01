# Ray-Ban / MediaPipe / OSC Lab

Open **RayBan_MediaPipe_OSC.toe** in TouchDesigner 2025.33230 or a compatible version.
The project keeps all of its code in DATs, so receiving OSC needs no Python packages
and no paths to the source files. The `.tox` lets you reuse the component in another
project; do not run both receivers on the same port.

The iOS app UI is in Spanish, so app labels appear here in English with the Spanish
label in parentheses.

## Workflow

The main network `/project1/rayban_osc` is laid out from left to right:

```text
input_osc → decode_frames → tracking_data → outputs → monitor
                                              ├─ OUT_CONTROLS (CHOP)
                                              └─ OUT_PREVIEW  (TOP)
```

The arrows show the flow through callbacks and operator references. The Python
details live inside each stage; the top level keeps only the components and outputs.

1. **input_osc**: OSC In DAT, raw messages, and a callback. It splits bundles into
   messages and keeps string labels, types, and offsets.
2. **decode_frames**: groups chunks by frame, validates the counts, discards old
   packets, and clears the state after 1 second without fresh tracking.
3. **tracking_data**: the `summary`, `detections`, `landmarks`, `categories`,
   `gestures`, `hands`, `embedding`, and `mask` tables. Open a table's viewer to inspect it.
4. **outputs**: generates numeric controls and draws the received boxes, landmarks,
   and segmentation confidence. The drawing is not camera video.
5. **monitor**: open its viewer to see the receiver status and the visualization.
   It opens automatically when you load the project.

Select `rayban_osc` and change **OSC Receiver → UDP Port** if you need another port.
The initial value is **9000**. The number shown in the monitor follows that parameter.

## Connect the iPhone

1. Connect the iPhone and the Mac to the same local network.
2. In the iOS app, open **Configure OSC** (`Configurar OSC`).
3. Enter the **Mac's local IP**, port `9000`, turn sending on, and tap **Apply** (`Aplicar`).
4. Open the settings again and send the test message. `summary` should show
   `TEST OK` and its `tests` counter should increase.
5. Start the stream and select one of the 11 tasks. The monitor shows the task name
   and the tables and CHOP update.

`127.0.0.1` on the iPhone points to the phone, not the Mac. You do not need to turn
off the firewall: if it blocks the traffic, allow TouchDesigner or the UDP port.
Some networks (campus, guest Wi-Fi) block device-to-device UDP; if the test message
never arrives, try a private router or a phone hotspot.
See [the app's OSC contract](../mediapipe-ios/OSC.md) for the exact arguments.

## Ready-to-map controls

`OUT_CONTROLS` exposes one sample per channel:

| Channel | Meaning |
|---|---|
| `active` | `1` while a complete, current frame exists; `0` after stop or timeout. |
| `frame` | Result identifier from the sender. |
| `results`, `detections`, `groups` | Counts for the frame. |
| `inference_ms` | Inference time on the iPhone. |
| `mask_confidence` | Mean confidence of the 256 mask samples; not a binary area. |
| `hand_x`, `hand_y` | Landmark 8 of group 0, useful as the index fingertip in hand tasks. |
| `pinch_distance` | 2D distance between landmarks 4 and 8, useful for pinch in hand tasks. |
| `first_score` | Score of the first detection or category, if present. |

The hand channels are specific to hand and gesture tasks. With other models they stay
at zero, because the same indices do not represent those fingers. Coordinates use the
top-left origin of the camera image, not the cropped preview on the phone. Groups are
indices within the frame, not persistent identities. No depth is computed.

Example: connect `OUT_CONTROLS` to a Select CHOP, select `pinch_distance`, use a
Math CHOP to remap the range to 0…1, and export that channel to particle size,
light intensity, or an audio parameter. Use `active` to turn the response off when
there is no tracking. Tune thresholds with your own readings.

## Demo without glasses

From this folder, with the project open and listening on port 9000:

```bash
# Cycle through the 11 tasks, 2 seconds per task; all data is synthetic.
python3 demo_sender.py --seconds 24

# Hold a single task to experiment with the controls.
python3 demo_sender.py --task handLandmarkDetection --seconds 30
```

The sender uses only the Python standard library, localhost, and the same OSC format
and chunking that the receiver expects. When it finishes it sends `active=0`. Stop the
demo and wait one second before connecting the iPhone: the receiver accepts one source
at a time. The demo does not run MediaPipe and does not represent real measurements
from the glasses.

## Robustness and limits

- Hand and gesture frames are published only after their handedness has arrived.
- Incomplete frames never replace the last complete frame. Chunks with different
  identifiers are never mixed.
- After one second without complete results, the tables and active controls are cleared.
- Frame IDs are local to a session: after the sender restarts, leave at least one
  second without traffic so the receiver accepts the new sequence.
- OSC over UDP does not guarantee delivery or order. This example works with one
  sender and synchronizes by IDs and counts; it adds no reliability to the transport.
- Masks are reconstructed as a 16×16 grid from the first channel.
- The viewer renders 2D geometry and confidence, not the video feed or a 3D scene.

## Sources and tests

`osc_protocol.py` holds the parser that is independent of TouchDesigner; `td_runtime.py`
holds the tables, CHOPs, and drawing. Both are embedded in the project when it is built.
`build_project.py` rebuilds only the `rayban_osc` component inside `/project1` and
saves the `.toe` and `.tox` in this folder. Change its `OUT` variable if you move
the repository. Run it from the Textport with `exec(open('/path/build_project.py').read())`.

The `.toe` and `.tox` embed copies of `osc_protocol.py` and `td_runtime.py`. After changing either file, rebuild the component with `build_project.py` so the project uses the new code.

To validate the parser without opening TouchDesigner:

```bash
python3 -m unittest discover -s . -p 'test_*.py' -v
```

The tests cover the 11 tasks, hand frames that wait for handedness, incomplete chunks, old packets, timeout, clearing,
sequence restart, conflicting sources, and the size of the demo packets.

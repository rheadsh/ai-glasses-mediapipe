"""Developer tool. In ../RayBan_MediaPipe_OSC.toe, run demo/demo_sender.py through all 11 tasks, then:
    exec(open(project.folder + '/dev/validate_project.py').read())
"""
import json
from pathlib import Path
folder = Path(project.folder)
component = op('/project1/rayban_osc')
runtime = component.op('decode_frames/runtime').module
state = runtime.receiver()
examples = [op('/project1/easy_example'), op('/project1/points_example')]
errors = [(node.path, node.errors()) for comp in [component] + examples for node in comp.findChildren() if node.errors()]
channels = [channel.name for channel in component.op('OUT_CONTROLS').chans()]
outputs = [getattr(c, 'outOP', None) and c.outOP.name for c in component.outputConnectors]
report = dict(touchdesigner=str(app.version), port=int(component.par.Port),
              tasks_seen=sorted(state.seen_tasks), task_count=len(state.seen_tasks),
              received_messages=state.messages, invalid_messages=state.invalid,
              operator_errors=errors, preview_size=[component.op('OUT_PREVIEW').width, component.op('OUT_PREVIEW').height],
              control_channels=channels, outputs=outputs,
              point_channels=[channel.name for channel in component.op('OUT_POINTS').chans()],
              input='Synthetic OSC demo over localhost; not physical glasses')
(folder/'dev'/'validation.json').write_text(json.dumps(report, indent=2))
assert len(state.seen_tasks) == 11, report
assert state.invalid == 0 and not errors, report
assert {'presence', 'point_x', 'gesture_open_palm', 'class_demo_cup'} <= set(channels), report
assert component.op('monitor/tracking').par.top.eval() == component.op('OUT_PREVIEW'), 'Missing monitor texture'
# Save a clean listening state, not stale demo data.
runtime.reset()
component.op('input_osc/osc_in').par.clear.pulse()
component.par.Openmonitor = False
component.save(str(folder/'RayBan_OSC.tox'))
component.par.Openmonitor = True
project.save(str(folder/'RayBan_MediaPipe_OSC.toe'))
print('VALIDATED: 11 tasks, zero invalid messages, zero operator errors; saved clean listening state')

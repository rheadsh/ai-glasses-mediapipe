"""Developer tool. In ../RayBan_MediaPipe_OSC.toe, reset the receiver, run demo/demo_sender.py through all 11 tasks, then:
    exec(open(project.folder + '/dev/validate_project.py').read())
"""
import json
import hashlib
import time
from pathlib import Path
folder = Path(project.folder)
component = op('/project1/rayban_osc')
runtime = component.op('decode_frames/runtime').module
state = runtime.receiver()
examples = [op('/project1/easy_example'), op('/project1/points_example')]
assert all(examples), 'Missing examples: rebuild the project first'
for target in (component.op('OUT_CONTROLS'), component.op('OUT_POINTS'), component.op('OUT_PREVIEW'),
               examples[0].op('out'), examples[1].op('out')):
    target.cook(force=True)
errors = [(node.path, node.errors()) for comp in [component] + examples
          for node in [comp] + list(comp.findChildren()) if node.errors()]
channels = [channel.name for channel in component.op('OUT_CONTROLS').chans()]
outputs = [getattr(c, 'outOP', None) and c.outOP.name for c in component.outputConnectors]
evidence = runtime._network_evidence
validated_at = time.time()
# A full synthetic cycle takes 22 seconds; reject historical session-only coverage.
max_evidence_age = 120
embedded_sources = {
    'dev/osc_protocol.py': component.op('decode_frames/protocol').text,
    'dev/td_runtime.py': component.op('decode_frames/runtime').text,
    'demo/demo_sender.py': component.op('decode_frames/demo').text,
}
source_hashes = {name: hashlib.sha256(text.encode('utf-8')).hexdigest()
                 for name, text in embedded_sources.items()}
sources_match = {name: text == (folder / name).read_text(encoding='utf-8')
                 for name, text in embedded_sources.items()}
report = dict(touchdesigner=str(app.version), port=int(component.par.Port),
              embedded_source_sha256=source_hashes, embedded_sources_match=sources_match,
              session_id=runtime._session_id, session_started_unix=runtime._session_started,
              validated_at_unix=validated_at, max_evidence_age_seconds=max_evidence_age,
              network_tasks_seen=sorted(evidence), network_task_results=evidence,
              builtin_demo_enabled=bool(component.par.Demo.eval()),
              tasks_seen=sorted(state.seen_tasks), task_count=len(state.seen_tasks),
              received_messages=state.messages, invalid_messages=state.invalid,
              operator_errors=errors, preview_size=[component.op('OUT_PREVIEW').width, component.op('OUT_PREVIEW').height],
              control_channels=channels, outputs=outputs,
              point_channels=[channel.name for channel in component.op('OUT_POINTS').chans()],
              input='Network OSC; origins and decoded values recorded per task. Sender/hardware identity is not authenticated.')
(folder/'dev'/'validation.json').write_text(json.dumps(report, indent=2))
assert not component.par.Demo.eval(), 'Disable built-in Demo; validation requires network OSC'
assert all(sources_match.values()), 'Embedded Python differs from source: rebuild the project first'
assert set(evidence) == set(runtime.protocol().TASKS), report
assert all(item['received_at'] >= runtime._session_started
           and 0 <= validated_at - item['received_at'] <= max_evidence_age
           and item['source'] != 'demo'
           for item in evidence.values()), report
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
print('VALIDATED: 11 network tasks in recorded receiver session, zero invalid messages, zero operator errors; saved clean listening state')

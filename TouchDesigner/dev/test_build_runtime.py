"""Pure Python checks for generation policy, runtime channel reuse and demo bounds."""
import ast
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'demo'))
from demo_sender import packets, sample, TASKS


def load_runtime():
    spec = importlib.util.spec_from_file_location('runtime_under_test', HERE / 'td_runtime.py')
    module = importlib.util.module_from_spec(spec)
    # These tests exercise no rendering and need neither numpy nor TouchDesigner.
    with patch.dict(sys.modules, {'numpy': SimpleNamespace()}):
        spec.loader.exec_module(module)
    return module


class BuildPolicyTests(unittest.TestCase):
    def setUp(self):
        tree = ast.parse((HERE / 'build_project.py').read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'setpar')
        self.namespace = {'WARNINGS': []}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<setpar>', 'exec'), self.namespace)

    def test_required_parameter_failure_is_fatal(self):
        target = SimpleNamespace(path='/example', par=SimpleNamespace())
        with self.assertRaisesRegex(RuntimeError, 'Required parameter /example.instancing'):
            self.namespace['setpar'](target, 'instancing', True)
        self.assertEqual(self.namespace['WARNINGS'], [])

    def test_only_explicit_cosmetic_failure_is_optional(self):
        target = SimpleNamespace(path='/example', par=SimpleNamespace())
        self.namespace['setpar'](target, 'bgalpha', 1, optional=True)
        self.assertEqual(len(self.namespace['WARNINGS']), 1)


class PacketBoundsTests(unittest.TestCase):
    def test_oversized_message_is_dropped_without_empty_bundle(self):
        self.assertEqual(list(packets(1, [('/oversized', ['x' * 1400])])), [])
        valid = ('/mediapipe/objectDetection/active', [1])
        expected = list(packets(1, [valid, valid]))
        self.assertEqual(list(packets(1, [valid, ('/oversized', ['x' * 1400]), valid])), expected)

    def test_every_demo_task_fits_datagram_limit(self):
        for task in TASKS:
            result = list(packets(1, sample(task, 1)))
            self.assertTrue(result, task)
            self.assertTrue(all(len(packet) <= 1200 for packet in result), task)


class FakeChannels:
    def __init__(self):
        self.channels = {}
        self.clears = 0
        self.numSamples = 0

    def clear(self):
        self.clears += 1
        self.channels.clear()

    def chans(self):
        return [SimpleNamespace(name=name) for name in self.channels]

    def appendChan(self, name):
        self.channels[name] = [0]
        return self.channels[name]

    def __getitem__(self, name):
        return self.channels[name]


class RuntimeTests(unittest.TestCase):
    def test_channel_objects_are_reused_until_schema_changes(self):
        runtime = load_runtime()
        values = {'presence': 1.0}
        runtime.receiver = lambda: SimpleNamespace(current=None)
        runtime._filter = SimpleNamespace(apply=lambda value, *args: value)
        runtime.protocol = lambda: SimpleNamespace(controls=lambda *args: dict(values))
        parameter = SimpleNamespace(eval=lambda: 'image')
        runtime.component = lambda: SimpleNamespace(par=SimpleNamespace(
            Trackpoint=parameter, Coordinates=parameter, Smooth=0.0,
            Holdonloss=SimpleNamespace(eval=lambda: False)))
        output = FakeChannels()
        runtime.channels(output)
        original = output['presence']
        values['presence'] = 0.5
        runtime.channels(output)
        self.assertIs(output['presence'], original)
        self.assertEqual(original[0], 0.5)
        self.assertEqual(output.clears, 1)
        values['new_label'] = 1.0
        runtime.channels(output)
        self.assertEqual(output.clears, 2)
        self.assertEqual(output['new_label'][0], 1.0)

    def test_reset_starts_a_new_evidence_session(self):
        runtime = load_runtime()
        previous = runtime._session_id
        runtime._network_evidence['objectDetection'] = {'source': 'old'}
        runtime.receiver = lambda: None
        runtime.refresh = lambda force=False: None
        runtime.reset()
        self.assertNotEqual(runtime._session_id, previous)
        self.assertEqual(runtime._network_evidence, {})

    def test_test_and_control_messages_never_refresh_network_evidence(self):
        from osc_protocol import ReceiverState
        runtime = load_runtime()
        now = [0.0]
        state = ReceiverState(clock=lambda: now[0])
        runtime.receiver = lambda: state
        runtime.component = lambda: SimpleNamespace(par=SimpleNamespace(
            Demo=SimpleNamespace(eval=lambda: False)))
        with patch.object(runtime.time, 'time', side_effect=lambda: 100 + now[0]):
            runtime.receive('/mediapipe/frame', [1], 'phone')
            for address, args in sample('objectDetection', 1):
                runtime.receive(address, args, 'phone')
            evidence = runtime._network_evidence['objectDetection']
            self.assertEqual(evidence['received_at'], 100)
            now[0] = .7
            runtime.receive('/mediapipe/test', ['rayban', 1], 'phone')
            runtime.receive('/mediapipe/objectDetection/active', [1], 'phone')
            runtime.receive('/mediapipe/frame', [1], 'phone')
            for address, args in sample('objectDetection', 1):
                runtime.receive(address, args, 'phone')
            self.assertIs(runtime._network_evidence['objectDetection'], evidence)
            now[0] = 1.1
            runtime.receive('/mediapipe/test', ['rayban', 1], 'phone')
            self.assertIsNone(state.current)
            self.assertIs(runtime._network_evidence['objectDetection'], evidence)
            runtime.receive('/mediapipe/frame', [2], 'phone')
            for address, args in sample('objectDetection', 2):
                runtime.receive(address, args, 'phone')
            updated = runtime._network_evidence['objectDetection']
            self.assertIsNot(updated, evidence)
            self.assertEqual(updated['received_at'], 101.1)
            self.assertEqual(updated['result']['frame'], 2)

    def test_network_evidence_is_copied_and_builtin_demo_is_ignored(self):
        runtime = load_runtime()
        state = SimpleNamespace(version=0, current=None, source=None)
        def receive(address, args, source):
            state.version += 1
            state.source = source
            state.current = {'task': 'objectDetection', 'detections': {0: ['cup']}}
        state.receive = receive
        runtime.receiver = lambda: state
        demo = [False]
        runtime.component = lambda: SimpleNamespace(par=SimpleNamespace(Demo=SimpleNamespace(eval=lambda: demo[0])))
        runtime.receive('/test', [], '127.0.0.1')
        state.current['detections'][0][0] = 'changed'
        self.assertEqual(runtime._network_evidence['objectDetection']['result']['detections'][0][0], 'cup')
        demo[0] = True
        runtime.receive('/test', [], 'other')
        self.assertEqual(state.version, 1)


if __name__ == '__main__':
    unittest.main()

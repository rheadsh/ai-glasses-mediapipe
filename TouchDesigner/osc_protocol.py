"""Receiver for the iOS OSC contract. Pure Python; also embedded in the .toe.
One active source, bounded frames, no mixing of partial/reordered UDP results.
"""
import math
import time

TASKS = ('objectDetection', 'imageClassification', 'imageSegmentation',
         'interactiveSegmentation', 'gestureRecognition', 'handLandmarkDetection',
         'imageEmbedding', 'faceDetection', 'faceLandmarkDetection',
         'poseLandmarkDetection', 'holisticLandmarkDetection')

class ReceiverState:
    def __init__(self, timeout=1.0, clock=time.monotonic):
        self.clock, self.timeout = clock, timeout
        self.source = None
        self.context = None
        self.last_frame = -1
        self.last_seen = -math.inf
        self.frames = {}
        self.current = None
        self.version = 0
        self.messages = 0
        self.invalid = 0
        self.tests = 0
        self.seen_tasks = set()
        self.last_result = -math.inf
        self.status = 'WAITING / Esperando OSC'

    def clear(self, status):
        self.current = None
        self.frames.clear()
        self.status = status
        self.version += 1

    def tick(self):
        if self.current is not None and self.clock() - self.last_result > self.timeout:
            self.clear('TIMEOUT / Tracking sin actualizar durante 1 s')
        if self.source is not None and self.clock() - self.last_seen > self.timeout:
            self.clear('TIMEOUT / Sin datos durante 1 s')
            self.source = self.context = None
            self.last_frame = -1

    def receive(self, address, args, source='local'):
        self.tick()
        if not address.startswith('/mediapipe/'):
            return
        if self.source is not None and source != self.source:
            return  # Never interleave two phones. The source is released by timeout.
        self.source = source
        self.last_seen = self.clock()
        self.messages += 1
        if address == '/mediapipe/test':
            self.tests += 1
            self.status = 'TEST OK / Mensaje de prueba recibido'
            self.version += 1
            return
        try:
            if address == '/mediapipe/frame':
                frame = int(args[0])
                if frame < self.last_frame:
                    self.context = None
                    return
                if frame > self.last_frame:
                    self.frames.clear()
                    self.last_frame = frame
                self.context = frame
                return
            parts = address.split('/')[2:]
            if len(parts) < 2 or parts[0] not in TASKS or self.context is None:
                return
            task, path = parts[0], parts[1:]
            if path == ['active'] and int(args[0]) == 0:
                if self.current is None or self.current['task'] == task:
                    self.clear('STOPPED / Tracking detenido')
                return
            frame = self.frames.setdefault(task, dict(
                task=task, frame=self.context, counts=None, inference=None,
                detections={}, groups={}, categories={}, gestures={}, hands={},
                embedding_size=None, embedding={}, mask_size=None, mask={},
                coverage=None, selection=None))
            if path == ['counts']:
                counts = tuple(int(x) for x in args[:3])
                if len(counts) != 3 or any(x < 0 or x > 2000 for x in counts):
                    raise ValueError('counts')
                frame['counts'] = counts
            elif path == ['inferenceMs']:
                frame['inference'] = self.finite(args[0])
            elif len(path) == 2 and path[0] == 'detection':
                frame['detections'][int(path[1])] = [str(args[0])] + [self.finite(x) for x in args[1:6]]
                if len(frame['detections'][int(path[1])]) != 6: raise ValueError('box')
            elif len(path) == 3 and path[0] == 'landmarks':
                group = frame['groups'].setdefault(int(path[1]), dict(count=None, points={}, label=''))
                if path[2] == 'count':
                    group['count'] = int(args[0])
                    if not 0 <= group['count'] <= 2000: raise ValueError('points')
                elif path[2] == 'label': group['label'] = str(args[0])
                elif path[2] == 'points':
                    offset = int(args[0])
                    values = [self.finite(x) for x in args[1:]]
                    if offset < 0 or offset > 2000 or len(values) % 2: raise ValueError('chunk')
                    group['points'].update({offset+i//2: (values[i], values[i+1]) for i in range(0, len(values), 2)})
            elif len(path) == 2 and path[0] in ('category', 'gesture'):
                frame['categories' if path[0] == 'category' else 'gestures'][int(path[1])] = (str(args[0]), self.finite(args[1]))
            elif len(path) == 3 and path[0] == 'hand' and path[2] == 'handedness':
                frame['hands'][int(path[1])] = (str(args[0]), self.finite(args[1]))
            elif path == ['embedding', 'dimensions']:
                frame['embedding_size'] = int(args[0])
                if not 0 <= frame['embedding_size'] <= 8192: raise ValueError('embedding')
            elif path == ['embedding', 'values']:
                offset = int(args[0])
                if not 0 <= offset <= 8192: raise ValueError('offset')
                frame['embedding'].update({offset+i: self.finite(v) for i, v in enumerate(args[1:])})
            elif path == ['mask', 'size']:
                frame['mask_size'] = tuple(int(x) for x in args[:2])
                if frame['mask_size'] not in ((0, 0), (16, 16)): raise ValueError('mask')
            elif path == ['mask', 'row']:
                row = int(args[0])
                if not 0 <= row < 16 or len(args) != 17: raise ValueError('row')
                frame['mask'][row] = [self.finite(x) for x in args[1:]]
            elif path == ['mask', 'coverage']: frame['coverage'] = self.finite(args[0])
            elif path == ['selection']: frame['selection'] = tuple(self.finite(x) for x in args[:2])
            if self.complete(frame):
                self.current = frame
                self.last_result = self.clock()
                self.seen_tasks.add(task)
                self.status = 'LIVE / ' + task
                self.version += 1
        except (ValueError, TypeError, IndexError, OverflowError):
            self.invalid += 1

    @staticmethod
    def finite(value):
        value = float(value)
        if not math.isfinite(value): raise ValueError('non-finite')
        return value

    @staticmethod
    def complete(frame):
        if frame['counts'] is None or frame['inference'] is None: return False
        results, detections, groups = frame['counts']
        if any(i not in frame['detections'] for i in range(detections)): return False
        for i in range(groups):
            group = frame['groups'].get(i)
            if group is None or group['count'] is None: return False
            if any(j not in group['points'] for j in range(group['count'])): return False
            if frame['task'] == 'holisticLandmarkDetection' and not group['label']: return False
        task = frame['task']
        # Handedness is sent after the landmarks: do not publish a hand frame without it.
        if task in ('handLandmarkDetection', 'gestureRecognition') and any(i not in frame['hands'] for i in range(groups)): return False
        if task == 'imageClassification' and any(i not in frame['categories'] for i in range(results)): return False
        if task == 'gestureRecognition' and any(i not in frame['gestures'] for i in range(results)): return False
        if task == 'imageEmbedding':
            if frame['embedding_size'] is None: return False
            if any(i not in frame['embedding'] for i in range(frame['embedding_size'])): return False
        if task in ('imageSegmentation', 'interactiveSegmentation'):
            if frame['mask_size'] is None: return False
            if frame['mask_size'] != (0, 0):
                if any(i not in frame['mask'] for i in range(16)) or frame['coverage'] is None: return False
            if task == 'interactiveSegmentation' and frame['selection'] is None: return False
        return True

"""Receiver for the iOS OSC contract. Pure Python; also embedded in the .toe.
One active source, bounded frames, no mixing of partial/reordered UDP results.
"""
import copy
import math
import re
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
        self.published = set()
        self.retired_frame = -1
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
        self.retired_frame = self.last_frame
        self.frames.clear()
        self.status = status
        self.version += 1

    def tick(self):
        if self.current is not None and self.clock() - self.last_result > self.timeout:
            self.clear('TIMEOUT / Tracking sin actualizar durante {:g} s'.format(self.timeout))
        if self.source is not None and self.clock() - self.last_seen > self.timeout:
            self.clear('TIMEOUT / Sin datos durante {:g} s'.format(self.timeout))
            self.source = self.context = None
            self.last_frame = -1
            self.retired_frame = -1
            self.published.clear()

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
                self.context = None
                if len(args) != 1: raise ValueError('frame arity')
                frame = args[0]
                if type(frame) is not int: raise ValueError('frame type')
                if not 1 <= frame <= 2147483647: raise ValueError('frame')
                if frame < self.last_frame:
                    self.context = None
                    return
                if frame > self.last_frame:
                    self.frames.clear()
                    self.published.clear()
                    self.last_frame = frame
                self.context = frame
                return
            parts = address.split('/')[2:]
            if len(parts) < 2 or parts[0] not in TASKS or self.context is None:
                return
            task, path = parts[0], parts[1:]
            if path == ['active']:
                if len(args) != 1 or args[0] not in (0, 1): raise ValueError('active')
                if args[0] == 0:
                    if self.current is None or self.current['task'] == task:
                        self.clear('STOPPED / Tracking detenido')
                return
            if self.context <= self.retired_frame:
                return
            frame = dict(self.frames.get(task, dict(
                task=task, frame=self.context, counts=None, inference=None,
                detections={}, groups={}, categories={}, gestures={}, hands={},
                embedding_size=None, embedding={}, mask_size=None, mask={},
                coverage=None, selection=None)))
            # Only branches written by this message are copied. The stored assembly
            # remains untouched if parsing, validation or its point budget fails.
            branch = {'detection': 'detections', 'category': 'categories',
                      'gesture': 'gestures', 'hand': 'hands', 'landmarks': 'groups',
                      'embedding': 'embedding', 'mask': 'mask'}.get(path[0])
            if branch is not None: frame[branch] = dict(frame[branch])
            arities = {('counts',): 3, ('inferenceMs',): 1,
                       ('embedding', 'dimensions'): 1, ('mask', 'size'): 2,
                       ('mask', 'coverage'): 1, ('selection',): 2}
            if tuple(path) in arities and len(args) != arities[tuple(path)]:
                raise ValueError('arity')
            if path == ['counts']:
                counts = tuple(int(x) for x in args[:3])
                if len(counts) != 3 or any(x < 0 or x > 2000 for x in counts):
                    raise ValueError('counts')
                frame['counts'] = counts
            elif path == ['inferenceMs']:
                frame['inference'] = self.finite(args[0])
            elif len(path) == 2 and path[0] == 'detection':
                index = self.index(path[1])
                if len(args) != 6: raise ValueError('box')
                frame['detections'][index] = [self.label(args[0])] + [self.finite(x) for x in args[1:]]
            elif len(path) == 3 and path[0] == 'landmarks':
                index = self.index(path[1])
                group = dict(frame['groups'].get(index, dict(count=None, points={}, label='')))
                frame['groups'][index] = group
                if path[2] in ('count', 'label') and len(args) != 1: raise ValueError('arity')
                if path[2] == 'count':
                    group['count'] = int(args[0])
                    if not 0 <= group['count'] <= 2000: raise ValueError('points')
                elif path[2] == 'label': group['label'] = self.label(args[0])
                elif path[2] == 'points':
                    offset = int(args[0])
                    values = [self.finite(x) for x in args[1:]]
                    if offset < 0 or offset + len(values)//2 > 2000 or len(values) % 2: raise ValueError('chunk')
                    group['points'] = dict(group['points'])
                    group['points'].update({offset+i//2: (values[i], values[i+1]) for i in range(0, len(values), 2)})
                else: return
            elif len(path) == 2 and path[0] in ('category', 'gesture'):
                if len(args) != 2: raise ValueError('arity')
                frame['categories' if path[0] == 'category' else 'gestures'][self.index(path[1])] = (self.label(args[0]), self.finite(args[1]))
            elif len(path) == 3 and path[0] == 'hand' and path[2] == 'handedness':
                if len(args) != 2: raise ValueError('arity')
                frame['hands'][self.index(path[1])] = (self.label(args[0]), self.finite(args[1]))
            elif path == ['embedding', 'dimensions']:
                frame['embedding_size'] = int(args[0])
                if not 0 <= frame['embedding_size'] <= 8192: raise ValueError('embedding')
            elif path == ['embedding', 'values']:
                offset = int(args[0])
                if not 0 <= offset <= offset + len(args)-1 <= 8192: raise ValueError('offset')
                frame['embedding'].update({offset+i: self.finite(v) for i, v in enumerate(args[1:])})
            elif path == ['mask', 'size']:
                frame['mask_size'] = tuple(int(x) for x in args[:2])
                if frame['mask_size'] not in ((0, 0), (16, 16)): raise ValueError('mask')
            elif path == ['mask', 'row']:
                row = int(args[0])
                if not 0 <= row < 16 or len(args) != 17: raise ValueError('row')
                frame['mask'][row] = [self.finite(x) for x in args[1:]]
            elif path == ['mask', 'coverage']: frame['coverage'] = self.finite(args[0])
            elif path == ['selection']:
                if len(args) != 2: raise ValueError('selection')
                frame['selection'] = tuple(self.finite(x) for x in args)
            else:
                return
            self.trim(frame, path)
            if sum(len(g['points']) for g in frame['groups'].values()) > 8192:
                raise ValueError('point budget')
            if task in self.published: return
            self.frames[task] = frame
            if self.complete(frame):
                self.current = copy.deepcopy(frame)
                self.published.add(task)
                self.last_result = self.clock()
                self.seen_tasks.add(task)
                self.status = 'LIVE / ' + task
                self.version += 1
        except (ValueError, TypeError, IndexError, OverflowError):
            self.invalid += 1

    @staticmethod
    def index(value):
        value = int(value)
        if not 0 <= value < 2000: raise ValueError('index')
        return value

    @staticmethod
    def label(value):
        # Labels fit inside the sender's 1200-byte datagram contract. Bound direct
        # calls as well, so untrusted labels cannot inflate assembly storage.
        if not isinstance(value, str) or len(value) > 1024:
            raise ValueError('label')
        return value

    @staticmethod
    def trim(frame, path):
        # Metadata may follow chunks. Only inspect the branch affected by this
        # message; unchanged nested dictionaries stay shared and are never mutated.
        if frame['counts'] is not None:
            results, detections, groups = frame['counts']
            routes = {'detections': 'detection', 'groups': 'landmarks',
                      'hands': 'hand', 'categories': 'category', 'gestures': 'gesture'}
            for name, count in (('detections', detections), ('groups', groups),
                                ('hands', groups), ('categories', results), ('gestures', results)):
                if path == ['counts'] or path[0] == routes[name]:
                    frame[name] = {i: value for i, value in frame[name].items() if i < count}
        if path[0] == 'landmarks' and int(path[1]) in frame['groups']:
            group = frame['groups'][int(path[1])]
            if group['count'] is not None and path[2] in ('count', 'points'):
                group['points'] = {i: value for i, value in group['points'].items() if i < group['count']}
        if path[0] == 'embedding' and frame['embedding_size'] is not None:
            frame['embedding'] = {i: value for i, value in frame['embedding'].items() if i < frame['embedding_size']}
        if path[0] == 'mask' and frame['mask_size'] == (0, 0): frame['mask'] = {}

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


# ---- Ready-to-map outputs. Pure functions so they can be tested without TouchDesigner. ----

HAND_TASKS = ('handLandmarkDetection', 'gestureRecognition')
HAND_POINTS = ('wrist', 'thumb_cmc', 'thumb_mcp', 'thumb_ip', 'thumb_tip',
               'index_mcp', 'index_pip', 'index_dip', 'index_tip',
               'middle_mcp', 'middle_pip', 'middle_dip', 'middle_tip',
               'ring_mcp', 'ring_pip', 'ring_dip', 'ring_tip',
               'pinky_mcp', 'pinky_pip', 'pinky_dip', 'pinky_tip')
POSE_POINTS = ('nose', 'left_eye_inner', 'left_eye', 'left_eye_outer', 'right_eye_inner',
               'right_eye', 'right_eye_outer', 'left_ear', 'right_ear', 'mouth_left',
               'mouth_right', 'left_shoulder', 'right_shoulder', 'left_elbow', 'right_elbow',
               'left_wrist', 'right_wrist', 'left_pinky', 'right_pinky', 'left_index',
               'right_index', 'left_thumb', 'right_thumb', 'left_hip', 'right_hip',
               'left_knee', 'right_knee', 'left_ankle', 'right_ankle', 'left_heel',
               'right_heel', 'left_foot_index', 'right_foot_index')
# (faceDetection keypoint, face mesh index) for the few face points worth naming.
FACE_POINTS = {'nose': (2, 1), 'mouth': (3, 13), 'right_eye': (0, 33), 'left_eye': (1, 263)}
TRACK_POINTS = (tuple('hand_' + n for n in HAND_POINTS) + tuple('pose_' + n for n in POSE_POINTS)
                + tuple('face_' + n for n in FACE_POINTS))
GESTURES = ('Closed_Fist', 'Open_Palm', 'Pointing_Up', 'Thumb_Down', 'Thumb_Up', 'Victory', 'ILoveYou')
COORDINATES = ('image', 'bottomleft', 'centered')
# Labels come from the network: bound the class_* channels any sender can create.
MAX_LABELS = 64
MAX_LABEL_LENGTH = 32
# Continuous channels: smoothed, and held on tracking loss when requested.
SMOOTHED = ('presence', 'mask_confidence', 'first_score', 'point_x', 'point_y',
            'hand_x', 'hand_y', 'pinch_distance')
HELD = ('point_x', 'point_y', 'hand_x', 'hand_y', 'pinch_distance')


def convert(x, y, mode):
    """Image coordinates (0..1, origin top-left) to the selected output space."""
    if mode == 'bottomleft': return x, 1 - y
    if mode == 'centered': return 2 * x - 1, 1 - 2 * y
    return x, y


def channel_name(label):
    return re.sub(r'[^a-z0-9]+', '_', str(label).lower()).strip('_')[:MAX_LABEL_LENGTH] or 'object'


def find_point(frame, name):
    """Return the image (x, y) of a named landmark in the current frame, or None."""
    kind, _, part = name.partition('_')
    task, groups = frame['task'], frame['groups']
    holistic = task == 'holisticLandmarkDetection'
    def pick(labels, index):
        for g in sorted(groups):
            if holistic and groups[g]['label'] not in labels: continue
            point = groups[g]['points'].get(index)
            if point is not None: return point
        return None
    if kind == 'hand' and part in HAND_POINTS and (task in HAND_TASKS or holistic):
        return pick(('leftHand', 'rightHand'), HAND_POINTS.index(part))
    if kind == 'pose' and part in POSE_POINTS and task in ('poseLandmarkDetection', 'holisticLandmarkDetection'):
        return pick(('pose',), POSE_POINTS.index(part))
    if kind == 'face' and part in FACE_POINTS:
        keypoint, mesh = FACE_POINTS[part]
        if task == 'faceDetection': return pick((), keypoint)
        if task in ('faceLandmarkDetection', 'holisticLandmarkDetection'): return pick(('face',), mesh)
    return None


class ControlValues(dict):
    """Channel mapping with position validity metadata, never exported as channels."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.valid_positions = set()


def controls(frame, trackpoint='hand_index_tip', coordinates='image', labels=None):
    """One value per channel. `labels` collects detection labels so class_* channels stay stable."""
    labels = set() if labels is None else labels
    f = frame
    counts = f['counts'] if f else (0, 0, 0)
    values = ControlValues(active=int(f is not None), present=int(f is not None and any(counts)),
                  frame=f['frame'] if f else 0, results=counts[0], detections=counts[1],
                  groups=counts[2], inference_ms=(f['inference'] or 0) if f else 0,
                  mask_confidence=(f['coverage'] or 0) if f else 0, first_score=0,
                  point_found=0, point_x=0, point_y=0, hand_x=0, hand_y=0, pinch_distance=0)
    if f:
        point = find_point(f, trackpoint)
        if point is not None:
            values['point_found'] = 1
            values.valid_positions.update(('point_x', 'point_y'))
            values['point_x'], values['point_y'] = convert(*point, coordinates)
        if f['task'] in HAND_TASKS:
            hand = f['groups'].get(0, {}).get('points', {})
            if 8 in hand:
                values['hand_x'], values['hand_y'] = convert(*hand[8], coordinates)
                values.valid_positions.update(('hand_x', 'hand_y'))
            if 4 in hand and 8 in hand:
                values['pinch_distance'] = math.dist(hand[4], hand[8])
                values.valid_positions.add('pinch_distance')
        if f['detections']: values['first_score'] = f['detections'][min(f['detections'])][1]
        elif f['categories']: values['first_score'] = f['categories'][min(f['categories'])][1]
        for name in (channel_name(d[0]) for d in f['detections'].values()):
            if name in labels or len(labels) < MAX_LABELS: labels.add(name)
    current = {g[0] for g in f['gestures'].values()} if f else set()
    for gesture in GESTURES:
        values['gesture_' + gesture.lower()] = int(gesture in current)
    present = {channel_name(d[0]) for d in f['detections'].values()} if f else set()
    for label in sorted(labels):
        values['class_' + label] = int(label in present)
    return values


def points(frame):
    """All landmarks as rows (tx, ty, group, index), centered -1..1 with y up, for instancing."""
    if not frame: return []
    return [(*convert(x, y, 'centered'), g, i)
            for g, group in sorted(frame['groups'].items())
            for i, (x, y) in sorted(group['points'].items())]


class OutputFilter:
    """Exponential smoothing (time constant in seconds) and optional hold on tracking loss."""
    def __init__(self):
        self.state, self.held = {}, {}

    def apply(self, values, dt, smooth=0.0, hold=False):
        out = dict(values)
        out['presence'] = float(values['present'])
        valid = getattr(values, 'valid_positions',
                        set(HELD) if values['point_found'] else set())
        for key in HELD:
            if key in valid: self.held[key] = out[key]
            elif hold and key in self.held: out[key] = self.held[key]
        alpha = 1.0 if smooth <= 0 else 1 - math.exp(-max(dt, 0) / smooth)
        for key in SMOOTHED:
            previous = self.state.get(key, out[key])
            out[key] = self.state[key] = previous + alpha * (out[key] - previous)
        return out

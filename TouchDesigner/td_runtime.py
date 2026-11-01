"""Embedded TouchDesigner runtime. All operators are resolved relative to this DAT."""
import time
import math
import numpy as np
_receiver = None
_last_refresh = 0
_last_version = -1

def receiver():
    global _receiver
    if _receiver is None:
        _receiver = me.parent().op('protocol').module.ReceiverState()
    return _receiver

def receive(address, args, source):
    receiver().receive(address, args, source)

def reset():
    global _receiver, _last_version
    _receiver = me.parent().op('protocol').module.ReceiverState()
    _last_version = -1
    refresh(force=True)

def table(name, header, rows):
    dat = me.parent().parent().op('tracking_data/' + name)
    dat.clear()
    dat.appendRow(header)
    for row in rows: dat.appendRow(row)

def refresh(force=False):
    global _last_refresh, _last_version
    r = receiver()
    r.tick()
    now = time.monotonic()
    if not force and now - _last_refresh < 0.1: return
    _last_refresh = now
    f = r.current
    age = now - r.last_seen if r.source else 0
    summary = [('state', r.status), ('task', f['task'] if f else '-'),
               ('frame', f['frame'] if f else '-'), ('source', r.source or '-'),
               ('port', int(me.parent().parent().par.Port)), ('messages', r.messages),
               ('tests', r.tests), ('invalid', r.invalid), ('age_seconds', round(age, 3))]
    table('summary', ['key', 'value'], summary)
    if force or r.version != _last_version:
        _last_version = r.version
        table('detections', ['index', 'label', 'score', 'x', 'y', 'width', 'height'],
              [(i, *v) for i, v in sorted(f['detections'].items())] if f else [])
        table('landmarks', ['group', 'label', 'index', 'x', 'y'],
              [(g, v['label'], i, *point) for g, v in sorted(f['groups'].items()) for i, point in sorted(v['points'].items())] if f else [])
        for name in ('categories', 'gestures', 'hands'):
            table(name, ['index', 'label', 'score'], [(i, *v) for i, v in sorted(f[name].items())] if f else [])
        table('embedding', ['index', 'value'], sorted(f['embedding'].items()) if f else [])
        table('mask', ['row'] + list(range(16)), [(i, *v) for i, v in sorted(f['mask'].items())] if f else [])
        me.parent().parent().op('outputs/preview').cook(force=True)
    me.parent().parent().op('outputs/controls').cook(force=True)
    label = (next(iter(f['gestures'].values()), ('', 0))[0] or next(iter(f['categories'].values()), ('', 0))[0]) if f else ''
    monitor_text = (
        'META RAY-BAN  /  OSC LAB\n\n' + r.status + '\n\n'
        + 'UDP ' + str(int(me.parent().parent().par.Port)) + '   |   ' + str(r.messages) + ' mensajes\n'
        + 'Frame: ' + str(f['frame'] if f else '-') + '   |   ' + str(round(f['inference'], 1) if f else 0) + ' ms\n'
        + 'Origen: ' + (r.source or '-') + '\n\n' + label + '\n\n'
        + 'iPhone > Configurar OSC\nIP de este Mac + puerto indicado\n\n'
        + 'Salidas: controls (CHOP)\nTablas: detections / landmarks\ncategories / gestures / hands\nembedding / mask\n\n'
        + 'X,Y: imagen original, origen arriba-izquierda.\nSin profundidad ni IDs persistentes.\n\n'
        + 'Timeout: 1 s. Datos incompletos no se publican.\nPrueba sin gafas: python3 demo_sender.py')
    me.parent().parent().op('monitor/info').par.text.expr = repr(monitor_text)

def channels(scriptOp):
    r = receiver()
    f = r.current
    values = dict(active=int(f is not None), frame=f['frame'] if f else 0,
                  results=f['counts'][0] if f else 0, detections=f['counts'][1] if f else 0,
                  groups=f['counts'][2] if f else 0, inference_ms=f['inference'] if f else 0,
                  mask_confidence=(f['coverage'] or 0) if f else 0, hand_x=0, hand_y=0,
                  pinch_distance=0, first_score=0)
    if f:
        group = f['groups'].get(0, {}).get('points', {}) if f['task'] in ('handLandmarkDetection', 'gestureRecognition') else {}
        if 8 in group:
            values['hand_x'], values['hand_y'] = group[8]
        if 4 in group and 8 in group:
            values['pinch_distance'] = math.dist(group[4], group[8])
        if f['detections']: values['first_score'] = next(iter(f['detections'].values()))[1]
        elif f['categories']: values['first_score'] = next(iter(f['categories'].values()))[1]
    scriptOp.clear()
    scriptOp.numSamples = 1
    for name, value in values.items(): scriptOp.appendChan(name)[0] = value

def picture(scriptOp):
    h, w = 540, 960
    image = np.zeros((h, w, 4), dtype=np.float32)
    image[:, :, :3] = [0.025, 0.04, 0.065]
    image[:, :, 3] = 1
    image[::54, :, :3] = [0.07, 0.1, 0.14]
    image[:, ::96, :3] = [0.07, 0.1, 0.14]
    f = receiver().current
    if f:
        if f['mask_size'] == (16, 16) and len(f['mask']) == 16:
            grid = np.array([f['mask'][i] for i in range(16)], dtype=np.float32)
            ys = np.minimum(15, np.arange(h) * 16 // h)
            xs = np.minimum(15, np.arange(w) * 16 // w)
            mask = np.clip(grid[ys[:, None], xs[None, :]], 0, 1)[::-1]
            image[:, :, :3] += mask[:, :, None] * np.array([0.05, 0.38, 0.48])
        def point(x, y, color, radius=4):
            px, py = int(x * (w-1)), int((1-y) * (h-1))
            if 0 <= px < w and 0 <= py < h:
                image[max(0,py-radius):min(h,py+radius+1), max(0,px-radius):min(w,px+radius+1), :3] = color
        for index, group in f['groups'].items():
            color = ([0.1, 0.9, 0.72], [0.96, 0.38, 0.6], [0.95, 0.75, 0.2])[index % 3]
            for x, y in group['points'].values(): point(x, y, color, 2 if len(group['points']) > 50 else 4)
        for label, score, x, y, bw, bh in f['detections'].values():
            for t in np.linspace(0, 1, 100):
                point(x+bw*t, y, [0.2,0.9,0.9], 1); point(x+bw*t, y+bh, [0.2,0.9,0.9], 1)
                point(x, y+bh*t, [0.2,0.9,0.9], 1); point(x+bw, y+bh*t, [0.2,0.9,0.9], 1)
        if f['selection']: point(*f['selection'], [1,0.3,0.2], 7)
    scriptOp.copyNumpyArray(image)

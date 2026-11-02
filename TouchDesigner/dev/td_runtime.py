"""Embedded TouchDesigner runtime. All operators are resolved relative to this DAT."""
import socket
import time
import numpy as np
_receiver = None
_filter = None
_labels = set()
_last_refresh = 0
_last_version = -1
_points_version = -1
_last_cook = None
_ip = ('-', 0.0)
_demo = dict(frame=0, last=0.0, started=0.0, task=None)
# Monitor status: (text, background colour) by the receiver status prefix.
STATES = {'LIVE': ('RECIBIENDO', (0.1, 0.55, 0.3)), 'TEST': ('PRUEBA OK', (0.15, 0.4, 0.75)),
          'TIMEOUT': ('SIN DATOS', (0.7, 0.2, 0.15)), 'STOPPED': ('DETENIDO', (0.45, 0.45, 0.45)),
          'WAITING': ('ESPERANDO', (0.6, 0.45, 0.1))}

def component(): return me.parent().parent()
def protocol(): return me.parent().op('protocol').module

def receiver():
    global _receiver, _filter
    if _receiver is None:
        _receiver = protocol().ReceiverState()
        _filter = protocol().OutputFilter()
    return _receiver

def receive(address, args, source):
    # While the built-in demo runs it owns the receiver; network messages are ignored.
    if component().par.Demo.eval(): return
    receiver().receive(address, args, source)

def reset():
    global _receiver, _last_version, _points_version, _last_cook
    _receiver = None
    _labels.clear()
    _demo.update(frame=0, last=0.0, started=time.monotonic(), task=None)
    _last_version = _points_version = -1
    _last_cook = None
    receiver()
    refresh(force=True)

def local_ip():
    """This computer's LAN address, the one to type on the iPhone. A UDP connect sends nothing."""
    global _ip
    if time.monotonic() - _ip[1] < 5: return _ip[0]
    address = '-'
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(('192.0.2.1', 9))
            address = s.getsockname()[0]
    except OSError:
        pass
    _ip = (address, time.monotonic())
    return address

def demo_tick():
    """Feed synthetic results straight into the receiver, about 15 per second, no network."""
    now = time.monotonic()
    if now - _demo['last'] < 1 / 15: return
    _demo['last'] = now
    tasks = protocol().TASKS
    choice = component().par.Demotask.eval()
    task = choice if choice in tasks else tasks[int((now - _demo['started']) / 2) % len(tasks)]
    r = receiver()
    if _demo['task'] and task != _demo['task']:
        _demo['frame'] += 1
        r.receive('/mediapipe/frame', [_demo['frame']], 'demo')
        r.receive('/mediapipe/' + _demo['task'] + '/active', [0], 'demo')
    _demo['frame'] += 1
    r.receive('/mediapipe/frame', [_demo['frame']], 'demo')
    for address, args in me.parent().op('demo').module.sample(task, _demo['frame']):
        r.receive(address, args, 'demo')
    _demo['task'] = task

def table(name, header, rows):
    dat = component().op('tracking_data/' + name)
    dat.clear()
    dat.appendRow(header)
    for row in rows: dat.appendRow(row)

def refresh(force=False):
    global _last_refresh, _last_version, _points_version
    comp = component()
    r = receiver()
    r.timeout = max(0.1, float(comp.par.Timeout))
    if comp.par.Demo.eval(): demo_tick()
    r.tick()
    # Controls cook every frame (smoothing needs time); the rest only follows new data.
    comp.op('outputs/controls').cook(force=True)
    if force or r.version != _points_version:
        _points_version = r.version
        comp.op('outputs/points').cook(force=True)
    now = time.monotonic()
    if not force and now - _last_refresh < 0.1: return
    _last_refresh = now
    f = r.current
    port = int(comp.par.Port)
    age = now - r.last_seen if r.source else 0
    summary = [('state', r.status), ('task', f['task'] if f else '-'),
               ('frame', f['frame'] if f else '-'), ('source', r.source or '-'),
               ('ip', local_ip()), ('port', port), ('messages', r.messages),
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
        comp.op('outputs/preview').cook(force=True)
    update_monitor(comp, r, f, port)

def update_monitor(comp, r, f, port):
    text, color = STATES.get(r.status.split(' ')[0], (r.status, (0.3, 0.3, 0.3)))
    if comp.par.Demo.eval(): text, color = 'DEMO (datos falsos)', (0.45, 0.25, 0.65)
    status = comp.op('monitor/status')
    status.par.text = text + ('  ·  ' + f['task'] if f else '')
    status.par.bgcolorr, status.par.bgcolorg, status.par.bgcolorb = color
    label = (next(iter(f['gestures'].values()), ('', 0))[0] or next(iter(f['categories'].values()), ('', 0))[0]) if f else ''
    monitor_text = (
        'EN EL IPHONE (Configurar OSC):\n'
        + '  IP   ' + local_ip() + '\n  Puerto   ' + str(port) + '\n\n'
        + r.status + '\n'
        + str(r.messages) + ' mensajes   |   ' + str(r.invalid) + ' inválidos\n'
        + 'Frame: ' + str(f['frame'] if f else '-') + '   |   ' + str(round(f['inference'], 1) if f else 0) + ' ms\n'
        + 'Origen: ' + (r.source or '-') + '\n\n' + label + '\n\n'
        + 'Salidas: CHOP 1 controls, CHOP 2 points,\nTOP preview\n'
        + 'Parámetros: Receiver / Outputs / Display\n\n'
        + 'Sin datos ' + str(r.timeout) + ' s = limpiar.\nSin lentes: activa Demo.\nAyuda: botón Help.')
    comp.op('monitor/info').par.text.expr = repr(monitor_text)

def channels(scriptOp):
    global _last_cook
    comp = component()
    receiver()
    now = time.monotonic()
    dt = 0 if _last_cook is None else now - _last_cook
    _last_cook = now
    values = protocol().controls(receiver().current, comp.par.Trackpoint.eval(),
                                 comp.par.Coordinates.eval(), _labels)
    values = _filter.apply(values, dt, float(comp.par.Smooth), bool(comp.par.Holdonloss.eval()))
    scriptOp.clear()
    scriptOp.numSamples = 1
    for name, value in values.items(): scriptOp.appendChan(name)[0] = value

def points(scriptOp):
    rows = protocol().points(receiver().current)
    scriptOp.clear()
    # Never zero samples: an empty frame is one instance with scale 0, so nothing is drawn.
    scriptOp.numSamples = max(1, len(rows))
    columns = list(zip(*rows)) if rows else [(0,), (0,), (-1,), (-1,)]
    columns.append((1,) * len(rows) if rows else (0,))
    for name, values in zip(('tx', 'ty', 'group', 'index', 'scale'), columns):
        scriptOp.appendChan(name).vals = list(values)

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

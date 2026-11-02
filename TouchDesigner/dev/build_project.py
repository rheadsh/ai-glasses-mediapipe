"""Developer tool. Open ../RayBan_MediaPipe_OSC.toe, then run in the Textport:
    exec(open(project.folder + '/dev/build_project.py').read())
All code is embedded in DATs; the saved TOE/TOX do not require external Python files.
"""
from pathlib import Path
OUT = Path(project.folder)  # The TouchDesigner/ folder that holds the .toe and .tox.
SRC = OUT / 'dev'
DEMO = OUT / 'demo' / 'demo_sender.py'
EXAMPLES = OUT / 'examples'
# Fail before touching the network if this is not the repository's TouchDesigner/ folder.
for required in (SRC/'osc_protocol.py', SRC/'td_runtime.py', DEMO):
    if not required.is_file():
        raise FileNotFoundError(f'{required} not found: open TouchDesigner/RayBan_MediaPipe_OSC.toe first')
PROTOCOL = {}
exec((SRC/'osc_protocol.py').read_text(encoding='utf-8'), PROTOCOL)
WARNINGS = []

def setpar(target, name, value=None, expr=None):
    """Optional cosmetic settings: record a failure instead of aborting the build."""
    try:
        par = getattr(target.par, name)
        if expr is not None: par.expr = expr
        else: par.val = value
    except Exception as error:
        WARNINGS.append(f'{target.path}.{name}: {error}')

root = op('/project1')
base = root.op('rayban_osc')
if base is None: base = root.create(baseCOMP, 'rayban_osc')
# Rebuild only our named operators. The surrounding project is preserved.
for child in list(base.children):
    if child.valid: child.destroy()
base.nodeX = 0
base.nodeY = 0

# ---- Parameters, grouped by what an artist wants to change. ----
base.destroyCustomPars()
page = base.appendCustomPage('Receiver')
p = page.appendInt('Port', label='UDP Port')[0]
p.default = 9000; p.min = p.normMin = 1; p.max = p.normMax = 65535; p.clampMin = p.clampMax = True
p = page.appendFloat('Timeout', label='Clear After (s)')[0]
p.default = 1.0; p.min = p.normMin = 0.1; p.normMax = 5; p.clampMin = True
page.appendToggle('Demo', label='Demo (Fake Data)')
p = page.appendMenu('Demotask', label='Demo Task')[0]
p.menuNames = ['all'] + list(PROTOCOL['TASKS'])
p.menuLabels = ['All tasks, 2 s each'] + list(PROTOCOL['TASKS'])
page.appendPulse('Reset', label='Reset Receiver')
page = base.appendCustomPage('Outputs')
p = page.appendMenu('Trackpoint', label='Track Point')[0]
p.menuNames = list(PROTOCOL['TRACK_POINTS'])
p.menuLabels = [n.replace('_', ' ', 1).replace('_', ' ').capitalize().replace(' ', ' - ', 1) for n in PROTOCOL['TRACK_POINTS']]
p = page.appendMenu('Coordinates', label='Coordinates')[0]
p.menuNames = list(PROTOCOL['COORDINATES'])
p.menuLabels = ['Image 0..1, origin top-left', '0..1, origin bottom-left', 'Centered -1..1, y up']
p = page.appendFloat('Smooth', label='Smooth (s)')[0]
p.default = 0.1; p.min = p.normMin = 0; p.normMax = 1; p.clampMin = True
page.appendToggle('Holdonloss', label='Hold Position On Loss')
page = base.appendCustomPage('Display')
page.appendToggle('Openmonitor', label='Open Monitor On Start')
page.appendPulse('Help', label='Help')
base.par.Port = 9000
base.par.Timeout = 1.0
base.par.Demo = False
base.par.Demotask = 'all'
base.par.Trackpoint = 'hand_index_tip'
base.par.Coordinates = 'image'
base.par.Smooth = 0.1
base.par.Holdonloss = False

def node(kind, name, x, y, owner=None):
    item = (owner or base).create(kind,name)
    item.nodeX, item.nodeY = x,y
    return item

stages = {}
for index, (name, color) in enumerate((('input_osc', (.12,.5,.62)), ('decode_frames', (.62,.4,.13)), ('tracking_data', (.46,.25,.65)), ('outputs', (.14,.6,.38)))):
    stage = node(baseCOMP, name, index*320, 100)
    stage.color = color
    stages[name] = stage
input_stage, decode, data, output = (stages[n] for n in ('input_osc','decode_frames','tracking_data','outputs'))
protocol = node(textDAT,'protocol',-200,0,decode)
protocol.text = (SRC/'osc_protocol.py').read_text(encoding='utf-8')
runtime = node(textDAT,'runtime',100,0,decode)
runtime.text = (SRC/'td_runtime.py').read_text(encoding='utf-8')
demo = node(textDAT,'demo',400,0,decode)
demo.text = DEMO.read_text(encoding='utf-8')
recv = node(oscinDAT,'osc_in',0,100,input_stage)
recv.par.active = False
recv.par.port.expr = 'int(parent(2).par.Port)'
recv.par.shared = False
recv.par.splitbundle = True
recv.par.splitmessage = True
recv.par.maxlines = 100
recv.par.addscope = '/mediapipe/*'
callbacks = recv.par.callbacks.eval()
callbacks.nodeX, callbacks.nodeY = 0,-100
callbacks.text = """def onReceiveOSC(dat, rowIndex, message, bytes, timeStamp, address, args, peer):
    dat.parent().parent().op('decode_frames/runtime').module.receive(address, args, str(peer.address))
    return
"""
for index,name in enumerate(('summary','detections','landmarks','categories','gestures','hands','embedding','mask')):
    node(tableDAT,name,(index%4)*240,200-(index//4)*220,data)

def script(kind, name, x, function):
    item = node(kind, name, x, 100, output)
    callback = item.par.callbacks.eval()
    callback.nodeX, callback.nodeY = x, -100
    callback.text = f"""def onCook(scriptOp):
    scriptOp.parent().parent().op('decode_frames/runtime').module.{function}(scriptOp)
    return
"""
    return item
script(scriptCHOP, 'controls', 0, 'channels')
script(scriptCHOP, 'points', 300, 'points')
script(scriptTOP, 'preview', 600, 'picture')
# Component outputs: wire rayban_osc directly into your network, no paths needed.
for index, (kind, select, name, source) in enumerate(((selectCHOP, 'OUT_CONTROLS', 'controls', 'outputs/controls'),
                                                      (selectCHOP, 'OUT_POINTS', 'points', 'outputs/points'),
                                                      (selectTOP, 'OUT_PREVIEW', 'preview', 'outputs/preview'))):
    selected = node(kind, select, 960, -120 - index*180)
    if kind is selectCHOP: selected.par.chop = source
    else: selected.par.top = source
    out = node(outCHOP if kind is selectCHOP else outTOP, name, 1200, -120 - index*180)
    out.inputConnectors[0].connect(selected)

panel = node(containerCOMP,'monitor',1280,100)
panel.color = (.15,.38,.65)
panel.par.w = 1280
panel.par.h = 720
panel.par.bgcolorr = .025; panel.par.bgcolorg = .04; panel.par.bgcolorb = .065; panel.par.bgalpha = 1
screen = panel.create(containerCOMP,'tracking')
screen.par.x=320;screen.par.y=90;screen.par.w=960;screen.par.h=540
screen.par.top = '../OUT_PREVIEW'
screen.par.topfill = 'fitbest'
status = panel.create(textCOMP,'status')
status.par.x=16; status.par.y=640; status.par.w=300; status.par.h=64
status.par.text = 'ESPERANDO'
status.par.fontsize = 20
setpar(status, 'bgalpha', 1)
setpar(status, 'fontcolorr', 1); setpar(status, 'fontcolorg', 1); setpar(status, 'fontcolorb', 1)
info = panel.create(textCOMP,'info')
info.par.x=16; info.par.y=24; info.par.w=300; info.par.h=600
info.par.text = 'META RAY-BAN / OSC LAB'
info.par.fontsize = 13
info.par.type = 'multiline'
info.par.wordwrap = True
info.par.alignx = 'left'
info.par.aligny = 'top'
info.par.textpaddingt = 8
caption = panel.create(textCOMP,'caption')
caption.par.x=340;caption.par.y=20;caption.par.w=920;caption.par.h=55
caption.par.text = 'CAMERA COORDINATES / X,Y NORMALIZED\nLandmarks + boxes + mask confidence | No video is transmitted'
caption.par.fontsize = 14
caption.par.type = 'multiline'
caption.par.wordwrap = True
caption.par.alignx = 'left'
caption.par.aligny = 'top'

execute = node(executeDAT,'refresh',100,-250,decode)
execute.text = '''def onStart():
    me.parent().op('runtime').module.reset()
    if me.parent().parent().par.Openmonitor:
        me.parent().parent().op('monitor').openViewer()
    return

def onFrameEnd(frame):
    me.parent().op('runtime').module.refresh()
    return
'''
execute.par.start = True
execute.par.frameend = True
parameters = node(parameterexecuteDAT,'parameters',400,-250,decode)
parameters.par.op.expr = 'me.parent(2)'
parameters.par.pars = '*'
setpar(parameters, 'custom', True)
setpar(parameters, 'builtin', False)
setpar(parameters, 'valuechange', True)
setpar(parameters, 'onpulse', True)
parameters.text = '''def onValueChange(par, prev):
    runtime = me.parent().op('runtime').module
    if par.name == 'Demo': runtime.reset()
    else: runtime.refresh(force=True)
    return

def onPulse(par):
    if par.name == 'Reset': me.parent().op('runtime').module.reset()
    elif par.name == 'Help': me.parent(2).op('START_HERE').openViewer()
    return
'''
notes = node(textDAT,'START_HERE',0,-150)
notes.text = '''RAY-BAN / MEDIAPIPE / OSC  -  HELP

1. iPhone > Configurar OSC: type the IP and port shown in the monitor, turn sending on, Apply.
   No glasses? Turn on Receiver > Demo (fake data, no network).
2. Wire the outputs of rayban_osc:
   - CHOP output 1 "controls": one value per channel, ready to map.
   - CHOP output 2 "points": every landmark as tx/ty/scale samples for Geometry COMP instancing.
   - TOP output "preview": drawing of the received data, NOT camera video.
3. Parameters:
   Receiver: UDP Port, Clear After (s), Demo, Demo Task, Reset Receiver.
   Outputs: Track Point (point_x/point_y), Coordinates, Smooth (s), Hold Position On Loss.
   Display: Open Monitor On Start, Help.

Useful channels: active, present, presence (smooth 0..1), point_x, point_y, point_found,
hand_x, hand_y, pinch_distance, gesture_open_palm / closed_fist / pointing_up / thumb_up /
thumb_down / victory / iloveyou, class_<label> (1 while that object is detected).

Examples: /project1/easy_example (CHOPs only) and /project1/points_example (instancing),
also saved as examples/*.tox.
Tables: Select DAT on rayban_osc/tracking_data/detections, landmarks, categories, ...
Do not edit inside this component: rebuilding it replaces everything here.
One receiver per UDP port. Full guide: TouchDesigner/README.md.
'''
recv.par.active = True
runtime.module.reset()

# ---- Examples outside the component: copy them, or drop examples/*.tox into a project. ----
def output_of(name):
    for connector in base.outputConnectors:
        if getattr(connector, 'outOP', None) is not None and connector.outOP.name == name:
            return connector
    raise LookupError('rayban_osc has no output ' + name)

def example(name, x, y, color, source):
    old = root.op(name)
    if old is not None: old.destroy()
    comp = root.create(baseCOMP, name)
    comp.nodeX, comp.nodeY, comp.color = x, y, color
    node(inCHOP, 'from_rayban', -200, 0, comp)
    comp.inputConnectors[0].connect(output_of(source))
    return comp

easy = example('easy_example', 0, -400, (.85, .55, .15), 'controls')
steps = (
    ('presence', 'presence', '1. Presence: 0 = nobody, 1 = tracking (fades smoothly).'),
    ('finger', 'point_x point_y', '2. Position of the Track Point (default: index fingertip).'),
    ('pinch', 'pinch_distance', '3. Pinch: distance between thumb and index tips.'),
    ('gestures', 'gesture_open_palm gesture_closed_fist', '4. Gestures: 1 while the gesture is seen.'),
)
for row, (name, channels, comment) in enumerate(steps):
    item = node(selectCHOP, name, 0, -row*160, easy)
    item.par.chop = 'from_rayban'
    item.par.channames = channels
    item.comment = comment
pinch_size = node(mathCHOP, 'pinch_size', 200, -320, easy)
pinch_size.inputConnectors[0].connect(easy.op('pinch'))
setpar(pinch_size, 'fromrange1', 0.02); setpar(pinch_size, 'fromrange2', 0.25)
setpar(pinch_size, 'torange1', 0.03); setpar(pinch_size, 'torange2', 0.25)
pinch_size.comment = 'Math CHOP: turns a small pinch range into a circle size.'
dot = node(circleTOP, 'dot', 450, -100, easy)
setpar(dot, 'outputresolution', 'custom')
setpar(dot, 'resolutionw', 1280); setpar(dot, 'resolutionh', 720)
setpar(dot, 'radiusunit', 'fractionaspect')
setpar(dot, 'centerx', expr="op('finger')['point_x'] - 0.5")
setpar(dot, 'centery', expr="0.5 - op('finger')['point_y']")
setpar(dot, 'radiusx', expr="op('pinch_size')['pinch_distance']")
setpar(dot, 'radiusy', expr="op('pinch_size')['pinch_distance']")
setpar(dot, 'fillcolorr', expr="1 - 0.8 * op('gestures')['gesture_open_palm']")
setpar(dot, 'fillcolorg', expr="1 - 0.5 * op('gestures')['gesture_open_palm'] - 0.8 * op('gestures')['gesture_closed_fist']")
setpar(dot, 'fillcolorb', expr="1 - 0.8 * op('gestures')['gesture_closed_fist']")
dot.comment = 'Circle: follows the finger, pinch sets the size, open palm = blue, fist = red.'
fade = node(levelTOP, 'fade', 650, -100, easy)
fade.inputConnectors[0].connect(dot)
setpar(fade, 'opacity', expr="op('presence')['presence']")
fade.comment = 'Level TOP: fades the circle out when nobody is tracked.'
easy_out = node(outTOP, 'out', 850, -100, easy)
easy_out.inputConnectors[0].connect(fade)
readme = node(textDAT, 'READ_ME', -200, 250, easy)
readme.text = '''EASY CHOP EXAMPLE - no code, only CHOPs and expressions

Turn on rayban_osc > Receiver > Demo, choose Demo Task "gestureRecognition", and look at "out".

1. presence  -> Level TOP opacity: the circle fades in while someone is tracked.
2. finger    -> Circle TOP center: point_x / point_y follow the index fingertip.
3. pinch     -> Math CHOP -> Circle TOP radius: pinch to grow or shrink it.
4. gestures  -> Circle TOP colour: open palm turns it blue, closed fist red.

Click a Circle or Level parameter to see its expression, e.g. op('finger')['point_x'] - 0.5.
Swap the Circle TOP for your own visual and keep the same expressions.
'''
easy.viewer = True

instancing = example('points_example', 400, -400, (.2, .6, .7), 'points')
geo = node(geometryCOMP, 'instances', 0, 0, instancing)
for child in list(geo.children): child.destroy()
sphere = geo.create(sphereSOP, 'sphere')
setpar(sphere, 'radx', 0.025); setpar(sphere, 'rady', 0.025); setpar(sphere, 'radz', 0.025)
sphere.render = sphere.display = True
look = node(constantMAT, 'look', 0, -160, instancing)
setpar(look, 'colorr', 0.1); setpar(look, 'colorg', 0.9); setpar(look, 'colorb', 0.75)
setpar(geo, 'material', expr="parent().op('look')")
setpar(geo, 'instancing', True)
setpar(geo, 'instanceop', expr="parent().op('from_rayban')")
for axis, channel in (('tx', 'tx'), ('ty', 'ty'), ('sx', 'scale'), ('sy', 'scale'), ('sz', 'scale')):
    setpar(geo, 'instance' + axis, channel)
camera = node(cameraCOMP, 'cam', 0, 160, instancing)
setpar(camera, 'tz', 3)
render = node(renderTOP, 'render', 250, 0, instancing)
setpar(render, 'camera', expr="parent().op('cam')")
setpar(render, 'geometry', expr="parent().op('instances')")
setpar(render, 'outputresolution', 'custom')
setpar(render, 'resolutionw', 1280); setpar(render, 'resolutionh', 720)
points_out = node(outTOP, 'out', 450, 0, instancing)
points_out.inputConnectors[0].connect(render)
readme = node(textDAT, 'READ_ME', -200, 250, instancing)
readme.text = '''POINTS INSTANCING EXAMPLE

The "points" CHOP output has one sample per landmark: tx, ty (centered -1..1, y up),
group, index and scale (0 when nothing is tracked). The Geometry COMP instances a sphere
on every sample (Instance page: Translate X = tx, Translate Y = ty, Scale = scale).
Turn on Demo with "faceLandmarkDetection" or "poseLandmarkDetection" and view "out".
Replace the sphere with any SOP to change what is drawn on every landmark.
'''
instancing.viewer = True

for pane in ui.panes:
    if pane.type == PaneType.NETWORKEDITOR:
        pane.owner = root
        if callable(getattr(pane, 'home', None)): pane.home()
EXAMPLES.mkdir(exist_ok=True)
easy.save(str(EXAMPLES/'RayBan_Easy_CHOPs.tox'))
instancing.save(str(EXAMPLES/'RayBan_Points_Instancing.tox'))
# The reusable .tox stays quiet inside other projects; only the example project opens the monitor.
base.par.Openmonitor = False
base.save(str(OUT/'RayBan_OSC.tox'))
base.par.Openmonitor = True
project.save(str(OUT/'RayBan_MediaPipe_OSC.toe'))
problems = [n.path+' '+str(n.errors()) for c in (base, easy, instancing) for n in c.findChildren() if n.errors()]
(SRC/'build_report.txt').write_text('\n'.join(problems + ['WARNING ' + w for w in WARNINGS]) or 'No operator errors at build time')
print('SAVED', str(OUT/'RayBan_MediaPipe_OSC.toe'))

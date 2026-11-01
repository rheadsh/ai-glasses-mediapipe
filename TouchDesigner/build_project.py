"""Run inside TouchDesigner Textport with exec(open(PATH).read()).
All code is embedded in DATs; the saved TOE/TOX do not require external Python files.
"""
from pathlib import Path
OUT = Path('/Users/robertocabezas/Documents/_AI_Ecosystems/xcode/mediapipe-tests/TouchDesigner')
root = op('/project1')
base = root.op('rayban_osc')
if base is None: base = root.create(baseCOMP, 'rayban_osc')
# Rebuild only our named component. The surrounding project is preserved.
for child in list(base.children):
    if child.valid: child.destroy()
base.nodeX = 0
base.nodeY = 0
page = base.appendCustomPage('OSC Receiver') if not base.customPages else base.customPages[0]
if not hasattr(base.par,'Port'):
    p = page.appendInt('Port', label='UDP Port')[0]
    p.default = 9000; p.min = 1; p.max = 65535
base.par.Port = 9000

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
protocol.text = (OUT/'osc_protocol.py').read_text()
runtime = node(textDAT,'runtime',100,0,decode)
runtime.text = (OUT/'td_runtime.py').read_text()
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
controls = node(scriptCHOP,'controls',0,100,output)
cc = controls.par.callbacks.eval()
cc.nodeX, cc.nodeY = 0,-100
cc.text = """def onCook(scriptOp):
    scriptOp.parent().parent().op('decode_frames/runtime').module.channels(scriptOp)
    return
"""
preview = node(scriptTOP,'preview',400,100,output)
pc = preview.par.callbacks.eval()
pc.nodeX, pc.nodeY = 400,-100
pc.text = """def onCook(scriptOp):
    scriptOp.parent().parent().op('decode_frames/runtime').module.picture(scriptOp)
    return
"""
outchop = node(selectCHOP,'OUT_CONTROLS',960,-120)
outchop.par.chop = 'outputs/controls'
outtop = node(selectTOP,'OUT_PREVIEW',1240,-120)
outtop.par.top = 'outputs/preview'

panel = node(containerCOMP,'monitor',1280,100)
panel.color = (.15,.38,.65)
panel.par.w = 1280
panel.par.h = 720
panel.par.bgcolorr = .025; panel.par.bgcolorg = .04; panel.par.bgcolorb = .065; panel.par.bgalpha = 1
screen = panel.create(containerCOMP,'tracking')
screen.par.x=320;screen.par.y=90;screen.par.w=960;screen.par.h=540
screen.par.top = '../OUT_PREVIEW'
screen.par.topfill = 'fitbest'
info = panel.create(textCOMP,'info')
info.par.x=16; info.par.y=24; info.par.w=300; info.par.h=680
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
caption.par.text.expr = repr(caption.par.text.eval())
caption.par.wordwrap = True
caption.par.alignx = 'left'
caption.par.aligny = 'top'

execute = node(executeDAT,'refresh',100,-250,decode)
execute.text = '''def onStart():
    me.parent().op('runtime').module.reset()
    me.parent().parent().op('monitor').openViewer()
    return

def onFrameEnd(frame):
    me.parent().op('runtime').module.refresh()
    return
'''
execute.par.start = True
execute.par.frameend = True
notes = node(textDAT,'START_HERE',0,-150)
notes.text = '''RAY-BAN / MEDIAPIPE / OSC
Open monitor viewer. The root network reads left to right: input_osc -> decode_frames -> tracking_data -> outputs.
UDP port: change rayban_osc > OSC Receiver > UDP Port (default 9000).
iPhone: configure OSC with the LAN IP of this Mac and the same port.
OSC In DAT splits bundles/messages, preserving string arguments and chunk offsets.
OUT_CONTROLS: numeric channels for mapping to visuals or sound. Inspect tracking_data for tables.
OUT_PREVIEW: synthetic visual rendering of received coordinates/mask, NOT camera video.
Data tables: summary, detections, landmarks, categories, gestures, hands, embedding, mask.
The parser publishes complete frames only and clears after 1 second without data.
Frame IDs are session-local. One sender at a time; allow 1 second between senders.
DEMO: python3 demo_sender.py --task handLandmarkDetection --seconds 20
See README.md and ../mediapipe-ios/OSC.md for full protocol.
'''
recv.par.active = True
runtime.module.reset()
for pane in ui.panes:
    if pane.type == PaneType.NETWORKEDITOR:
        pane.owner = base
        if callable(getattr(pane, 'home', None)): pane.home()
base.save(str(OUT/'RayBan_OSC.tox'))
project.save(str(OUT/'RayBan_MediaPipe_OSC.toe'))
(OUT/'build_report.txt').write_text('\n'.join(n.path+' '+str(n.errors()) for n in base.findChildren() if n.errors()) or 'No operator errors at build time')
print('SAVED', str(OUT/'RayBan_MediaPipe_OSC.toe'))

"""Run build_finger_geometry(folder) in a blank TouchDesigner project."""
from pathlib import Path


def build_finger_geometry(folder):
    folder = Path(folder)
    root = op('/project1')
    if root.children:
        raise RuntimeError('Open a blank project first.')

    receiver = root.loadTox(str(folder / 'RayBan_OSC.tox'))
    receiver.name = 'rayban_osc'
    receiver.par.Openmonitor = False
    receiver.par.Demo = False
    receiver.par.Demotask = 'handLandmarkDetection'
    receiver.nodeX, receiver.nodeY = 0, 0

    shapes = root.create(scriptTOP, 'finger_shapes')
    shapes.nodeX, shapes.nodeY = 300, 0
    shapes.par.callbacks.eval().text = '''import math
import numpy as np

WIDTH, HEIGHT = 960, 540
HAND_TASKS = ('handLandmarkDetection', 'gestureRecognition')
FINGERS = (
    # MediaPipe fingertip, polygon sides (0 means circle), RGB
    (4, 4, (1.0, 0.63, 0.29)),
    (8, 0, (0.24, 0.95, 0.81)),
    (12, 3, (0.60, 0.72, 1.0)),
    (16, 4, (1.0, 0.48, 0.69)),
    (20, 6, (0.86, 0.72, 1.0)),
)

background = np.empty((HEIGHT, WIDTH, 4), dtype=np.float32)
background[:] = (0.028, 0.044, 0.068, 1)
background[::45, :, :3] = (0.058, 0.077, 0.105)
background[:, ::48, :3] = (0.058, 0.077, 0.105)


def hand_frame():
    receiver = me.parent().op('rayban_osc/decode_frames/runtime').module.receiver()
    frame = receiver.current
    return frame if frame and frame['task'] in HAND_TASKS else None


def draw(image, point, radius, sides, phase, color):
    x, y = point[0] * (WIDTH - 1), (1 - point[1]) * (HEIGHT - 1)
    lo_x, hi_x = max(0, math.floor(x-radius-1)), min(WIDTH, math.ceil(x+radius+1))
    lo_y, hi_y = max(0, math.floor(y-radius-1)), min(HEIGHT, math.ceil(y+radius+1))
    if lo_x >= hi_x or lo_y >= hi_y:
        return
    py, px = np.ogrid[lo_y:hi_y, lo_x:hi_x]
    dx, dy = px - x, py - y
    distance = np.hypot(dx, dy)
    if sides:
        sector = 2 * math.pi / sides
        angle = (np.arctan2(dy, dx) - phase + math.pi / sides) % sector - math.pi / sides
        distance = distance * np.cos(angle) - radius * math.cos(math.pi / sides)
    else:
        distance -= radius
    alpha = np.clip(0.5 - distance, 0, 1)[..., None]
    pixels = image[lo_y:hi_y, lo_x:hi_x, :3]
    pixels[:] = pixels * (1 - alpha) + np.asarray(color) * alpha


def onCook(scriptOp):
    frame = hand_frame()
    image = background.copy()
    if frame:
        for group in frame['groups'].values():
            points = group['points']
            for tip, sides, color in FINGERS:
                if tip not in points:
                    continue
                radius = 20
                if tip == 8 and 4 in points:
                    thumb, index = points[4], points[8]
                    spread = math.hypot((thumb[0]-index[0])*WIDTH, (thumb[1]-index[1])*HEIGHT)
                    radius = 14 + 22 * min(1, spread / 135)
                # A quarter sector gives the thumb a square and the ring finger a diamond.
                phase = 0 if tip == 4 else math.pi / 4 if tip == 16 else -math.pi / 2
                draw(image, points[tip], radius, sides, phase, color)
    scriptOp.copyNumpyArray(image)
'''

    output = root.create(nullTOP, 'OUT_FINGERS')
    output.nodeX, output.nodeY = 580, 0
    output.inputConnectors[0].connect(shapes)
    output.viewer = True

    refresh = root.create(executeDAT, 'refresh_fingers')
    refresh.nodeX, refresh.nodeY = 300, -180
    refresh.text = '''previous = None

def onFrameEnd(frame):
    global previous
    top = me.parent().op('finger_shapes')
    current = top.par.callbacks.eval().module.hand_frame()
    if current is not previous:
        previous = current
        top.cook(force=True)
'''
    refresh.par.frameend = True

    notes = root.create(textDAT, 'LEEME')
    notes.nodeX, notes.nodeY = 0, 220
    notes.text = '''FIGURAS CON LOS DEDOS · OSC

En el iPhone, abre Configurar OSC, introduce la IP de esta computadora,
usa UDP 9000 (rayban_osc > Receiver > UDP Port) y aplica el envío.
Usa la misma red y selecciona Hand Landmarks o Gesture Recognition.
La ventana TRACKING_EN_VIVO muestra las figuras, la IP y el puerto.

Pulgar: cuadrado naranja. Índice: círculo turquesa.
Medio: triángulo azul. Anular: rombo rosa. Meñique: hexágono violeta.
Acerca el pulgar al índice para achicar el círculo.
Cada mano recibida aporta un juego de figuras. Sin tracking, se limpian.

Para probar sin lentes activa rayban_osc > Receiver > Demo.
Apaga Demo para volver a recibir OSC.
'''

    add_live_view(root)
    output.cook(force=True)
    errors = [(node.path, node.errors()) for node in root.findChildren() if node.errors()]
    if errors:
        raise RuntimeError(str(errors))
    for pane in ui.panes:
        if pane.type == PaneType.NETWORKEDITOR:
            pane.owner = root
            pane.home()
    project.save(str(folder / 'RayBan_Finger_Geometry.toe'))


def add_live_view(root):
    """Open a dedicated display at startup, with the OSC receiver status visible."""
    panel = root.create(containerCOMP, 'TRACKING_EN_VIVO')
    panel.nodeX, panel.nodeY = 850, 0
    panel.par.w, panel.par.h = 960, 610
    panel.par.bgcolorr, panel.par.bgcolorg, panel.par.bgcolorb = 0.04, 0.06, 0.09
    panel.par.bgalpha = 1

    canvas = panel.create(containerCOMP, 'figuras')
    canvas.par.w, canvas.par.h = 960, 540
    canvas.par.top = '../OUT_FINGERS'
    canvas.par.topfill = 'fitbest'

    status = panel.create(textCOMP, 'estado')
    status.par.x, status.par.y = 18, 540
    status.par.w, status.par.h = 924, 70
    status.par.fontsize = 16
    status.par.alignx = 'left'
    status.par.type = 'multiline'
    status.par.text.expr = r"""(
        ('DEMO LOCAL' if op('../rayban_osc').par.Demo.eval()
         else str(op('../rayban_osc/tracking_data/summary')['state', 'value'] or 'ESPERANDO OSC'))
        + '\nOSC  ·  IP ' + str(op('../rayban_osc/tracking_data/summary')['ip', 'value'] or '…')
        + '  ·  UDP ' + str(int(op('../rayban_osc').par.Port))
        + '  ·  Hand Landmarks / Gesture Recognition'
    )"""

    startup = root.create(executeDAT, 'abrir_pantalla')
    startup.nodeX, startup.nodeY = 850, -180
    startup.text = """def onStart():
    me.parent().op('TRACKING_EN_VIVO').openViewer()
"""
    startup.par.start = True
    return panel

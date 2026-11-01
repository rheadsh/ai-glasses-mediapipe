#!/usr/bin/env python3
"""Standard-library OSC demo; sends synthetic data, never claims to be live glasses."""
import argparse
import math
import socket
import struct
import time
from osc_protocol import TASKS

def string(value):
    data = str(value).encode('ascii') + b'\0'
    return data + b'\0' * (-len(data) % 4)

def message(address, args):
    tags, data = ',', b''
    for value in args:
        if isinstance(value, int): tags += 'i'; data += struct.pack('>i', value)
        elif isinstance(value, float): tags += 'f'; data += struct.pack('>f', value)
        else: tags += 's'; data += string(value)
    return string(address) + string(tags) + data

def packets(frame, messages):
    base = b'#bundle\0' + struct.pack('>Q', 1)
    def element(msg): return struct.pack('>I', len(msg)) + msg
    base += element(message('/mediapipe/frame', [frame]))
    packet = base
    for address, args in messages:
        data = element(message(address, args))
        if len(packet) + len(data) > 1200:
            yield packet
            packet = base
        packet += data
    if packet != base: yield packet

def sample(task, frame):
    root = '/mediapipe/' + task
    t = frame / 15
    groups = []
    count, detections = 1, []
    extra = []
    if task in ('objectDetection', 'faceDetection'):
        detections = [['DEMO cup' if task == 'objectDetection' else 'DEMO face', .92, .3 + .12*math.sin(t), .25, .22, .35]]
    if task in ('handLandmarkDetection', 'gestureRecognition', 'poseLandmarkDetection', 'faceLandmarkDetection', 'holisticLandmarkDetection'):
        n = 21 if 'hand' in task.lower() or task == 'gestureRecognition' else 33 if task == 'poseLandmarkDetection' else 478
        groups = [[(.5+.25*math.cos(i*.37+t), .5+.3*math.sin(i*.37+t)) for i in range(n)]]
        if task in ('handLandmarkDetection','gestureRecognition'):
            extra.append(('/hand/0/handedness', ['Right', .99]))
        if task == 'gestureRecognition': extra.append(('/gesture/0', ['Open_Palm', .96]))
        if task == 'holisticLandmarkDetection': extra.append(('/landmarks/0/label', ['face']))
    if task == 'imageClassification': extra.append(('/category/0', ['DEMO plant', .91]))
    if task == 'imageEmbedding':
        extra.append(('/embedding/dimensions', [128]))
        for offset in (0,64): extra.append(('/embedding/values', [offset] + [float(math.sin(i*.13+t)) for i in range(offset,offset+64)]))
    if task in ('imageSegmentation', 'interactiveSegmentation'):
        extra.append(('/mask/size', [16,16]))
        for row in range(16):
            extra.append(('/mask/row', [row]+[float(math.exp(-((col-8-3*math.sin(t))**2+(row-8)**2)/20)) for col in range(16)]))
        extra.append(('/mask/coverage', [.25]))
        if task == 'interactiveSegmentation':
            groups = [[(.5,.5)]]
            extra.append(('/selection', [.5,.5]))
    result = [(root+'/active',[1]), (root+'/counts',[count,len(detections),len(groups)]), (root+'/inferenceMs',[12.5])]
    result += [(root+'/detection/'+str(i), values) for i,values in enumerate(detections)]
    for group, points in enumerate(groups):
        result.append((root+'/landmarks/'+str(group)+'/count',[len(points)]))
        for offset in range(0,len(points),32):
            values = [float(c) for point in points[offset:offset+32] for c in point]
            result.append((root+'/landmarks/'+str(group)+'/points',[offset]+values))
    result += [(root+address,args) for address,args in extra]
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=9000)
    parser.add_argument('--seconds', type=float, default=24)
    parser.add_argument('--task', choices=TASKS)
    args = parser.parse_args()
    sock = socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    started = time.monotonic()
    frame = 1
    previous = None
    try:
        while time.monotonic()-started < args.seconds:
            task = args.task or TASKS[int((time.monotonic()-started)/2) % len(TASKS)]
            if previous and task != previous:
                for packet in packets(frame, [('/mediapipe/'+previous+'/active',[0])]): sock.sendto(packet,(args.host,args.port))
                frame += 1
            for packet in packets(frame,sample(task,frame)): sock.sendto(packet,(args.host,args.port))
            previous = task
            frame += 1
            time.sleep(1/15)
    finally:
        if previous:
            for packet in packets(frame,[('/mediapipe/'+previous+'/active',[0])]): sock.sendto(packet,(args.host,args.port))
        sock.close()
    print('DEMO finalizada: datos sinteticos, no lecturas de lentes.')

if __name__ == '__main__': main()

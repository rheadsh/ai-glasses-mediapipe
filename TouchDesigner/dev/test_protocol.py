import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'demo'))
from osc_protocol import ReceiverState, TASKS, OutputFilter, controls, points, find_point, convert, TRACK_POINTS, MAX_LABELS, MAX_LABEL_LENGTH
from demo_sender import sample, packets, TASKS as DEMO_TASKS

class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.r = ReceiverState(clock=lambda: self.now)

    def send(self, frame, task):
        self.r.receive('/mediapipe/frame',[frame])
        for address,args in sample(task,frame): self.r.receive(address,args)

    def test_all_eleven_tasks_publish_numeric_payloads(self):
        for frame,task in enumerate(TASKS,1):
            self.send(frame,task)
            self.assertEqual(self.r.current['task'],task)
        self.assertEqual(self.r.seen_tasks,set(TASKS))
        self.assertEqual(self.r.invalid,0)

    def test_incomplete_landmarks_do_not_replace_previous_frame(self):
        self.send(1,'objectDetection')
        self.r.receive('/mediapipe/frame',[2])
        root='/mediapipe/handLandmarkDetection'
        for path,args in [('/counts',[1,0,1]),('/inferenceMs',[1.0]),('/landmarks/0/count',[2]),('/landmarks/0/points',[0,.1,.2])]:
            self.r.receive(root+path,args)
        self.assertEqual(self.r.current['frame'],1)
        self.r.receive(root+'/landmarks/0/points',[1,.3,.4])
        self.assertEqual(self.r.current['frame'],1)  # handedness still missing
        self.r.receive(root+'/hand/0/handedness',['Right',.9])
        self.assertEqual(self.r.current['frame'],2)
        self.assertEqual(self.r.current['groups'][0]['points'][1],(.3,.4))
        self.assertEqual(self.r.current['hands'][0],('Right',.9))

    def test_old_packets_cannot_mix_into_new_frames(self):
        self.send(10,'objectDetection')
        self.send(9,'handLandmarkDetection')
        self.assertEqual(self.r.current['task'],'objectDetection')

    def test_stop_timeout_and_sender_restart(self):
        self.send(10,'objectDetection')
        self.r.receive('/mediapipe/frame',[11])
        self.r.receive('/mediapipe/objectDetection/active',[0])
        self.assertIsNone(self.r.current)
        self.now=2
        self.r.tick()
        self.send(1,'handLandmarkDetection')
        self.assertEqual(self.r.current['frame'],1)
        self.now=4
        self.r.tick()
        self.assertIsNone(self.r.current)

    def test_test_messages_do_not_keep_old_tracking_alive(self):
        self.send(1,'objectDetection')
        self.now=.7;self.r.receive('/mediapipe/test',['rayban',1])
        self.now=1.1;self.r.tick()
        self.assertIsNone(self.r.current)

    def test_conflicting_sources_and_nan_rejected(self):
        self.send(1,'objectDetection')
        self.r.receive('/mediapipe/frame',[2],'other-source')
        self.assertEqual(self.r.context,1)
        self.r.receive('/mediapipe/objectDetection/inferenceMs',[float('nan')])
        self.assertEqual(self.r.invalid,1)

    def test_named_points_follow_the_task(self):
        self.send(1,'handLandmarkDetection')
        hand = self.r.current
        self.assertEqual(find_point(hand,'hand_index_tip'),hand['groups'][0]['points'][8])
        self.assertIsNone(find_point(hand,'pose_nose'))
        self.send(2,'poseLandmarkDetection')
        self.assertEqual(find_point(self.r.current,'pose_left_wrist'),self.r.current['groups'][0]['points'][15])
        self.send(3,'holisticLandmarkDetection')  # the demo's only holistic group is labelled face
        self.assertEqual(find_point(self.r.current,'face_nose'),self.r.current['groups'][0]['points'][1])
        self.assertIsNone(find_point(self.r.current,'hand_wrist'))
        self.assertEqual(len(TRACK_POINTS),len(set(TRACK_POINTS)))

    def test_controls_expose_triggers_and_converted_coordinates(self):
        self.send(1,'gestureRecognition')
        x,y = self.r.current['groups'][0]['points'][8]
        values = controls(self.r.current,'hand_index_tip','centered')
        self.assertEqual((values['point_x'],values['point_y']),(2*x-1,1-2*y))
        self.assertEqual((values['active'],values['present'],values['point_found']),(1,1,1))
        self.assertEqual(values['gesture_open_palm'],1)
        self.assertEqual(values['gesture_closed_fist'],0)
        self.assertEqual(convert(.25,.25,'bottomleft'),(.25,.75))
        labels=set()
        self.send(2,'objectDetection')
        self.assertEqual(controls(self.r.current,labels=labels)['class_demo_cup'],1)
        empty = controls(None,labels=labels)
        self.assertEqual((empty['active'],empty['present'],empty['class_demo_cup']),(0,0,0))

    def test_network_labels_cannot_grow_channels_without_bound(self):
        labels=set()
        for frame in range(1,MAX_LABELS+20):
            self.r.receive('/mediapipe/frame',[frame])
            root='/mediapipe/objectDetection'
            for path,args in [('/counts',[1,1,0]),('/inferenceMs',[1.0]),('/detection/0',[str(frame)+'x'*100,.9,0.,0.,.1,.1])]:
                self.r.receive(root+path,args)
            controls(self.r.current,labels=labels)
        self.assertEqual(len(labels),MAX_LABELS)
        self.assertTrue(all(len(label)<=MAX_LABEL_LENGTH for label in labels))

    def test_points_are_centered_rows_for_instancing(self):
        self.send(1,'handLandmarkDetection')
        rows = points(self.r.current)
        self.assertEqual(len(rows),21)
        self.assertEqual(rows[8][2:],(0,8))
        self.assertTrue(all(-1<=v<=1 for row in rows for v in row[:2]))
        self.assertEqual(points(None),[])

    def test_filter_smooths_and_holds(self):
        f = OutputFilter()
        self.send(1,'handLandmarkDetection')
        live = controls(self.r.current)
        out = f.apply(live,0.0,smooth=0.5,hold=True)
        self.assertEqual(out['point_x'],live['point_x'])  # first value is not faded in from zero
        lost = controls(None)
        held = f.apply(lost,10.0,smooth=0.0,hold=True)
        self.assertEqual(held['point_x'],live['point_x'])
        self.assertEqual(held['presence'],0.0)
        dropped = OutputFilter(); dropped.apply(live,0,0,False)
        self.assertEqual(dropped.apply(lost,1,0,False)['point_x'],0)
        smooth = OutputFilter(); smooth.apply(lost,0,0.5)
        half = smooth.apply(live,0.5,0.5)['presence']
        self.assertAlmostEqual(half,1-2.718281828**-1,places=5)

    def test_malformed_packet_never_mutates_published_snapshot(self):
        self.send(1, 'objectDetection')
        snapshot = self.r.current
        box = list(snapshot['detections'][0])
        version, received = self.r.version, self.r.last_result
        self.r.receive('/mediapipe/objectDetection/detection/0', ['broken', .4])
        self.assertEqual(self.r.invalid, 1)
        self.assertEqual(snapshot['detections'][0], box)
        self.assertIs(self.r.current, snapshot)
        self.assertEqual((self.r.version, self.r.last_result), (version, received))

    def test_invalid_chunks_are_atomic_and_indices_are_bounded(self):
        self.r.receive('/mediapipe/frame', [1])
        root = '/mediapipe/faceLandmarkDetection'
        self.r.receive(root+'/landmarks/0/count', [2])
        self.r.receive(root+'/landmarks/0/points', [0, .1, .2])
        for path, args in [('/landmarks/0/points', [1, .3, float('nan')]),
                           ('/landmarks/0/count', [-1]),
                           ('/landmarks/0/points', [1999, .1, .2, .3, .4]),
                           ('/landmarks/-1/count', [1]),
                           ('/landmarks/2000/count', [1]),
                           ('/embedding/values', [8191, .1, .2]),
                           ('/category/-1', ['bad', .9]),
                           ('/hand/2000/handedness', ['Right', .9])]:
            self.r.receive(root+path, args)
        group = self.r.frames['faceLandmarkDetection']['groups'][0]
        self.assertEqual(group, dict(count=2, points={0: (.1, .2)}, label=''))
        self.assertEqual(self.r.invalid, 8)
        self.r.receive(root+'/counts', [1, 0, 1])
        self.r.receive(root+'/inferenceMs', [1.0])
        self.assertIsNone(self.r.current)
        self.r.receive(root+'/landmarks/0/points', [1, .3, .4])
        self.assertEqual(len(points(self.r.current)), 2)

    def test_counts_prune_extras_received_before_and_after_metadata(self):
        self.r.receive('/mediapipe/frame', [1])
        root = '/mediapipe/objectDetection'
        for index in range(3000):
            self.r.receive(root+'/detection/'+str(index), ['cup', .5, 0, 0, .1, .1])
        self.assertEqual(len(self.r.frames['objectDetection']['detections']), 2000)
        self.r.receive(root+'/counts', [1, 1, 0])
        self.r.receive(root+'/detection/100', ['extra', .9, 0, 0, .1, .1])
        self.assertEqual(set(self.r.frames['objectDetection']['detections']), {0})
        self.r.receive(root+'/inferenceMs', [1.0])
        self.assertEqual(set(self.r.current['detections']), {0})

    def test_reordered_chunks_before_counts_complete_same_frame(self):
        self.r.receive('/mediapipe/frame', [1])
        root = '/mediapipe/faceLandmarkDetection'
        for path, args in [('/landmarks/0/points', [1, .3, .4, .8, .9]),
                           ('/landmarks/1/count', [1]),
                           ('/landmarks/0/label', ['face']),
                           ('/landmarks/0/count', [2]),
                           ('/counts', [1, 0, 1]), ('/inferenceMs', [1.0])]:
            self.r.receive(root+path, args)
        self.assertIsNone(self.r.current)
        self.r.receive('/mediapipe/frame', [1])  # another bundle for this frame
        self.r.receive(root+'/landmarks/0/points', [0, .1, .2])
        snapshot = self.r.current
        self.assertEqual(set(snapshot['groups']), {0})
        self.assertEqual(set(snapshot['groups'][0]['points']), {0, 1})
        self.now = .5
        version = self.r.version
        self.r.receive(root+'/landmarks/0/points', [0, .9, .9])
        self.assertEqual(snapshot['groups'][0]['points'][0], (.1, .2))
        self.assertEqual(self.r.version, version)
        self.assertEqual(self.r.last_result, 0)

    def test_expired_and_stopped_frames_cannot_be_resurrected(self):
        self.send(1, 'objectDetection')
        self.now = .7
        self.r.receive('/mediapipe/test', ['keep source'])
        self.now = 1.1
        self.r.tick()
        self.send(1, 'objectDetection')
        self.assertIsNone(self.r.current)
        self.send(2, 'objectDetection')
        self.assertEqual(self.r.current['frame'], 2)
        self.r.receive('/mediapipe/objectDetection/active', [0])
        self.send(2, 'objectDetection')
        self.assertIsNone(self.r.current)
        self.send(3, 'objectDetection')
        self.assertEqual(self.r.current['frame'], 3)

    def test_embedding_reordering_trims_extras_and_bad_dimensions_roll_back(self):
        self.r.receive('/mediapipe/frame', [1])
        root = '/mediapipe/imageEmbedding'
        self.r.receive(root+'/embedding/values', [1, .2, .3, .4])
        self.r.receive(root+'/embedding/dimensions', [3])
        self.r.receive(root+'/embedding/dimensions', [-1])
        self.assertEqual(self.r.frames['imageEmbedding']['embedding_size'], 3)
        self.r.receive(root+'/counts', [1, 0, 0])
        self.r.receive(root+'/inferenceMs', [1.0])
        self.assertIsNone(self.r.current)
        self.r.receive(root+'/embedding/values', [0, .1])
        self.assertEqual(self.r.current['embedding'], {0: .1, 1: .2, 2: .3})

    def test_total_staged_landmark_budget_is_bounded(self):
        self.r.receive('/mediapipe/frame', [1])
        root = '/mediapipe/holisticLandmarkDetection'
        for group in range(5):
            self.r.receive(root+'/landmarks/'+str(group)+'/points', [0]+[.5]*4000)
        frame = self.r.frames['holisticLandmarkDetection']
        self.assertEqual(sum(len(g['points']) for g in frame['groups'].values()), 8000)
        self.assertNotIn(4, frame['groups'])
        self.assertEqual(self.r.invalid, 1)

    def test_first_score_uses_protocol_index_not_arrival_order(self):
        for task, route, counts in [('objectDetection', 'detection', [2, 2, 0]),
                                    ('imageClassification', 'category', [2, 0, 0])]:
            self.r = ReceiverState(clock=lambda: self.now)
            self.r.receive('/mediapipe/frame', [1])
            root = '/mediapipe/'+task
            self.r.receive(root+'/counts', counts)
            self.r.receive(root+'/inferenceMs', [1.0])
            for index, score in [(1, .2), (0, .9)]:
                args = ['label', score] + ([0, 0, .1, .1] if route == 'detection' else [])
                self.r.receive(root+'/'+route+'/'+str(index), args)
            self.assertEqual(controls(self.r.current)['first_score'], .9)

    def test_hold_survives_empty_live_frames_and_unrelated_tasks(self):
        self.send(1, 'handLandmarkDetection')
        f = OutputFilter()
        live = f.apply(controls(self.r.current), 0, hold=True)
        self.r.receive('/mediapipe/frame', [2])
        root = '/mediapipe/handLandmarkDetection'
        self.r.receive(root+'/counts', [0, 0, 0])
        self.r.receive(root+'/inferenceMs', [1.0])
        empty = f.apply(controls(self.r.current), 1, hold=True)
        self.assertEqual((empty['active'], empty['point_found'], empty['present']), (1, 0, 0))
        for key in ('point_x', 'point_y', 'hand_x', 'hand_y', 'pinch_distance'):
            self.assertEqual(empty[key], live[key])
        self.send(3, 'objectDetection')
        unrelated = f.apply(controls(self.r.current), 1, hold=True)
        self.assertEqual(unrelated['hand_x'], live['hand_x'])
        self.assertEqual(f.apply(controls(None), 1, hold=True)['point_x'], live['point_x'])

    def test_frame_markers_require_one_positive_int32(self):
        self.send(10, 'objectDetection')
        snapshot = self.r.current
        for args in ([], [11, 12], [0], [-1], [2147483648], [11.5], ['11'], [True]):
            self.r.receive('/mediapipe/frame', args)
            self.assertIsNone(self.r.context)
            self.assertEqual(self.r.last_frame, 10)
            self.assertIs(self.r.current, snapshot)
        self.assertEqual(self.r.invalid, 8)
        self.send(11, 'objectDetection')
        self.assertEqual(self.r.current['frame'], 11)

    def test_metadata_arity_and_labels_are_validated_before_state_changes(self):
        self.r.receive('/mediapipe/frame', [1])
        root = '/mediapipe/faceLandmarkDetection'
        self.r.receive(root+'/landmarks/0/count', [2])
        self.r.receive(root+'/landmarks/0/points', [0, .1, .2])
        assembly = self.r.frames['faceLandmarkDetection']
        for path, args in [('/counts', [1, 0, 1, 999]), ('/inferenceMs', [1, 2]),
                           ('/landmarks/0/count', [1, 2]),
                           ('/landmarks/0/label', ['face', 'extra']),
                           ('/landmarks/0/label', ['x'*1025]),
                           ('/landmarks/0/label', [123]),
                           ('/embedding/dimensions', [3, 4]),
                           ('/mask/size', [16, 16, 16]),
                           ('/mask/coverage', [.1, .2]),
                           ('/active', [0, 1]), ('/active', [2]),
                           ('/category/0', ['label', .9, 99]),
                           ('/hand/0/handedness', ['Right', .9, 99])]:
            self.r.receive(root+path, args)
            self.assertIs(self.r.frames['faceLandmarkDetection'], assembly)
        self.assertEqual(self.r.invalid, 13)
        self.assertEqual(assembly['groups'][0], dict(count=2, points={0: (.1, .2)}, label=''))

    def test_standalone_demo_uses_the_receiver_task_names(self):
        self.assertEqual(DEMO_TASKS,TASKS)

    def test_demo_uses_mtu_safe_osc_bundles(self):
        for task in TASKS:
            for packet in packets(1,sample(task,1)):
                self.assertLessEqual(len(packet),1200)
                self.assertEqual(len(packet)%4,0)
                self.assertEqual(packet[:8],b'#bundle\0')

if __name__=='__main__': unittest.main()

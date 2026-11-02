import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'demo'))
from osc_protocol import ReceiverState, TASKS, OutputFilter, controls, points, find_point, convert, TRACK_POINTS
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

    def test_standalone_demo_uses_the_receiver_task_names(self):
        self.assertEqual(DEMO_TASKS,TASKS)

    def test_demo_uses_mtu_safe_osc_bundles(self):
        for task in TASKS:
            for packet in packets(1,sample(task,1)):
                self.assertLessEqual(len(packet),1200)
                self.assertEqual(len(packet)%4,0)
                self.assertEqual(packet[:8],b'#bundle\0')

if __name__=='__main__': unittest.main()

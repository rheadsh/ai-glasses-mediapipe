import unittest
from osc_protocol import ReceiverState, TASKS
from demo_sender import sample, packets

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

    def test_demo_uses_mtu_safe_osc_bundles(self):
        for task in TASKS:
            for packet in packets(1,sample(task,1)):
                self.assertLessEqual(len(packet),1200)
                self.assertEqual(len(packet)%4,0)
                self.assertEqual(packet[:8],b'#bundle\0')

if __name__=='__main__': unittest.main()

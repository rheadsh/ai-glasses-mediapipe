import hashlib
import io
from pathlib import Path
import plistlib
from contextlib import redirect_stdout
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
from validate_resources import model_pins, verify_models, verify_dependencies, verify_release, ROOT


class ResourceValidationTests(unittest.TestCase):
    def test_repository_has_twelve_unique_pins(self):
        pins = model_pins((ROOT / 'mediapipe-ios/Scripts/download_models.sh').read_text())
        self.assertEqual(len(pins), 12)

    def test_incomplete_pin_catalog_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exactly 12'):
            model_pins('download_model "unpinned.tflite" "https://example.invalid"')

    def test_model_mismatch_and_missing_model_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / 'test.task'
            model.write_bytes(b'original')
            pins = {'test.task': hashlib.sha256(b'original').hexdigest()}
            verify_models(root, pins)
            model.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                verify_models(root, pins)
            model.unlink()
            with self.assertRaises(FileNotFoundError):
                verify_models(root, pins)

    def test_dependency_pins_in_repository_agree(self):
        verify_dependencies(ROOT / 'mediapipe-ios')


class ReleaseDATValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name)
        self.dat = {'MetaAppID': '0', 'AppLinkURLScheme': 'mediapipe-ios://',
                    'TeamID': 'TESTTEAM01', 'ClientToken': ''}
        # Only the platform-specific executable inspection is mocked. Plist parsing
        # and DAT validation run through the real Release entry point on any OS.
        self.otool = patch('validate_resources.subprocess.run',
                           return_value=SimpleNamespace(stdout='app:\n/usr/lib/libSystem.B.dylib\n'))
        self.otool.start()
        self.addCleanup(self.otool.stop)

    def check_release(self, dat):
        info = {'CFBundleExecutable': 'app', 'MWDAT': dat}
        with (self.app / 'Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
        self.output = io.StringIO()
        with redirect_stdout(self.output):
            verify_release(self.app, {})
        return self.output.getvalue()

    def test_incomplete_dat_configuration_is_rejected_before_success_output(self):
        configurations = [{'TeamID': 'example'}]
        configurations += [{key: value for key, value in self.dat.items() if key != missing}
                           for missing in self.dat]
        for dat in configurations:
            with self.subTest(keys=list(dat)):
                with self.assertRaisesRegex(ValueError, 'DAT configuration'):
                    self.check_release(dat)
                self.assertEqual(self.output.getvalue(), '')

    def test_developer_mode_allows_an_explicit_empty_client_token(self):
        output = self.check_release(self.dat)
        self.assertIn('Developer Mode (MetaAppID=0)', output)

    def test_invalid_dat_values_are_rejected_without_exposing_credentials(self):
        for key, value in [('MetaAppID', ''), ('MetaAppID', 'invalid'),
                           ('MetaAppID', 0), ('TeamID', ' '),
                           ('AppLinkURLScheme', 'other-app://'),
                           ('ClientToken', '$(CLIENT_TOKEN)')]:
            with self.subTest(key=key, value=value):
                dat = dict(self.dat, **{key: value})
                with self.assertRaisesRegex(ValueError, 'DAT configuration') as error:
                    self.check_release(dat)
                self.assertNotIn('$(CLIENT_TOKEN)', str(error.exception))
        with self.assertRaisesRegex(ValueError, 'DAT configuration'):
            self.check_release(['invalid'])

    def test_nonzero_app_id_requires_a_client_token(self):
        dat = dict(self.dat, MetaAppID='123')
        with self.assertRaisesRegex(ValueError, 'DAT configuration'):
            self.check_release(dat)
        dat['ClientToken'] = 'synthetic-test-token'
        output = self.check_release(dat)
        self.assertIn('nonzero MetaAppID', output)
        self.assertNotIn(dat['ClientToken'], output)


if __name__ == '__main__':
    unittest.main()

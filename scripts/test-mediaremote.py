#!/usr/bin/env python3
"""Compile/run the real native helper against fakes. Never controls live players."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/MediaRemoteAdapter'

class NativeMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='captur-native-tests-')
        cls.commands = Path(cls.temp.name) / 'commands'
        cls.query = Path(cls.temp.name) / 'query'
        common = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-objc-property-implementation',
                  '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'CoreAudio',
                  '-I' + str(VENDOR / 'src'), '-I' + str(VENDOR / 'include'),
                  str(ROOT / 'scripts/tests/mediaremote_harness.m')]
        subprocess.run(common + [str(ROOT / 'Sources/Modules/Audio/MediaRemoteHelper/CapturMediaCommands.m'),
                                 '-o', str(cls.commands)], check=True)
        subprocess.run(common + ['-DTEST_GET', str(VENDOR / 'src/adapter/get.m'),
                                 str(VENDOR / 'src/adapter/keys.m'), '-o', str(cls.query)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def command(self, mode, command='pause', valid=True):
        permit = Path(self.temp.name) / 'permit'
        permit.unlink(missing_ok=True)
        if valid:
            permit.touch()
        env = dict(os.environ, CAPTUR_MEDIA_COMMAND=command, CAPTUR_MEDIA_PERMIT=str(permit),
                   CAPTUR_MEDIA_ALLOWED_BUNDLES='["com.apple.Music"]',
                   CAPTUR_MEDIA_IDENTITY='{"bundleIdentifier":"com.apple.Music","processIdentifier":123,"title":"Track"}')
        return subprocess.run([str(self.commands), mode], env=env, capture_output=True, text=True, timeout=9)

    def test_delayed_pause_confirms_without_resending(self):
        result = self.command('delayed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['playing'])
        self.assertEqual(result.stderr.count('SENT'), 1)

    def test_delayed_play_confirms_without_resending(self):
        result = self.command('delayed', 'play')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['playing'])
        self.assertEqual(result.stderr.count('SENT'), 1)

    def test_unchanged_state_expires_without_resending(self):
        result = self.command('unchanged')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count('SENT'), 1)

    def test_changed_media_abandons_confirmation(self):
        result = self.command('changed')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count('SENT'), 1)

    def test_revocation_during_query_prevents_dispatch(self):
        result = self.command('revoke')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SENT', result.stderr)

    def test_revocation_after_dispatch_still_confirms_owned_pause(self):
        result = self.command('revoke-after')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['playing'])
        self.assertEqual(result.stderr.count('SENT'), 1)

    def test_missing_permit_prevents_dispatch(self):
        result = self.command('delayed', valid=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SENT', result.stderr)

    def test_query_timeout_is_failure(self):
        result = subprocess.run([str(self.query), 'timeout'], capture_output=True, text=True, timeout=4)
        self.assertNotEqual(result.returncode, 0)

    def test_empty_session_remains_successful_null(self):
        result = subprocess.run([str(self.query), 'empty'], capture_output=True, text=True, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout))

if __name__ == '__main__':
    unittest.main()

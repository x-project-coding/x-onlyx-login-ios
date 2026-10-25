import os
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent

class ReleaseProductTests(unittest.TestCase):
    def test_white_label_identity_does_not_accept_onlyx_artifacts(self):
        with patch.dict(os.environ, {"LOGIN_PRODUCT": "white-label"}):
            release = runpy.run_path(str(HERE / "release-signing.py"))
        self.assertEqual(release['BUNDLE'], 'ai.onlyx.whitelabel.login')
        self.assertEqual(release['EXECUTABLE'], 'Login')
        self.assertEqual(release['ENTITLEMENTS']['application-identifier'], 'Y5NUN99S3X.ai.onlyx.whitelabel.login')
        info = {'CFBundleIdentifier': 'ai.onlyx.whitelabel.login', 'CFBundleExecutable': 'Login',
                'UIDeviceFamily': [1], 'MinimumOSVersion': '17.0', 'ITSAppUsesNonExemptEncryption': False,
                'CFBundleURLTypes': [{'CFBundleURLSchemes': ['secure-connect']}],
                'NSCameraUsageDescription': 'Identity check', 'NSMicrophoneUsageDescription': 'Identity check'}
        self.assertEqual(release['app_errors'](info), [])
        info['CFBundleIdentifier'] = 'ai.onlyx.login'
        self.assertTrue(release['app_errors'](info))
        info['CFBundleIdentifier'] = 'ai.onlyx.whitelabel.login'
        info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] = ['onlyx-connect']
        self.assertTrue(release['app_errors'](info))

    def test_unknown_product_cannot_select_an_arbitrary_identity(self):
        with patch.dict(os.environ, {"LOGIN_PRODUCT": "unknown"}), self.assertRaises(ValueError):
            runpy.run_path(str(HERE / 'release-product.py'))

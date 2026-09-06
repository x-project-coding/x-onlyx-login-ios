"""Prevent a recurrence of compiling the App Store binary on the beta host."""
from pathlib import Path
import runpy
import unittest

check = runpy.run_path(str(Path(__file__).with_name("check-build-environment.py")))["environment_errors"]


class BuildEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.environment = {
            "host_version": "26.5.2", "host_build": "25F205",
            "xcode_version": "26.6", "xcode_build": "17F113",
            "ios_sdk_version": "26.5", "ios_sdk_build": "23F81a",
        }

    def test_supported_release_host_and_sdk_build_suffix_are_accepted(self):
        self.assertEqual(check(self.environment), [])

    def test_original_macOS_27_beta_host_is_rejected_with_stable_xcode(self):
        self.environment.update(host_version="27.0", host_build="26A5421a")
        self.assertEqual(len(check(self.environment)), 2)

    def test_host_support_boundaries(self):
        for version in ("26.2", "26.2.1", "26.6"):
            with self.subTest(version=version):
                self.assertEqual(check({**self.environment, "host_version": version}), [])
        for version in ("26.1.9", "25.6", "27.0", "26.2 beta", "unknown"):
            with self.subTest(version=version):
                self.assertTrue(check({**self.environment, "host_version": version}))

    def test_beta_host_same_major_is_rejected(self):
        self.assertTrue(check({**self.environment, "host_build": "25G5000a"}))

    def test_unapproved_or_beta_toolchain_is_rejected(self):
        for key, value in (("xcode_version", "27.0 beta 6"), ("xcode_build", "17F100a"),
                           ("ios_sdk_version", "27.0"), ("ios_sdk_build", "")):
            with self.subTest(key=key):
                self.assertTrue(check({**self.environment, key: value}))

    def test_missing_metadata_fails(self):
        self.assertTrue(check({}))


if __name__ == "__main__":
    unittest.main()

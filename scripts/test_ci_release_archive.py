import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
import zipfile


SPEC = importlib.util.spec_from_file_location("ci_release_archive", Path(__file__).with_name("ci-release-archive.py"))
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class ReleaseArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / "OnlyXLogin-4-unsigned.xcarchive"
        self.app = self.archive / "Products/Applications/OnlyX Login.app"
        self.app.mkdir(parents=True)
        self.environment = {"host_build": "25F84", "xcode_build": "17F113",
                            "ios_sdk_version": "26.5", "ios_sdk_build": "23F81a"}
        self.info = {"CFBundleIdentifier": "ai.onlyx.login", "CFBundleVersion": "4",
                     "CFBundleExecutable": "OnlyX Login", "UIDeviceFamily": [1],
                     "BuildMachineOSBuild": "25F84", "DTXcodeBuild": "17F113",
                     "DTSDKName": "iphoneos26.5", "DTSDKBuild": "23F81a"}
        self.write_info()
        with (self.archive / "Info.plist").open("wb") as stream:
            plistlib.dump({"ApplicationProperties": {"ApplicationPath": "Applications/OnlyX Login.app"}}, stream)

    def write_info(self):
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def test_requires_positive_decimal_input(self):
        self.assertEqual(ci.positive_build_number("4"), "4")
        for value in ("", "0", "-1", "4.1", "04", "4\n", " 4", "4; touch bad", "٤"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                ci.positive_build_number(value)

    def test_matching_compiler_metadata_is_read_without_modification(self):
        before = (self.app / "Info.plist").read_bytes()
        metadata = ci.archive_metadata(self.archive, "4", self.environment)
        self.assertEqual(metadata["BuildMachineOSBuild"], "25F84")
        self.assertEqual((self.app / "Info.plist").read_bytes(), before)

    def test_wrong_host_sdk_build_bundle_or_executable_is_rejected(self):
        for key, value in (("BuildMachineOSBuild", "26A5421a"), ("DTXcodeBuild", "27A100"),
                           ("DTSDKName", "iphonesimulator26.5"), ("DTSDKBuild", "other"),
                           ("CFBundleVersion", "3"), ("CFBundleIdentifier", "ai.onlyx.other"),
                           ("CFBundleExecutable", "Other"), ("UIDeviceFamily", [1, 2])):
            with self.subTest(key=key):
                previous = self.info[key]
                self.info[key] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    ci.archive_metadata(self.archive, "4", self.environment)
                self.info[key] = previous

    def test_generic_archive_rejected(self):
        with (self.archive / "Info.plist").open("wb") as stream:
            plistlib.dump({}, stream)
        with self.assertRaises(ValueError):
            ci.archive_metadata(self.archive, "4", self.environment)

    def test_provisioned_or_signed_archive_rejected(self):
        for name in ("embedded.mobileprovision", "_CodeSignature"):
            with self.subTest(name=name):
                path = self.app / name
                path.touch()
                with self.assertRaises(ValueError):
                    ci.archive_metadata(self.archive, "4", self.environment)
                path.unlink()

    @unittest.skipUnless(shutil.which("ditto"), "macOS ditto required")
    def test_real_zip_preserves_symlink_executable_and_archive_root(self):
        executable = self.app / "OnlyX Login"
        executable.write_bytes(b"synthetic executable fixture\n")
        executable.chmod(0o755)
        (self.app / "Alias").symlink_to("OnlyX Login")
        destination = Path(self.temp.name) / "artifact.zip"
        digest = ci.package_archive(self.archive, destination)
        self.assertEqual(digest, ci.sha256(destination))
        with zipfile.ZipFile(destination) as archive_zip:
            member = archive_zip.getinfo(self.archive.name + "/Products/Applications/OnlyX Login.app/Alias")
            self.assertTrue(stat.S_ISLNK(member.external_attr >> 16))
        extracted = Path(self.temp.name) / "extracted"
        ci.run("ditto", "-x", "-k", str(destination), str(extracted))
        app = extracted / self.archive.name / "Products/Applications/OnlyX Login.app"
        self.assertEqual(os.readlink(app / "Alias"), "OnlyX Login")
        self.assertEqual((app / "OnlyX Login").read_bytes(), executable.read_bytes())
        self.assertTrue(os.access(app / "OnlyX Login", os.X_OK))


if __name__ == "__main__":
    unittest.main()

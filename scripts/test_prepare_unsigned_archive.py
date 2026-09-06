import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("prepare_archive", Path(__file__).with_name("prepare-unsigned-archive.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "Unsigned.xcarchive"
        self.output = self.root / "Signed.xcarchive"
        self.app = self.source / helper.APP_PATH
        self.app.mkdir(parents=True)
        self.info = {
            "CFBundleIdentifier": helper.BUNDLE, "CFBundleExecutable": "OnlyX Login", "UIDeviceFamily": [1],
            "CFBundleVersion": "4", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "15.0", "ITSAppUsesNonExemptEncryption": False,
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["onlyx-connect"]}],
            "NSCameraUsageDescription": "Selfie verification.", "NSMicrophoneUsageDescription": "Identity video sound.",
            "BuildMachineOSBuild": "25F80", "DTXcode": "2660", "DTXcodeBuild": "17F113",
            "DTSDKName": "iphoneos26.5", "DTSDKBuild": "23F81a", "DTPlatformBuild": "23F81a",
            "DTPlatformName": "iphoneos", "DTPlatformVersion": "26.5",
        }
        self.write_info()
        metadata = {"ArchiveVersion": 2, "ApplicationProperties": {
            "ApplicationPath": "Applications/OnlyX Login.app", "CFBundleIdentifier": helper.BUNDLE,
            "CFBundleVersion": "4", "CFBundleShortVersionString": "1.0",
        }}
        (self.source / "Info.plist").write_bytes(plistlib.dumps(metadata))
        (self.app / "OnlyX Login").write_bytes(struct.pack("<IiiIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 0, 0, 0, 0))
        (self.app / "OnlyX Login").chmod(0o755)
        (self.app / "PrivacyInfo.xcprivacy").write_bytes(b"original resource")
        self.environment = {"valid": True, "errors": [], "environment": {
            "host_version": "26.5", "host_build": "25F80", "xcode_version": "26.6",
            "xcode_build": "17F113", "ios_sdk_version": "26.5", "ios_sdk_build": "23F81a",
        }}
        self.environment_path = self.root / "build-environment.json"
        self.environment_path.write_text(json.dumps(self.environment))
        certificate = b"synthetic certificate for mocked signing only"
        self.digest = hashlib.sha1(certificate).hexdigest().upper()
        self.identity = "Apple Distribution: Test Owner (Y5NUN99S3X)"
        profile_entitlements = copy.deepcopy(helper.ENTITLEMENTS)
        profile_entitlements["keychain-access-groups"] = ["Y5NUN99S3X.*", "com.apple.token"]
        self.profile = {"Name": "OnlyX Login App Store", "UUID": "test-profile", "TeamIdentifier": [helper.TEAM], "Platform": ["iOS"],
                        "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=30),
                        "DeveloperCertificates": [certificate], "Entitlements": profile_entitlements}
        self.profile_path = self.root / "Store.mobileprovision"
        self.profile_path.write_bytes(b"synthetic CMS input for mock only")
        self.calls = []

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def command(self, args, *, data=None):
        self.calls.append(args)
        if args[:3] == ["security", "cms", "-D"]:
            self.assertEqual(data, self.profile_path.read_bytes())
            return plistlib.dumps(self.profile)
        if args[:2] == ["security", "find-identity"]:
            return f'  1) {self.digest} "{self.identity}"\n'.encode()
        if args[:2] == ["codesign", "--force"]:
            app = Path(args[-1])
            self.assertNotEqual(app, self.app)
            self.assertEqual(plistlib.loads(Path(args[args.index("--entitlements") + 1]).read_bytes()), helper.ENTITLEMENTS)
            (app / "OnlyX Login").write_bytes(b"mock signed executable")
            (app / "_CodeSignature").mkdir()
            (app / "_CodeSignature/CodeResources").write_bytes(b"mock resource seal")
            return b""
        if args[:2] == ["codesign", "--display"]:
            return plistlib.dumps(helper.ENTITLEMENTS)
        raise AssertionError(args)

    def prepare(self, command=None, blockers=None):
        with patch.object(helper, "run", command or self.command), patch.dict(helper.validation, {
            "verify": (lambda *args: ((blockers(*args) if blockers else []), {}, {}))
        }):
            return helper.prepare(self.source, self.output, self.profile_path, self.identity, self.environment_path)

    def test_success_preserves_source_provenance_resources_and_exact_default_keychain(self):
        before = helper.inventory(self.source)
        result = self.prepare()
        self.assertTrue(result["prepared"])
        self.assertFalse(result["uploaded"])
        self.assertEqual(helper.inventory(self.source), before)
        self.assertEqual(plistlib.loads((self.output / helper.APP_PATH / "Info.plist").read_bytes()), self.info)
        self.assertEqual((self.output / helper.APP_PATH / "PrivacyInfo.xcprivacy").read_bytes(), b"original resource")
        properties = plistlib.loads((self.output / "Info.plist").read_bytes())["ApplicationProperties"]
        self.assertEqual(properties["SigningIdentity"], self.identity)
        self.assertEqual(properties["Team"], helper.TEAM)
        self.assertEqual(result["entitlements"]["keychain-access-groups"], [helper.TEAM + "." + helper.BUNDLE])
        self.assertNotIn("com.apple.token", result["entitlements"]["keychain-access-groups"])
        self.assertNotIn("aps-environment", result["entitlements"])
        self.assertNotIn("com.apple.developer.applesignin", result["entitlements"])

    def test_noncode_swift_resource_bundle_is_preserved_but_embedded_code_rejected(self):
        bundle = self.app / "OnlyXLoginCore.bundle"
        bundle.mkdir()
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "OnlyXLoginCore"}))
        self.prepare()
        self.assertEqual((self.output / helper.APP_PATH / bundle.name / "Info.plist").read_bytes(), (bundle / "Info.plist").read_bytes())
        (bundle / "HiddenCode").write_bytes((self.app / "OnlyX Login").read_bytes())
        with self.assertRaisesRegex(ValueError, "another executable"):
            helper.check_archive(self.source, self.environment)

    def test_unrelated_capabilities_are_never_permitted_in_signature(self):
        for key, value in (("aps-environment", "production"), ("com.apple.developer.applesignin", ["Default"])):
            with self.subTest(key=key):
                entitlements = copy.deepcopy(helper.ENTITLEMENTS)
                entitlements[key] = value
                self.profile["Entitlements"][key] = value
                self.assertTrue(helper.validation["profile_errors"](self.profile, entitlements))

    def test_strict_verifier_checks_certificate_membership_and_apple_trust(self):
        calls = []
        certificate = self.profile["DeveloperCertificates"][0]
        def command(args, **kwargs):
            calls.append(args)
            output = b""
            if args[:3] == ["codesign", "--display", "--entitlements"]:
                output = plistlib.dumps(helper.ENTITLEMENTS)
            elif args[:3] == ["security", "cms", "-D"]:
                output = plistlib.dumps(self.profile)
            elif args[:2] == ["codesign", "--display"]:
                prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--extract-certificates="))
                Path(prefix + "0").write_bytes(certificate)
            return subprocess.CompletedProcess(args, 0, output, b"")
        with patch("subprocess.run", command):
            errors, _, _ = helper.validation["verify"](self.app, self.info)
            self.assertEqual(errors, [])
            self.profile["DeveloperCertificates"] = [b"another certificate"]
            errors, _, _ = helper.validation["verify"](self.app, self.info)
            self.assertTrue(any("not authorized" in error for error in errors))
        self.assertTrue(any(args[:3] == ["security", "verify-cert", "-p"] for args in calls))
        self.assertTrue(any(any(arg.startswith("-R=anchor apple generic") for arg in args) for args in calls))
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "codesign")):
            self.assertTrue(helper.validation["verify"](self.app, self.info)[0])

    def test_existing_alias_nested_and_dangling_output_paths_are_rejected(self):
        existing = self.root / "Existing.xcarchive"
        existing.mkdir()
        alias = self.root / "Alias.xcarchive"
        alias.symlink_to(self.source, target_is_directory=True)
        dangling = self.root / "Dangling.xcarchive"
        dangling.symlink_to(self.root / "Missing.xcarchive")
        for output in (self.source, existing, alias, dangling, self.source / "Nested.xcarchive"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                helper.paths(self.source, output)
        self.assertTrue(existing.is_dir())

    def test_external_symlink_and_missing_executable_mode_are_rejected(self):
        link = self.app / "Outside"
        link.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.prepare()
        link.unlink()
        (self.app / "OnlyX Login").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "mode"):
            self.prepare()
        self.assertEqual(self.calls, [])

    def test_beta_or_mismatched_provenance_stops_before_signing(self):
        for changes in ({"host_version": "27.0", "host_build": "26A5421a"}, {"host_build": "25F81"},
                        {"xcode_build": "27A5252f"}, {"ios_sdk_build": "different"}):
            with self.subTest(changes=changes):
                report = copy.deepcopy(self.environment)
                report["environment"].update(changes)
                self.environment_path.write_text(json.dumps(report))
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())
        self.assertEqual(self.calls, [])

    def test_signed_or_embedded_code_archive_is_rejected(self):
        for file in (self.app / "embedded.mobileprovision", self.app / "Extension.appex"):
            with self.subTest(file=file):
                file.write_bytes(b"not supported")
                with self.assertRaises(ValueError):
                    self.prepare()
                file.unlink()
        self.assertEqual(self.calls, [])

    def test_wrong_expired_adhoc_profile_capability_and_certificate_are_rejected(self):
        mutations = [
            lambda p: p.update(TeamIdentifier=["OTHERTEAM0"]),
            lambda p: p.update(Platform=["macOS"]),
            lambda p: p.update(ExpirationDate=datetime(2020, 1, 1)),
            lambda p: p.update(ProvisionedDevices=["device"]),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p["Entitlements"].update({"beta-reports-active": False}),
            lambda p: p["Entitlements"].update({"keychain-access-groups": ["OTHER.*"]}),
            lambda p: p.update(DeveloperCertificates=[b"different certificate"]),
        ]
        original = copy.deepcopy(self.profile)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.profile = copy.deepcopy(original)
                mutation(self.profile)
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())
        self.assertFalse(any(args[0] == "codesign" for args in self.calls))

    def test_signing_failure_removes_only_new_output(self):
        before = helper.inventory(self.source)
        def command(args, **kwargs):
            if args[0] == "codesign":
                raise ValueError("signing failed")
            return self.command(args, **kwargs)
        with self.assertRaisesRegex(ValueError, "signing failed"):
            self.prepare(command)
        self.assertFalse(self.output.exists())
        self.assertEqual(helper.inventory(self.source), before)

    def test_signing_must_not_change_info_or_resources(self):
        for target in ("Info.plist", "PrivacyInfo.xcprivacy"):
            with self.subTest(target=target):
                def command(args, **kwargs):
                    response = self.command(args, **kwargs)
                    if args[:2] == ["codesign", "--force"]:
                        file = Path(args[-1]) / target
                        if target == "Info.plist":
                            info = plistlib.loads(file.read_bytes())
                            info["BuildMachineOSBuild"] = "forged"
                            file.write_bytes(plistlib.dumps(info))
                        else:
                            file.write_bytes(b"changed")
                    return response
                with self.assertRaisesRegex(ValueError, "changed"):
                    self.prepare(command)
                self.assertFalse(self.output.exists())

    def test_missing_signed_capabilities_or_strict_trust_failure_are_not_success(self):
        def command(args, **kwargs):
            if args[:2] == ["codesign", "--display"]:
                return plistlib.dumps({"application-identifier": helper.TEAM + "." + helper.BUNDLE})
            return self.command(args, **kwargs)
        with self.assertRaisesRegex(ValueError, "allowlist"):
            self.prepare(command)
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ValueError, "untrusted"):
            self.prepare(blockers=lambda *args: ["untrusted signing certificate"])
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

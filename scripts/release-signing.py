#!/usr/bin/env python3
"""Local OnlyX Login distribution checks. No uploads or key export.

Certificate trust uses the system store and cached revocation information;
App Store Connect validation is still required.
"""
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile

TEAM = "Y5NUN99S3X"
BUNDLE = "ai.onlyx.login"
EXECUTABLE = "OnlyX Login"
APP_PATH = Path("Products/Applications/OnlyX Login.app")
ENTITLEMENTS = {
    "application-identifier": TEAM + "." + BUNDLE,
    "com.apple.developer.team-identifier": TEAM,
    "get-task-allow": False,
    "beta-reports-active": True,
    "keychain-access-groups": [TEAM + "." + BUNDLE],
}


def profile_errors(profile, entitlements):
    errors = []
    if entitlements != ENTITLEMENTS:
        errors.append("Signature must contain exactly the OnlyX Login release entitlements.")
    if not isinstance(profile, dict):
        return errors + ["Invalid provisioning profile."]
    if profile.get("TeamIdentifier") != [TEAM] or "iOS" not in profile.get("Platform", []):
        errors.append("Expected the OnlyX team and an iOS provisioning profile.")
    if profile.get("ProvisionedDevices") is not None or profile.get("ProvisionsAllDevices"):
        errors.append("An App Store distribution profile is required.")
    expiration = profile.get("ExpirationDate")
    if isinstance(expiration, datetime) and expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if not isinstance(expiration, datetime) or expiration <= datetime.now(timezone.utc):
        errors.append("Provisioning profile is expired or invalid.")
    if not isinstance(profile.get("UUID"), str) or not profile["UUID"]:
        errors.append("Provisioning profile UUID is missing.")
    allowed = profile.get("Entitlements", {})
    if not isinstance(allowed, dict):
        return errors + ["Invalid provisioning entitlements."]
    for key, expected in ENTITLEMENTS.items():
        if key == "keychain-access-groups":
            groups = allowed.get(key, [])
            authorized = isinstance(groups, list) and any(
                isinstance(group, str) and (group == expected[0] or (
                    group.endswith("*") and group.count("*") == 1 and expected[0].startswith(group[:-1])
                )) for group in groups)
            if not authorized:
                errors.append("Profile does not authorize the explicit default Keychain group.")
        elif type(allowed.get(key)) is not type(expected) or allowed.get(key) != expected:
            errors.append("Profile does not authorize release entitlement: " + key)
    return errors


def provenance_errors(info, report):
    if not isinstance(report, dict) or report.get("valid") is not True or report.get("errors") != []:
        return ["CI environment report did not pass the release gate."]
    environment = report.get("environment")
    keys = ("host_version", "host_build", "xcode_version", "xcode_build", "ios_sdk_version", "ios_sdk_build")
    if not isinstance(environment, dict) or any(not isinstance(environment.get(key), str) for key in keys):
        return ["CI environment identities must be strings."]
    checker = runpy.run_path(str(Path(__file__).with_name("check-build-environment.py")))["environment_errors"]
    errors = checker(environment)
    expected = {"BuildMachineOSBuild": environment["host_build"], "DTXcode": "2660",
                "DTXcodeBuild": environment["xcode_build"], "DTSDKName": "iphoneos" + environment["ios_sdk_version"],
                "DTSDKBuild": environment["ios_sdk_build"], "DTPlatformBuild": environment["ios_sdk_build"],
                "DTPlatformName": "iphoneos", "DTPlatformVersion": environment["ios_sdk_version"]}
    errors.extend("Archive provenance does not match CI: " + key for key, value in expected.items() if info.get(key) != value)
    return errors


def app_errors(info):
    expected = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": EXECUTABLE,
                "UIDeviceFamily": [1], "MinimumOSVersion": "17.0", "ITSAppUsesNonExemptEncryption": False}
    errors = ["Unexpected release configuration: " + key for key, value in expected.items() if info.get(key) != value]
    schemes = [scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])]
    if schemes != ["onlyx-connect"]:
        errors.append("The onlyx-connect URL scheme must be preserved.")
    if not all(isinstance(info.get(key), str) and info[key].strip() for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription")):
        errors.append("Camera and microphone usage descriptions are required.")
    if info.get("NSAppTransportSecurity"):
        errors.append("Unexpected transport-security exceptions.")
    return errors


def verify(app, info):
    def run(command):
        return subprocess.run(command, check=True, capture_output=True, timeout=60).stdout
    try:
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        entitlements = plistlib.loads(run(["codesign", "--display", "--entitlements", "-", "--xml", str(app)]))
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")]))
        errors = app_errors(info) + profile_errors(profile, entitlements)
        with tempfile.TemporaryDirectory(prefix="onlyx-signing-") as directory:
            prefix = Path(directory) / "certificate"
            run(["codesign", "--display", "--extract-certificates=" + str(prefix), str(app)])
            leaf = Path(str(prefix) + "0")
            certificates = profile.get("DeveloperCertificates", [])
            if not leaf.is_file() or leaf.read_bytes() not in certificates:
                errors.append("Signing certificate is not authorized by the profile.")
            chain = sorted(Path(directory).glob("certificate[0-9]*"), key=lambda p: int(p.name.removeprefix("certificate")))
            trust = ["security", "verify-cert", "-p", "codeSign", "-L", "-R", "offline", "-q"]
            for certificate in chain:
                trust.extend(["-c", str(certificate)])
            if not chain:
                errors.append("Signing certificate chain is missing.")
            else:
                run(trust)
            # Apple-trusted iOS distribution leaf and the expected team, not a
            # development certificate or a self-reported authority name.
            requirement = ("anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists "
                           "and certificate leaf[field.1.2.840.113635.100.6.1.4] exists "
                           f'and certificate leaf[subject.OU] = "{TEAM}"')
            run(["codesign", "--verify", "--strict", "-R=" + requirement, str(app)])
        return errors, entitlements, profile
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError):
        return ["Strict signature, certificate trust or provisioning verification failed."], {}, {}


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--environment-report", required=True, type=Path)
    parser.add_argument("--profile", required=True, help="Expected profile UUID or exact name")
    args = parser.parse_args()
    try:
        info = plistlib.loads((args.app / "Info.plist").read_bytes())
        report = json.loads(args.environment_report.read_text())
        errors, entitlements, profile = verify(args.app, info)
        errors.extend(provenance_errors(info, report))
        if args.profile not in (profile.get("UUID"), profile.get("Name")):
            errors.append("Signed provisioning profile differs from the requested export profile.")
        result = {"verified": not errors, "errors": errors, "entitlements": entitlements,
                  "profile_uuid": profile.get("UUID"), "build": info.get("CFBundleVersion"),
                  "app_info": info, "uploaded": False}
    except (OSError, ValueError, TypeError, KeyError) as error:
        result = {"verified": False, "errors": [str(error)], "uploaded": False}
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["verified"] else 2)

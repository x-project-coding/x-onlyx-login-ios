#!/usr/bin/env python3
"""Pin release compilation to the supported, non-beta toolchain reviewed for OnlyX Login.

Apple's 2026-09-06 matrix: Xcode 26.6 on macOS 26.2–26.x, iOS SDK 26.5.
https://developer.apple.com/xcode/system-requirements/
This checks compilation hosts, not machines used only to sign/export an archive.
"""
import json
import re
import subprocess
import sys


def environment_errors(environment):
    errors = []
    version = environment.get("host_version", "")
    match = re.fullmatch(r"26\.(\d+)(?:\.\d+)?", version)
    if not match or int(match.group(1)) < 2:
        errors.append("Compile with Xcode 26.6 on supported macOS 26.2–26.x, not this host version.")
    # The pinned CI uses a public macOS release. Do not silently accept prerelease
    # build identifiers or fabricate a different BuildMachineOSBuild in the app.
    if not re.fullmatch(r"25[A-Z]\d+", environment.get("host_build", "")):
        errors.append("The compilation host must be a public macOS 26 release build.")
    if (environment.get("xcode_version"), environment.get("xcode_build")) != ("26.6", "17F113"):
        errors.append("Select the approved Xcode 26.6 (17F113) toolchain using DEVELOPER_DIR.")
    if environment.get("ios_sdk_version") != "26.5":
        errors.append("Compile with the iOS 26.5 SDK bundled with the approved Xcode.")
    if not environment.get("ios_sdk_build"):
        errors.append("The iOS SDK build identity is missing.")
    return errors


def output(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=30).stdout.strip()


def main():
    try:
        xcode = output("xcodebuild", "-version").splitlines()
        environment = {
            "host_version": output("sw_vers", "-productVersion"),
            "host_build": output("sw_vers", "-buildVersion"),
            "xcode_version": xcode[0].removeprefix("Xcode "),
            "xcode_build": xcode[1].removeprefix("Build version "),
            "ios_sdk_version": output("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
            "ios_sdk_build": output("xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"),
        }
        errors = environment_errors(environment)
    except (OSError, subprocess.SubprocessError, IndexError):
        environment = {}
        errors = ["Unable to determine the active macOS, Xcode and iOS SDK identities."]
    print(json.dumps({"valid": not errors, "environment": environment, "errors": errors}, indent=2))
    return 2 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Build only on the approved host. No signing credentials or App Store upload.

The ZIP preserves the actual compiler-produced archive, including symlinks. It
requires separate local distribution signing, export and release validation;
an unsigned archive is not an installable or upload-ready IPA.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


API_URL = "https://of-api.onlyx.ai"
XCODEGEN_URL = "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
XCODEGEN_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"


def positive_build_number(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("ONLYX_BUILD_NUMBER must be an unused positive integer.")
    return value


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True, capture_output=capture).stdout


def archive_metadata(archive, build_number, environment):
    """Verify compiler provenance without modifying any archive contents."""
    app = archive / "Products/Applications/OnlyX Login.app"
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {
        "CFBundleIdentifier": "ai.onlyx.login",
        "CFBundleExecutable": "OnlyX Login",
        "CFBundleVersion": build_number,
        "UIDeviceFamily": [1],
        "BuildMachineOSBuild": environment["host_build"],
        "DTXcodeBuild": environment["xcode_build"],
        "DTSDKName": "iphoneos" + environment["ios_sdk_version"],
        "DTSDKBuild": environment["ios_sdk_build"],
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Archive {key} does not match the requested release/environment.")
    with (archive / "Info.plist").open("rb") as stream:
        archive_info = plistlib.load(stream)
    if archive_info.get("ApplicationProperties", {}).get("ApplicationPath") != "Applications/OnlyX Login.app":
        raise ValueError("Xcode did not produce the expected iOS application archive.")
    if (app / "embedded.mobileprovision").exists() or (app / "_CodeSignature").exists():
        raise ValueError("This job must produce an unsigned archive without provisioning material.")
    return {key: info.get(key) for key in (*expected, "DTXcode", "CFBundleShortVersionString")}


def check_release_api(repository):
    # Execute the real configuration code; a Release client must ignore an
    # environment override. The unchanged app sets packaged=true outside DEBUG.
    with tempfile.TemporaryDirectory(prefix="onlyx-login-api-check-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        directory = Path(directory)
        main = directory / "main.swift"
        main.write_text(f'''import Foundation
precondition(Config.apiBase == "{API_URL}")
precondition(Config.resolveApiBase(packaged: true, override: "https://invalid.example") == "{API_URL}")
''')
        executable = directory / "check-api"
        run("swiftc", "-O", str(repository / "Sources/OnlyXLoginCore/Config.swift"), str(main), "-o", str(executable))
        run(str(executable))


def package_archive(archive, destination):
    # Uploading the directory directly through upload-artifact loses file modes.
    # ditto retains executable modes, symbolic links and archive metadata in ZIP.
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(archive), str(destination))
    return sha256(destination)


def main():
    build_number = positive_build_number(os.environ.get("ONLYX_BUILD_NUMBER", ""))
    repository = Path(__file__).resolve().parents[1]
    os.chdir(repository)
    checked = subprocess.run([sys.executable, "scripts/check-build-environment.py"],
                             capture_output=True, text=True)
    print(checked.stdout, end="", flush=True)
    checked.check_returncode()
    report = json.loads(checked.stdout)
    if report.get("valid") is not True:
        raise ValueError("The build environment did not pass the shared release gate.")
    source_commit = run("git", "rev-parse", "HEAD", capture=True).strip()
    if source_commit != os.environ.get("GITHUB_SHA"):
        raise ValueError("The checkout does not match the dispatched GitHub commit.")
    run("git", "diff", "--exit-code", "HEAD", "--")
    # Pure core tests use their own fixtures/transports, never real accounts.
    run("swift", "test", "--configuration", "release")
    check_release_api(repository)

    output = repository / "build/ci-release"
    output.mkdir(parents=True, exist_ok=False)
    (output / "build-environment.json").write_text(json.dumps(report, indent=2) + "\n")
    archive = repository / "build" / f"OnlyXLogin-{build_number}-unsigned.xcarchive"
    if archive.exists() or archive.is_symlink():
        raise ValueError("Refusing to overwrite an existing archive.")
    with tempfile.TemporaryDirectory(prefix="onlyx-login-xcodegen-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        tool_dir = Path(directory)
        download = tool_dir / "xcodegen.zip"
        run("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
            "--proto-redir", "=https", "--tlsv1.2", "--max-time", "60", XCODEGEN_URL, "-o", str(download))
        if sha256(download) != XCODEGEN_SHA256:
            raise ValueError("XcodeGen release checksum mismatch.")
        run("ditto", "-x", "-k", str(download), str(tool_dir))
        xcodegen = tool_dir / "xcodegen/bin/xcodegen"
        xcodegen_version = run(str(xcodegen), "--version", capture=True).strip()
        run(str(xcodegen), "generate")
    run("xcodebuild", "-project", "OnlyXLogin.xcodeproj", "-scheme", "OnlyXLogin", "-configuration", "Release",
        "-destination", "generic/platform=iOS", "-archivePath", str(archive),
        "-derivedDataPath", str(repository / "build/ci-derived-data"),
        f"CURRENT_PROJECT_VERSION={build_number}",
        "DEVELOPMENT_TEAM=Y5NUN99S3X", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGN_IDENTITY=", "archive")
    metadata = archive_metadata(archive, build_number, report["environment"])
    archive_zip = output / (archive.name + ".zip")
    archive_sha256 = package_archive(archive, archive_zip)
    provenance = {
        "source_commit": source_commit,
        "repository": os.environ.get("GITHUB_REPOSITORY"),
        "workflow_run_id": os.environ.get("GITHUB_RUN_ID"),
        "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "runner_image_version": os.environ.get("ImageVersion"),
        "developer_dir": os.environ.get("DEVELOPER_DIR"),
        "environment": report["environment"],
        "xcodegen": {"version": xcodegen_version, "url": XCODEGEN_URL, "sha256": XCODEGEN_SHA256},
        "configuration": "Release", "archive_metadata": metadata,
        "api_base": API_URL,
        "validation": {"core_tests": "swift test --configuration release", "compiled_api_override_check": "passed"},
        "archive_zip": archive_zip.name, "archive_sha256": archive_sha256,
        "signing": "unsigned; local distribution signing/export/validation required",
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (output / "README.txt").write_text(
        "Unsigned OnlyX Login Release archive built on the recorded supported host.\n"
        "Verify: shasum -a 256 -c SHA256SUMS\n"
        "Extract the inner archive ZIP on macOS with: ditto -x -k <archive.zip> <empty-directory>\n"
        "Keep this original ZIP unchanged. Sign/export a separate extracted copy locally.\n"
        "Distribution signing, provisioning, export and normal release validation are still required.\n"
        "No IPA was produced or submitted, and local export compatibility is not proven by this job.\n"
        "Do not edit BuildMachineOSBuild, SDK or Xcode metadata.\n")
    (output / "SHA256SUMS").write_text("".join(
        f"{sha256(path)}  {path.name}\n" for path in sorted(output.iterdir()) if path.is_file()))
    print(f"Unsigned archive: {archive_zip.name}; SHA256: {archive_sha256}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release archive failed: {error}") from error

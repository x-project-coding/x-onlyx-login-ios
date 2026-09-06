#!/usr/bin/env python3
"""Copy and locally sign a trusted CI archive; never build, upload or export keys.

Authenticate the GitHub run/commit and verify its artifact hashes before use.
The required environment report cross-checks provenance, but is not an attestation.
Only the current OnlyX Login main-app archive (no embedded code) is supported.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import struct
import subprocess
import sys
import tempfile


DIRECTORY = Path(__file__).resolve().parent
validation = runpy.run_path(str(DIRECTORY / "release-signing.py"))
TEAM, BUNDLE, APP_PATH, EXECUTABLE, ENTITLEMENTS = (
    validation[key] for key in ("TEAM", "BUNDLE", "APP_PATH", "EXECUTABLE", "ENTITLEMENTS")
)


def run(arguments, *, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError(f"{Path(arguments[0]).name} failed (exit {result.returncode}).")
    return result.stdout


def paths(source, output):
    if source.is_symlink() or not source.is_dir() or source.suffix != ".xcarchive":
        raise ValueError("Input must be an existing, non-symlink xcarchive directory.")
    if output.exists() or output.is_symlink():
        raise ValueError("Refusing to overwrite the output archive.")
    source, output = source.resolve(), output.resolve()
    if output == source or output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError("Input and output must be separate, non-nested archives.")
    if output.suffix != ".xcarchive" or not output.parent.is_dir():
        raise ValueError("Output must be a new xcarchive in an existing directory.")
    # Relative internal symlinks are preserved; external/absolute links could
    # otherwise cause signing a copy to write through into the original.
    for entry in source.rglob("*"):
        if entry.is_symlink() and (entry.readlink().is_absolute() or not entry.resolve().is_relative_to(source)):
            raise ValueError("Archive contains an external or absolute symlink.")
    return source, output


def inventory(root):
    return {
        str(path.relative_to(root)): (
            {"symlink": str(path.readlink())} if path.is_symlink() else
            {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": path.stat().st_mode & 0o777}
        )
        for path in root.rglob("*") if path.is_symlink() or path.is_file()
    }


def check_archive(source, report):
    app = source / APP_PATH
    for file in (source / "Info.plist", app, app / "Info.plist", app / EXECUTABLE):
        if file.is_symlink():
            raise ValueError("Archive signing inputs must not be symlinks.")
    if list((source / "Products/Applications").iterdir()) != [app]:
        raise ValueError("Only the OnlyX Login main application archive is supported.")
    if any(path.suffix in (".app", ".appex", ".framework", ".dylib") for path in app.rglob("*")):
        raise ValueError("Embedded applications, extensions or libraries require a separate signing workflow.")
    for path in app.rglob("*"):
        if path.is_file() and path != app / EXECUTABLE:
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
                raise ValueError("Resource bundles must not contain another executable.")
    if (app / "embedded.mobileprovision").exists() or (app / "_CodeSignature").exists():
        raise ValueError("Input must be the unsigned CI archive, not an already signed archive.")
    executable = app / EXECUTABLE
    with executable.open("rb") as stream:
        header = stream.read(32)
    if len(header) != 32 or struct.unpack("<IiiIIIII", header)[:4] != (0xFEEDFACF, 0x100000C, 0, 2):
        raise ValueError("Expected an arm64 iOS executable in the unsigned archive.")
    if not executable.stat().st_mode & 0o111:
        raise ValueError("Executable file mode is missing; extract the original ZIP with ditto.")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    errors = validation["app_errors"](info) + validation["provenance_errors"](info, report)
    if errors:
        raise ValueError("; ".join(errors))
    if not re.fullmatch(r"[1-9][0-9]*", str(info.get("CFBundleVersion", ""))):
        raise ValueError("Archive build number must be a positive integer.")
    metadata = plistlib.loads((source / "Info.plist").read_bytes())
    properties = metadata.get("ApplicationProperties", {})
    if properties.get("ApplicationPath") != "Applications/OnlyX Login.app" or metadata.get("Distributions"):
        raise ValueError("Expected an undistributed OnlyX Login application archive.")
    for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"):
        if not info.get(key) or properties.get(key) != info[key]:
            raise ValueError(f"Archive application metadata disagrees on {key}.")
    return info, metadata


def check_profile(info, profile, identity, identities):
    if not isinstance(profile, dict) or "iOS" not in profile.get("Platform", []):
        raise ValueError("The supplied provisioning profile must support iOS.")
    if not isinstance(profile.get("UUID"), str) or not profile["UUID"]:
        raise ValueError("The provisioning profile identity is missing.")
    errors = validation["profile_errors"](profile, ENTITLEMENTS)
    if errors:
        raise ValueError("; ".join(errors))
    matches = [(digest, name) for digest, name in re.findall(r'\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', identities)
               if identity.upper() == digest.upper() or identity == name]
    if len(matches) != 1:
        raise ValueError("Choose exactly one available local Apple Distribution signing identity.")
    digest, name = matches[0]
    if not name.startswith("Apple Distribution: ") or not name.endswith("(" + TEAM + ")"):
        raise ValueError("Signing identity must be Apple Distribution for the OnlyX Login team.")
    certificates = profile.get("DeveloperCertificates", [])
    if not any(isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest().upper() == digest.upper() for cert in certificates):
        raise ValueError("The supplied profile does not authorize this signing certificate.")
    return digest, name


def prepare(source, output, profile_path, identity, environment_path):
    source, output = paths(source, output)
    report = json.loads(environment_path.read_text())
    before = inventory(source)
    info, metadata = check_archive(source, report)
    profile_bytes = profile_path.read_bytes()
    profile = plistlib.loads(run(["security", "cms", "-D"], data=profile_bytes))
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"]).decode()
    identity_hash, identity_name = check_profile(info, profile, identity, identities)
    # Reserve before copying; never merge with an existing archive. Remove only
    # this new output on failure so it cannot be mistaken for a prepared result.
    output.mkdir()
    try:
        shutil.copytree(source, output, symlinks=True, dirs_exist_ok=True)
        if inventory(output) != before:
            raise ValueError("Archive copy changed resources or executable modes.")
        app = output / APP_PATH
        (app / "embedded.mobileprovision").write_bytes(profile_bytes)
        with tempfile.TemporaryDirectory(prefix="onlyx-release-entitlements-") as directory:
            entitlements_path = Path(directory) / "ProductionEntitlements.plist"
            entitlements_path.write_bytes(plistlib.dumps(ENTITLEMENTS))
            run(["codesign", "--force", "--sign", identity_hash, "--entitlements", str(entitlements_path),
                 "--generate-entitlement-der", str(app)])
        metadata["ApplicationProperties"].update(SigningIdentity=identity_name, Team=TEAM)
        (output / "Info.plist").write_bytes(plistlib.dumps(metadata))
        after_info = plistlib.loads((app / "Info.plist").read_bytes())
        if after_info != info:
            raise ValueError("Signing changed the original app Info.plist/provenance.")
        signed = plistlib.loads(run(["codesign", "--display", "--entitlements", "-", "--xml", str(app)]))
        if signed != ENTITLEMENTS:
            raise ValueError("Signed entitlements differ from the exact OnlyX Login release allowlist.")
        errors, _, _ = validation["verify"](app, after_info)
        if errors:
            raise ValueError("; ".join(errors))
        def immutable(files):
            return {key: value for key, value in files.items() if key not in (
                "Info.plist", str(APP_PATH / EXECUTABLE), str(APP_PATH / "embedded.mobileprovision")
            ) and not key.startswith(str(APP_PATH / "_CodeSignature") + "/")}
        if immutable(inventory(output)) != immutable(before) or inventory(source) != before:
            raise ValueError("Preparation changed original files or copied archive resources.")
        return {"prepared": True, "archive": str(output), "build": info["CFBundleVersion"],
                "profile_uuid": profile["UUID"], "signing_identity": identity_name,
                "environment": report["environment"], "app_info_preserved": True,
                "source_untouched": True, "strict_signing_passed": True,
                "entitlements": signed, "uploaded": False}
    except BaseException:
        shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--signing-identity", required=True, help="Exact local Apple Distribution name or SHA-1 identity")
    parser.add_argument("--environment-report", required=True, type=Path, help="Verified CI artifact's build-environment.json")
    args = parser.parse_args()
    try:
        result = prepare(args.input, args.output, args.profile, args.signing_identity, args.environment_report)
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(2, f"Archive preparation failed: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

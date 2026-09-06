#!/bin/bash
# Export locally only; never upload or change the archive's compilation metadata.
set -euo pipefail
: "${ONLYX_ARCHIVE:?Set the prepared signed xcarchive path}"
: "${ONLYX_EXPORT_DIR:?Set a new export directory}"
: "${ONLYX_ENVIRONMENT_REPORT:?Set the authenticated CI build-environment.json path}"
: "${ONLYX_PROVISIONING_PROFILE:=58b631c4-136e-4a89-aba0-bc38dfc58e49}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
ONLYX_SCRIPTS=$(cd "$(dirname "$0")" && pwd)

python3 - "$ONLYX_ARCHIVE" "$ONLYX_EXPORT_DIR" "$ONLYX_PROVISIONING_PROFILE" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
archive, output = (Path(value) for value in sys.argv[1:3])
if not archive.is_dir() or archive.is_symlink() or archive.suffix != '.xcarchive':
    raise SystemExit('Use the prepared, non-symlink xcarchive.')
if output.exists() or output.is_symlink():
    raise SystemExit('Refusing to overwrite export output.')
if output.resolve().is_relative_to(archive.resolve()):
    raise SystemExit('Export output must be outside the original archive.')
version = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()
if version != ['Xcode 26.6', 'Build version 17F113']:
    raise SystemExit('Export with the approved stable Xcode 26.6 (17F113).')
output.mkdir()
options = {'method':'app-store-connect', 'destination':'export', 'teamID':'Y5NUN99S3X',
           'signingStyle':'manual', 'signingCertificate':'Apple Distribution',
           'provisioningProfiles':{'ai.onlyx.login':sys.argv[3]},
           'manageAppVersionAndBuildNumber':False, 'stripSwiftSymbols':True, 'uploadSymbols':True}
(output/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY

python3 "$ONLYX_SCRIPTS/release-signing.py" \
  --app "$ONLYX_ARCHIVE/Products/Applications/OnlyX Login.app" \
  --environment-report "$ONLYX_ENVIRONMENT_REPORT" --profile "$ONLYX_PROVISIONING_PROFILE" \
  > "$ONLYX_EXPORT_DIR/pre-export-verification.json"

xcodebuild -exportArchive -archivePath "$ONLYX_ARCHIVE" \
  -exportOptionsPlist "$ONLYX_EXPORT_DIR/ExportOptions.plist" -exportPath "$ONLYX_EXPORT_DIR"

python3 - "$ONLYX_ARCHIVE" "$ONLYX_EXPORT_DIR" "$ONLYX_SCRIPTS" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, runpy, subprocess, sys, zipfile
archive, output, scripts = map(Path, sys.argv[1:])
ipas = list(output.glob('*.ipa'))
if len(ipas) != 1:
    raise SystemExit('Expected exactly one exported IPA.')
ipa = ipas[0]
with zipfile.ZipFile(ipa) as zipped:
    if zipped.testzip() is not None:
        raise SystemExit('Exported IPA failed ZIP integrity validation.')
    if zipped.getinfo('Payload/OnlyX Login.app/OnlyX Login').external_attr >> 16 & 0o111 == 0:
        raise SystemExit('Exported executable mode is missing.')
subprocess.run(['ditto', '-x', '-k', str(ipa), str(output/'unpacked')], check=True)
original = archive/'Products/Applications/OnlyX Login.app'
app = output/'unpacked/Payload/OnlyX Login.app'
info = plistlib.loads((app/'Info.plist').read_bytes())
if info != plistlib.loads((original/'Info.plist').read_bytes()):
    raise SystemExit('Export changed original Info.plist/provenance values.')
def resources(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()
            and str(p.relative_to(root)) not in ('OnlyX Login', 'Info.plist', 'embedded.mobileprovision')
            and p.relative_to(root).parts[0] != '_CodeSignature'}
if resources(original) != resources(app):
    raise SystemExit('Export changed original application resources.')
def uuid(path):
    return subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True).split()[1]
ids = [uuid(app/'OnlyX Login'), uuid(original/'OnlyX Login'), uuid(archive/'dSYMs/OnlyX Login.app.dSYM')]
if len(set(ids)) != 1:
    raise SystemExit('Exported executable and original dSYM UUID differ.')
errors, entitlements, profile = runpy.run_path(str(scripts/'release-signing.py'))['verify'](app, info)
expected = json.loads((output/'pre-export-verification.json').read_text())
if profile.get('UUID') != expected['profile_uuid']:
    errors.append('Export substituted a different provisioning profile.')
result = {'verified':not errors, 'errors':errors, 'ipa':str(ipa.resolve()),
          'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest(), 'app_info':info,
          'entitlements':entitlements, 'profile_uuid':profile.get('UUID'), 'uuid':ids[0],
          'original_info_and_resources_preserved':True, 'uploaded':False}
(output/'verification.json').write_text(json.dumps(result, indent=2)+'\n')
if errors:
    raise SystemExit('Exported IPA failed strict signing checks; see verification.json.')
print('Exported and verified locally:', ipa)
PY

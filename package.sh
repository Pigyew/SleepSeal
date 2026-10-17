#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
. ./VERSION

app="$PWD/build/SleepSeal.app"
helper="$PWD/build/PowerControl"
stage="$PWD/build/package-root"
packages="$PWD/build/package-components"
output="$PWD/build/$(python3 scripts/release-metadata.py name)"
[ -d "$app" ] && [ -x "$helper" ] || {
  echo 'Build the app and PowerControl helper before packaging.' >&2
  exit 1
}
python3 scripts/release-metadata.py verify-build
/bin/rm -f "$output" "$output.sha256" "$output.manifest.json"
/bin/rm -rf "$stage" "$packages"
/bin/mkdir -p "$stage/Applications" "$stage/Library/PrivilegedHelperTools" "$packages"
/usr/bin/ditto --noqtn --norsrc "$app" "$stage/Applications/SleepSeal.app"
/usr/bin/install -m 0755 "$helper" "$stage/Library/PrivilegedHelperTools/local.sleepseal.PowerControl"
/bin/chmod -R go-w "$stage"
# Root ownership is encoded into the package; building never requires sudo.
/usr/bin/pkgbuild --root "$stage" --ownership recommended \
  --component-plist "$PWD/Packaging/Components.plist" \
  --scripts "$PWD/Packaging/Scripts" --identifier org.pigyew.sleepseal \
  --version "$SLEEPSEAL_VERSION" --install-location / "$packages/SleepSeal-component.pkg"
python3 scripts/release-metadata.py distribution build/Distribution.xml
/bin/cp -R Packaging/Resources "$packages/Resources"
# Installer text uses the same version source as the executable and package.
python3 - "$packages/Resources" "$SLEEPSEAL_VERSION" "$SLEEPSEAL_CHANNEL" <<'PY'
import pathlib, sys
for path in pathlib.Path(sys.argv[1]).rglob('*.html'):
    path.write_text(path.read_text().replace('@SLEEPSEAL_VERSION@', sys.argv[2]).replace('@SLEEPSEAL_CHANNEL@', sys.argv[3]))
PY
/usr/bin/productbuild --distribution "$PWD/build/Distribution.xml" \
  --resources "$packages/Resources" --package-path "$packages" "$output"
(cd "$PWD/build" && /usr/bin/shasum -a 256 "$(/usr/bin/basename "$output")") > "$output.sha256"
python3 scripts/release-metadata.py record-package
python3 scripts/release-metadata.py verify-package build
echo "$output"

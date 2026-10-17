#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="$PWD/build/SleepSeal.app"
helper="$PWD/build/PowerControl"
stage="$PWD/build/package-root"
packages="$PWD/build/package-components"
output="$PWD/build/SleepSeal-0.2.1-Beta-AppleSilicon.pkg"
[ -d "$app" ] && [ -x "$helper" ] || {
  echo 'Build the app and PowerControl helper before packaging.' >&2
  exit 1
}
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign --verify --strict "$helper"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = 0.2.1 ] || {
  echo 'Refusing to package an app with a different version.' >&2
  exit 1
}
/bin/rm -rf "$stage" "$packages"
/bin/mkdir -p "$stage/Applications" "$stage/Library/PrivilegedHelperTools" "$packages"
/usr/bin/ditto --noqtn --norsrc "$app" "$stage/Applications/SleepSeal.app"
/usr/bin/install -m 0755 "$helper" "$stage/Library/PrivilegedHelperTools/local.sleepseal.PowerControl"
/bin/chmod -R go-w "$stage"
# Root ownership is encoded into the package; building never requires sudo.
/usr/bin/pkgbuild --root "$stage" --ownership recommended \
  --component-plist "$PWD/Packaging/Components.plist" \
  --scripts "$PWD/Packaging/Scripts" --identifier org.pigyew.sleepseal \
  --version 0.2.1 --install-location / "$packages/SleepSeal-component.pkg"
/usr/bin/productbuild --distribution "$PWD/Packaging/Distribution.xml" \
  --resources "$PWD/Packaging/Resources" --package-path "$packages" "$output"
(cd "$PWD/build" && /usr/bin/shasum -a 256 "$(/usr/bin/basename "$output")") > "$output.sha256"
echo "$output"

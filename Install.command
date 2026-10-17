#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
package_name="$(python3 scripts/release-metadata.py name)"
if [ -f "build/$package_name" ]; then
  /usr/bin/open "build/$package_name"
else
  /usr/bin/open 'https://github.com/Pigyew/SleepSeal/releases'
fi

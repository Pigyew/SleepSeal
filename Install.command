#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f build/SleepSeal-0.2.0-Beta-AppleSilicon.pkg ]; then
  /usr/bin/open build/SleepSeal-0.2.0-Beta-AppleSilicon.pkg
else
  /usr/bin/open 'https://github.com/Pigyew/SleepSeal/releases/tag/v0.2.0'
fi

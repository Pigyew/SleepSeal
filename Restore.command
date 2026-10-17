#!/bin/bash
set -euo pipefail
# Compatibility shortcut. Recovery, diagnostics and uninstall live in the panel.
if [ -d /Applications/SleepSeal.app ]; then
  /usr/bin/open /Applications/SleepSeal.app
else
  /usr/bin/open 'https://github.com/Pigyew/SleepSeal/releases'
fi

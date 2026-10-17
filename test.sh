#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/cache" \
  Sources/StateMachine.swift Tests/StateMachineTests.swift -o build/state-tests
build/state-tests
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/cache" \
  Sources/StateMachine.swift Sources/MacSystem.swift Tests/PowerPolicyTests.swift \
  -framework AppKit -framework CoreWLAN -framework IOBluetooth -o build/policy-tests
build/policy-tests
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/cache" \
  Sources/StateMachine.swift Sources/SleepTransitions.swift Tests/SleepTransitionTests.swift -o build/transition-tests
build/transition-tests
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/cache" \
  Sources/HotCorners.swift Tests/HotCornerTests.swift -o build/hotcorner-tests
build/hotcorner-tests
for task_script in build.sh test.sh Install.command Restore.command Uninstall.command Check.command; do
  /bin/bash -n "$task_script"
done
/usr/bin/plutil -lint Resources/Info.plist

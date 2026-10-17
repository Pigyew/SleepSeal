#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache
compile_test() {
  name="$1"; shift
  /usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/build/cache" "$@" -o "build/$name"
  "build/$name"
}
compile_test state-tests Sources/StateMachine.swift Tests/StateMachineTests.swift
compile_test policy-tests Sources/StateMachine.swift Sources/PowerPolicy.swift Tests/PowerPolicyTests.swift
compile_test transition-tests Sources/StateMachine.swift Sources/SleepTransitions.swift Tests/SleepTransitionTests.swift
compile_test hotcorner-tests Sources/HotCorners.swift Tests/HotCornerTests.swift
compile_test core-reliability-tests Sources/StateMachine.swift Tests/CoreReliabilityTests.swift
compile_test trigger-tests Sources/StateMachine.swift Sources/SleepTransitions.swift Sources/HotCorners.swift Sources/TriggerPolicy.swift Sources/AppConfiguration.swift Tests/TriggerPolicyTests.swift
compile_test runtime-cycle-tests Sources/StateMachine.swift Sources/SleepTransitions.swift Sources/HotCorners.swift Sources/TriggerPolicy.swift Sources/PowerPreferences.swift Sources/ProtectionCoordinator.swift Tests/RuntimeCycleTests.swift
compile_test error-presentation-tests Sources/ErrorPresentation.swift Tests/ErrorPresentationTests.swift
compile_test power-preferences-tests Sources/PowerPreferences.swift Tests/PowerPreferencesTests.swift
compile_test command-budget-tests -DCOMMAND_BUDGET_TESTS Sources/StateMachine.swift Sources/PowerPolicy.swift Sources/MacSystem.swift Tests/CommandBudgetTests.swift -framework AppKit -framework CoreWLAN -framework IOBluetooth -framework CoreBluetooth
compile_test helper-policy-tests -DHELPER_POLICY_TESTING Helper/PowerControl.swift Tests/HelperPolicyTests.swift
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -DAGENT_IDENTITY_TESTS -module-cache-path "$PWD/build/cache" Sources/AgentIPC.swift Tests/AgentIdentityTests.swift -framework Security -o build/identity-tests
/usr/bin/codesign --force --sign - build/identity-tests
build/identity-tests
for task_script in build.sh test.sh package.sh Install.command Restore.command Uninstall.command Check.command; do /bin/bash -n "$task_script"; done
for package_script in Packaging/Scripts/*; do /bin/sh -n "$package_script"; done
/usr/bin/plutil -lint Resources/Info.plist Resources/en.lproj/*.strings Resources/zh-Hans.lproj/*.strings

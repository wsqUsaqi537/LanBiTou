#!/bin/sh
set -eu

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$tests_dir/.." && pwd)
build_dir=$(mktemp -d /tmp/reminder-tests.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT HUP INT TERM

swiftc \
  "$project_dir/Shared/Reminder.swift" \
  "$project_dir/Shared/ReminderSyncState.swift" \
  "$project_dir/Shared/ReminderRepository.swift" \
  "$tests_dir/ReminderTests.swift" \
  -module-cache-path "$build_dir/module-cache" \
  -o "$build_dir/reminder-tests"

"$build_dir/reminder-tests"

swiftc \
  -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Shared/Reminder.swift" \
  "$project_dir/Shared/ReminderSyncState.swift" \
  "$project_dir/Shared/ReminderRepository.swift" \
  "$project_dir/Shared/ReminderCloudSync.swift" \
  "$tests_dir/CloudSyncTests.swift" \
  -module-cache-path "$build_dir/module-cache" \
  -o "$build_dir/cloud-sync-tests"

"$build_dir/cloud-sync-tests"

swiftc \
  -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/App/ReminderNotifications.swift" \
  "$tests_dir/NotificationTests.swift" \
  -module-cache-path "$build_dir/module-cache" \
  -o "$build_dir/notification-tests"

"$build_dir/notification-tests"

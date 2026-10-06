#!/bin/sh
set -eu

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$tests_dir/.." && pwd)
build_dir=$(mktemp -d /tmp/reminder-tests.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT HUP INT TERM

swiftc \
  "$project_dir/Shared/Reminder.swift" \
  "$project_dir/Shared/ReminderRepository.swift" \
  "$tests_dir/ReminderTests.swift" \
  -module-cache-path "$build_dir/module-cache" \
  -o "$build_dir/reminder-tests"

"$build_dir/reminder-tests"

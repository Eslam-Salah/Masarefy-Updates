#!/usr/bin/env bash
set -euo pipefail

APK="${RUNNER_TEMP:?}/qa/Masarefy-v1.0.0.apk"
test -s "$APK"
adb wait-for-device

# Test only the public signed binary. No private source/key/data access.
adb shell pm list packages com.masarefy.app | grep -qv 'package:com.masarefy.app' || {
  echo 'A prior install is unexpectedly present on the clean emulator' >&2
  exit 1
}
adb install --no-streaming "$APK"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 12
adb shell pm list packages com.masarefy.app | grep -Fx 'package:com.masarefy.app'
adb shell dumpsys package com.masarefy.app | grep -m1 "versionCode=1"
PID="$(adb shell pidof com.masarefy.app | tr -d '\r\n ')"
test -n "$PID" || { echo 'App not running after first launch' >&2; exit 1; }
adb exec-out screencap -p > "$RUNNER_TEMP/qa/first-launch.png"
test -s "$RUNNER_TEMP/qa/first-launch.png"
echo "PASS: official signed v1.0.0 installed, opened and remained alive as PID $PID"

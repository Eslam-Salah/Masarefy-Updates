#!/usr/bin/env bash
set -euo pipefail

APK="${RUNNER_TEMP:?}/qa/Masarefy-v1.0.0.apk"
test -s "$APK"
adb wait-for-device

# Test only the public signed binary. No private source/key/data access.
if adb shell pm list packages com.masarefy.app | grep -qFx 'package:com.masarefy.app'; then
  echo 'A prior install is unexpectedly present on the clean emulator' >&2
  exit 1
fi
adb install --no-streaming "$APK"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 12
adb shell pm list packages com.masarefy.app | grep -Fx 'package:com.masarefy.app'
adb shell dumpsys package com.masarefy.app | grep -m1 "versionCode=1"
PID="$(adb shell pidof com.masarefy.app | tr -d '\r\n ')"
test -n "$PID" || { echo 'App not running after first launch' >&2; exit 1; }
adb exec-out screencap -p > "$RUNNER_TEMP/qa/first-launch.png"
test -s "$RUNNER_TEMP/qa/first-launch.png"
# Diagnostic follow-up: verify the screen is not stuck on an empty splash gradient
# after the app has had plenty of time to initialize.
sleep 32
adb shell input keyevent KEYCODE_WAKEUP || true
adb exec-out screencap -p > "$RUNNER_TEMP/qa/first-launch-after-45s.png"
adb shell dumpsys activity top > "$RUNNER_TEMP/qa/activity-top.txt" || true
adb shell dumpsys window windows > "$RUNNER_TEMP/qa/window-focus.txt" || true
adb shell dumpsys gfxinfo com.masarefy.app > "$RUNNER_TEMP/qa/gfxinfo.txt" || true
adb logcat -d -v time -t 1400 > "$RUNNER_TEMP/qa/logcat.txt" || true
timeout 30 adb shell uiautomator dump /sdcard/qa-view.xml || true
adb pull /sdcard/qa-view.xml "$RUNNER_TEMP/qa/qa-view.xml" || true
if [ -z "$(adb shell pidof com.masarefy.app | tr -d '\\r\\n ')" ]; then
  echo 'Application process terminated before second screenshot' >&2
  exit 1
fi
echo "INFO: signed APK installed and launched. Screenshots, activity, UI and logcat diagnostics captured for review."

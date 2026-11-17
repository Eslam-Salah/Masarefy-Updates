#!/usr/bin/env bash
set -euo pipefail

APK="${RUNNER_TEMP:?}/qa/Masarefy-v1.0.0.apk"
test -s "$APK"
adb wait-for-device
# Let the freshly booted Android system settle before launching the app.
test "$(adb shell getprop sys.boot_completed | tr -d '\r\n ')" = 1
sleep 20

# Test only the public signed binary. No private source/key/data access.
if adb shell pm list packages com.masarefy.app | grep -qFx 'package:com.masarefy.app'; then
  echo 'A prior install is unexpectedly present on the clean emulator' >&2
  exit 1
fi
adb logcat -c || true
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
if ! timeout 45 adb shell uiautomator dump /sdcard/qa-view.xml; then
  echo 'FAIL: Android UI hierarchy could not be captured' >&2
  exit 1
fi
adb pull /sdcard/qa-view.xml "$RUNNER_TEMP/qa/qa-view.xml"
test -s "$RUNNER_TEMP/qa/qa-view.xml"
# A running PID alone is not a pass: the previous "successful" run
# showed an Android system ANR dialog on top of an otherwise live app.
if grep -Fq 'Application Not Responding:' "$RUNNER_TEMP/qa/window-focus.txt"; then
  echo 'FAIL: Android system/app ANR dialog obscures the first-launch UI' >&2
  exit 1
fi
if grep -Eq 'ANR in (com\.masarefy\.app|com\.android\.phone|com\.android\.systemui|system)' "$RUNNER_TEMP/qa/logcat.txt"; then
  echo 'FAIL: Android system/app ANR detected in startup logcat' >&2
  exit 1
fi
if ! grep -Fq 'package="com.masarefy.app"' "$RUNNER_TEMP/qa/qa-view.xml"; then
  echo 'FAIL: app UI is not the foreground screen (blocking dialog or blank screen)' >&2
  exit 1
fi
if [ -z "$(adb shell pidof com.masarefy.app | tr -d '\\r\\n ')" ]; then
  echo 'Application process terminated before second screenshot' >&2
  exit 1
fi
echo "PASS: signed APK launched without ANR and app UI is visible in foreground."

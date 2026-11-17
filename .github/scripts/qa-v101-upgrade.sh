#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v101"
OLD="$QA/Masarefy-v1.0.0.apk"
NEW="$QA/Masarefy-v1.0.1.apk"
test -s "$OLD"
test -s "$NEW"
mkdir -p "$QA"

adb wait-for-device
test "$(adb shell getprop sys.boot_completed | tr -d '\r\n ')" = 1
sleep 18
if adb shell pm list packages com.masarefy.app | grep -qFx 'package:com.masarefy.app'; then
  echo 'FAIL: emulator is not clean before installing first release' >&2
  exit 1
fi

# Install real published first release, not a locally rebuilt approximation.
adb install --no-streaming "$OLD"
adb shell pm list packages com.masarefy.app | grep -qFx 'package:com.masarefy.app'
adb shell dumpsys package com.masarefy.app | grep -m1 'versionCode=1' > "$QA/before-upgrade-version.txt"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 12
adb shell pidof com.masarefy.app > "$QA/before-upgrade-pid.txt"
test -s "$QA/before-upgrade-pid.txt"

# Use the disposable emulator only to create a marker inside the app data
# directory. This tests Android package-manager preservation of app files.
# It does NOT assert financial DB or user backup migrations have been tested.
adb root
adb wait-for-device
adb shell 'mkdir -p /data/user/0/com.masarefy.app/files && printf "keep-v100-test-data" > /data/user/0/com.masarefy.app/files/qa-package-upgrade-marker'
adb shell 'cat /data/user/0/com.masarefy.app/files/qa-package-upgrade-marker' | grep -Fx 'keep-v100-test-data'
adb shell am force-stop com.masarefy.app || true
adb logcat -c || true

# -r MUST install in place: no uninstall, no clear-data, no fresh-install fallback.
adb install -r --no-streaming "$NEW"
adb shell dumpsys package com.masarefy.app | grep -m1 'versionCode=2' > "$QA/after-upgrade-version.txt"
adb shell 'cat /data/user/0/com.masarefy.app/files/qa-package-upgrade-marker' | grep -Fx 'keep-v100-test-data'
adb shell am start -n com.masarefy.app/.MainActivity
sleep 12
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
adb exec-out screencap -p > "$QA/upgrade-first-launch.png"
test -s "$QA/upgrade-first-launch.png"
sleep 32
adb shell input keyevent KEYCODE_WAKEUP || true
adb exec-out screencap -p > "$QA/upgrade-after-45s.png"
adb shell dumpsys window windows > "$QA/window-focus.txt" || true
adb logcat -d -v time -t 2500 > "$QA/logcat.txt" || true
if ! timeout 45 adb shell uiautomator dump /sdcard/qa-upgrade-view.xml; then
  echo 'FAIL: cannot inspect foreground Android UI after update' >&2
  exit 1
fi
adb pull /sdcard/qa-upgrade-view.xml "$QA/qa-upgrade-view.xml"
test -s "$QA/qa-upgrade-view.xml"
if grep -Fq 'Application Not Responding:' "$QA/window-focus.txt"; then
  echo 'FAIL: Android ANR system dialog covers upgraded application' >&2
  exit 1
fi
if grep -Eq 'ANR in (com\.masarefy\.app|com\.android\.phone|com\.android\.systemui|system)' "$QA/logcat.txt"; then
  echo 'FAIL: Android/system ANR during signed upgrade' >&2
  exit 1
fi
if ! grep -Fq 'package="com.masarefy.app"' "$QA/qa-upgrade-view.xml"; then
  echo 'FAIL: Masarefy is not the visible foreground UI after in-place upgrade' >&2
  exit 1
fi
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
echo 'PASS: actual published v1.0.0 updated in place to same-signed v1.0.1 Build 2, emulator app-file marker persisted and UI is responsive.'

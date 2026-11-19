#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?light-normal or dark-large is required}"
THEME="${2:?yes or no is required}"
FONT_SCALE="${3:?font scale is required}"
case "$MODE:$THEME:$FONT_SCALE" in
  light-normal:no:1.0|dark-large:yes:1.5) ;;
  *) echo 'Unexpected visual test configuration' >&2; exit 2 ;;
esac

QA="${RUNNER_TEMP:?}/qa-v105-ui/$MODE"
APK="${RUNNER_TEMP:?}/Masarefy-v1.0.5.apk"
mkdir -p "$QA"
test -s "$APK"

adb wait-for-device
test "$(adb shell getprop sys.boot_completed | tr -d '\r\n ')" = 1
adb shell settings put system font_scale "$FONT_SCALE"
adb shell cmd uimode night "$THEME"
adb shell settings get system font_scale > "$QA/font-scale.txt"
adb shell cmd uimode night > "$QA/system-night-mode.txt"

if adb shell pm list packages com.masarefy.app | grep -qFx 'package:com.masarefy.app'; then
  echo 'FAIL: emulator must be isolated and clean before app installation' >&2
  exit 1
fi
adb install --no-streaming "$APK"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 14
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
adb exec-out screencap -p > "$QA/home-first-launch.png"
test -s "$QA/home-first-launch.png"

# Capture a second view after a harmless upward scroll; no financial data are created.
adb shell input swipe 500 1750 500 670 500
sleep 3
adb exec-out screencap -p > "$QA/home-after-scroll.png"
test -s "$QA/home-after-scroll.png"
adb shell dumpsys window windows > "$QA/window-focus.txt" || true
adb logcat -d -v time -t 2500 > "$QA/logcat.txt" || true
if ! timeout 50 adb shell uiautomator dump /sdcard/masarefy-visual.xml; then
  echo 'FAIL: Android UI hierarchy not available after launch' >&2
  exit 1
fi
adb pull /sdcard/masarefy-visual.xml "$QA/home-hierarchy.xml"
test -s "$QA/home-hierarchy.xml"
if ! grep -Fq 'package="com.masarefy.app"' "$QA/home-hierarchy.xml"; then
  echo 'FAIL: Masarefy is not visible in the inspected foreground UI' >&2
  exit 1
fi
if grep -Fq 'Application Not Responding:' "$QA/window-focus.txt"; then
  echo 'FAIL: visible ANR covers the app' >&2
  exit 1
fi
if grep -Eq 'ANR in (com\.masarefy\.app|com\.android\.systemui|system)' "$QA/logcat.txt"; then
  echo 'FAIL: Android or app ANR found' >&2
  exit 1
fi
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
printf '%s\n' "PASS: v1.0.5 UI screenshot evidence and basic foreground checks for $MODE"

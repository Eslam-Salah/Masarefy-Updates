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

# App theme is an explicit setting; changing Android night mode alone does NOT
# test Masarefy's dark theme. Toggle the first appearance switch on the empty emulator.
if [ "$MODE" = 'dark-large' ]; then
  timeout 50 adb shell uiautomator dump /sdcard/masarefy-home-before-theme.xml
  adb pull /sdcard/masarefy-home-before-theme.xml "$QA/home-before-theme.xml" >/dev/null
  # Use the real accessibility bounds rather than guessed tap coordinates.
  read -r TAB_X TAB_Y < <(python3 - "$QA/home-before-theme.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
nodes=[n for n in root.iter('node') if n.attrib.get('text') == 'الإعدادات']
if len(nodes) != 1:
    raise SystemExit('Settings tab not uniquely available in Android UI')
m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', nodes[0].attrib['bounds'])
if not m:
    raise SystemExit('Invalid settings tab accessibility bounds')
x1,y1,x2,y2=map(int,m.groups())
print((x1+x2)//2,(y1+y2)//2)
PY
  )
  adb shell input tap "$TAB_X" "$TAB_Y"
  sleep 4
  timeout 50 adb shell uiautomator dump /sdcard/masarefy-settings-before.xml
  adb pull /sdcard/masarefy-settings-before.xml "$QA/settings-before.xml" >/dev/null
  # Appearance is the first card in SettingsScreen. Its switch is first in the
  # accessibility order; refuse to click anything if it cannot be identified.
  read -r SWITCH_X SWITCH_Y < <(python3 - "$QA/settings-before.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
nodes=list(root.iter('node'))
if not any(n.attrib.get('text') == 'الوضع الفاتح' for n in nodes):
    raise SystemExit('Expected initial light appearance switch not shown')
switches=[n for n in nodes if n.attrib.get('class') == 'android.widget.Switch']
if not switches:
    switches=[n for n in nodes if n.attrib.get('checkable') == 'true' and n.attrib.get('clickable') == 'true']
if not switches:
    raise SystemExit('Cannot identify the appearance Switch')
m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',switches[0].attrib['bounds'])
if not m:
    raise SystemExit('Invalid appearance switch bounds')
x1,y1,x2,y2=map(int,m.groups())
print((x1+x2)//2,(y1+y2)//2)
PY
  )
  adb shell input tap "$SWITCH_X" "$SWITCH_Y"
  sleep 4
  timeout 50 adb shell uiautomator dump /sdcard/masarefy-settings-dark.xml
  adb pull /sdcard/masarefy-settings-dark.xml "$QA/settings-dark.xml" >/dev/null
  grep -Fq 'text="الوضع الداكن"' "$QA/settings-dark.xml" || {
    echo 'FAIL: app-specific dark theme did not become enabled' >&2
    exit 1
  }
  adb exec-out screencap -p > "$QA/settings-dark.png"
  adb shell input keyevent KEYCODE_BACK
  sleep 4
fi

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

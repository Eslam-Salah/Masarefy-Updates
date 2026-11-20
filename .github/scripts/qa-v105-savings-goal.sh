#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-savings-goal"
APK="${RUNNER_TEMP:?}/Masarefy-v1.0.5.apk"
mkdir -p "$QA"
test -s "$APK"

dump_ui() {
  local name="$1"
  timeout 50 adb shell uiautomator dump "/sdcard/masarefy-$name.xml"
  adb pull "/sdcard/masarefy-$name.xml" "$QA/$name.xml" >/dev/null
  test -s "$QA/$name.xml"
}

# Target app semantics, not arbitrary screen coordinates.
tap_ui() {
  local xml="$1" kind="$2" target="$3"
  read -r x y < <(python3 - "$xml" "$kind" "$target" <<'PY'
import re, sys, xml.etree.ElementTree as E
xml, kind, target = sys.argv[1:]
nodes=list(E.parse(xml).getroot().iter('node'))
if kind == 'edit':
    matches=[n for n in nodes if n.attrib.get('class') == 'android.widget.EditText']
    i=int(target)
    if i >= len(matches):
        raise SystemExit(f'Expected form text field #{i}, only {len(matches)} found')
    node=matches[i]
elif kind in ('text','content-desc'):
    matches=[n for n in nodes if n.attrib.get(kind) == target]
    if len(matches) != 1:
        raise SystemExit(f'Expected unique {kind}={target!r}, got {len(matches)}')
    node=matches[0]
else:
    raise SystemExit('Unsupported UI selector')
bounds=node.attrib['bounds']
m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',bounds)
if not m:
    raise SystemExit(f'Invalid accessibility bounds: {bounds}')
a,b,c,d=map(int,m.groups())
print((a+c)//2,(b+d)//2)
PY
  )
  test -n "$x" && test -n "$y"
  adb shell input tap "$x" "$y"
}

adb wait-for-device
test "$(adb shell getprop sys.boot_completed | tr -d '\r\n ')" = 1
test -z "$(adb shell pm list packages com.masarefy.app | grep -Fx 'package:com.masarefy.app' || true)"
adb install --no-streaming "$APK"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 12
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
dump_ui home-before

# Navigate from home to Savings goals. The planning cards may be offscreen.
for attempt in 1 2 3 4 5 6; do
  dump_ui "home-goal-$attempt"
  if grep -Fq 'text="الادخار"' "$QA/home-goal-$attempt.xml"; then break; fi
  adb shell input swipe 510 1700 510 670 430
  sleep 2
done
grep -Fq 'text="الادخار"' "$QA/home-goal-$attempt.xml"
tap_ui "$QA/home-goal-$attempt.xml" text 'الادخار'
sleep 4
dump_ui goal-page
grep -Fq 'text="أهداف الادخار"' "$QA/goal-page.xml"
tap_ui "$QA/goal-page.xml" content-desc 'إضافة هدف'
sleep 3
dump_ui goal-form
grep -Fq 'text="هدف ادخار جديد"' "$QA/goal-form.xml"

tap_ui "$QA/goal-form.xml" edit 0
adb shell input text 'QAGOAL26'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui goal-name
tap_ui "$QA/goal-name.xml" edit 1
adb shell input text '1000'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui goal-target
tap_ui "$QA/goal-target.xml" edit 2
adb shell input text '250'
adb shell input keyevent KEYCODE_BACK
sleep 2

for attempt in 1 2 3 4; do
  dump_ui "goal-bottom-$attempt"
  if grep -Fq 'text="إضافة الهدف"' "$QA/goal-bottom-$attempt.xml"; then break; fi
  adb shell input swipe 550 1690 550 670 430
  sleep 2
done
grep -Fq 'text="إضافة الهدف"' "$QA/goal-bottom-$attempt.xml"
tap_ui "$QA/goal-bottom-$attempt.xml" text 'إضافة الهدف'
sleep 6
dump_ui goal-created
adb exec-out screencap -p > "$QA/goal-created.png"
grep -Fq 'text="QAGOAL26"' "$QA/goal-created.xml"

for attempt in 1 2 3 4; do
  dump_ui "goal-contribute-$attempt"
  if grep -Fq 'text="إضافة مبلغ للهدف"' "$QA/goal-contribute-$attempt.xml"; then break; fi
  adb shell input swipe 520 1690 520 720 420
  sleep 2
done
grep -Fq 'text="إضافة مبلغ للهدف"' "$QA/goal-contribute-$attempt.xml"
tap_ui "$QA/goal-contribute-$attempt.xml" text 'إضافة مبلغ للهدف'
sleep 3
dump_ui contribution-dialog
tap_ui "$QA/contribution-dialog.xml" edit 0
adb shell input text '200'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui contribution-filled
tap_ui "$QA/contribution-filled.xml" text 'إضافة'
sleep 7
dump_ui after-contribution
adb exec-out screencap -p > "$QA/after-contribution.png"

adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/savings-goal-results.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
assert db.execute('pragma user_version').fetchone()[0]==11
goals=db.execute("SELECT uid,title,targetAmount,savedAmount,targetDate,isActive FROM savings_goals WHERE title='QAGOAL26'").fetchall()
assert len(goals)==1, goals
uid,title,target,saved,date,active=goals[0]
assert len(uid)>10 and active==1 and len(date)==10
assert abs(target-1000)<.001 and abs(saved-450)<.001,goals
assert abs((target-saved)-550)<.001
assert abs(saved/target-.45)<.0001
assert db.execute("SELECT count(*) FROM transactions").fetchone()[0]==0, 'Savings transfer must not create expense'
print('PASS: official signed v1.0.5 created EGP 1,000 savings goal, started at 250, added 200 to reach 450 (45%); remaining 550, and no duplicate expense transaction.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/savings-goal-results.txt"

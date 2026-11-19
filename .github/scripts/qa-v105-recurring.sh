#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-recurring"
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
dump_ui home
tap_ui "$QA/home.xml" text 'الإعدادات'
sleep 3
for n in 1 2 3 4 5 6; do
  dump_ui "settings-recurring-$n"
  if grep -Fq 'text="المعاملات المتكررة"' "$QA/settings-recurring-$n.xml"; then break; fi
  adb shell input swipe 500 1750 500 650 420
  sleep 2
done
grep -Fq 'text="المعاملات المتكررة"' "$QA/settings-recurring-$n.xml"
tap_ui "$QA/settings-recurring-$n.xml" text 'المعاملات المتكررة'
sleep 4
dump_ui recurring-list
tap_ui "$QA/recurring-list.xml" text 'إضافة معاملة متكررة'
sleep 4
dump_ui recurring-form

# Build a monthly rule with a synthetic amount, no personal information.
tap_ui "$QA/recurring-form.xml" edit 0
adb shell input text 'QARECUR26'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui recurring-name
tap_ui "$QA/recurring-name.xml" edit 1
adb shell input text '75'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui recurring-amount
tap_ui "$QA/recurring-amount.xml" edit 2
adb shell input text 'QARECURCAT26'
adb shell input keyevent KEYCODE_BACK
sleep 1

# Scroll down within the modal sheet to reach the active switch and submit.
for n in 1 2 3 4 5 6; do
  dump_ui "recurring-bottom-$n"
  if grep -Fq 'text="نشطة"' "$QA/recurring-bottom-$n.xml"; then break; fi
  adb shell input swipe 520 1690 520 690 460
  sleep 2
done
grep -Fq 'text="نشطة"' "$QA/recurring-bottom-$n.xml"

# Disable the test rule before saving, so no scheduled transaction is due.
read -r x y < <(python3 - "$QA/recurring-bottom-$n.xml" <<'PY'
import re,sys,xml.etree.ElementTree as ET
nodes=list(ET.parse(sys.argv[1]).getroot().iter('node'))
switches=[n for n in nodes if n.attrib.get('class')=='android.widget.Switch']
if not switches: switches=[n for n in nodes if n.attrib.get('checkable')=='true' and n.attrib.get('clickable')=='true']
if len(switches)!=1: raise SystemExit('Expected unique recurring active switch')
n=switches[0]
assert n.attrib.get('checked')=='true','Active switch not enabled initially'
a,b,c,d=map(int,re.findall(r'\d+',n.attrib['bounds']))
print((a+c)//2,(b+d)//2)
PY
)
adb shell input tap "$x" "$y"
sleep 2
dump_ui recurring-paused
python3 - "$QA/recurring-paused.xml" <<'PY'
import sys,xml.etree.ElementTree as ET
n=list(ET.parse(sys.argv[1]).getroot().iter('node'))
sw=[x for x in n if x.attrib.get('class')=='android.widget.Switch']
if not sw: sw=[x for x in n if x.attrib.get('checkable')=='true' and x.attrib.get('clickable')=='true']
assert len(sw)==1 and sw[0].attrib.get('checked')=='false', 'Recurring switch was not paused'
PY
grep -Fq 'text="إضافة المعاملة المتكررة"' "$QA/recurring-paused.xml"
adb exec-out screencap -p > "$QA/recurring-paused.png"
tap_ui "$QA/recurring-paused.xml" text 'إضافة المعاملة المتكررة'
sleep 7
dump_ui recurring-saved
adb exec-out screencap -p > "$QA/recurring-saved.png"

adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/recurring-verification.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
rows=db.execute("SELECT type,name,amount,category,frequency,intervalCount,isActive,startDate,nextRunDate,uid FROM recurring_transactions WHERE name='QARECUR26'").fetchall()
assert len(rows)==1, rows
kind,name,amount,cat,freq,interval,active,start,next_run,uid=rows[0]
assert kind=='expense' and abs(amount-75)<0.001 and cat=='QARECURCAT26',rows
assert freq=='monthly' and interval==1 and active==0,rows
assert len(start)==10 and len(next_run)==10 and uid and len(uid)>10,rows
tx=db.execute("SELECT count(*) FROM transactions WHERE category='QARECURCAT26'").fetchone()[0]
assert tx==0, 'Paused future rule must not produce ledger transaction'
print('PASS: official signed APK saved one paused monthly EGP 75 recurring expense rule in Room, with valid dates and no generated transaction.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/recurring-verification.txt"

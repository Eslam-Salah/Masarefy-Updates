#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-recurring-due"
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
adb shell input text 'QADUE26'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui recurring-name
tap_ui "$QA/recurring-name.xml" edit 1
adb shell input text '75'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui recurring-amount
tap_ui "$QA/recurring-amount.xml" edit 2
adb shell input text 'QADUECAT26'
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


# The default start date is today and the rule remains ACTIVE.
# Saving must immediately create one occurrence, without duplication later.
dump_ui recurring-active
python3 - "$QA/recurring-active.xml" <<'PY'
import sys,xml.etree.ElementTree as ET,re
nodes=list(ET.parse(sys.argv[1]).getroot().iter('node'))
labels=[n for n in nodes if n.attrib.get('text')=='نشطة']
switches=[n for n in nodes if n.attrib.get('checkable')=='true' and n.attrib.get('clickable')=='true']
assert len(labels)==1 and switches
def cy(n):
    a=list(map(int,re.findall(r'\d+',n.attrib.get('bounds',''))))
    return (a[1]+a[3])/2
sw=min(switches,key=lambda n:abs(cy(n)-cy(labels[0])))
assert abs(cy(sw)-cy(labels[0]))<90 and sw.attrib.get('checked')=='true','Rule must remain active'
PY
grep -Fq 'text="إضافة المعاملة المتكررة"' "$QA/recurring-active.xml"
tap_ui "$QA/recurring-active.xml" text 'إضافة المعاملة المتكررة'
sleep 8
dump_ui after-create-active
adb exec-out screencap -p > "$QA/after-create-active.png"

# Restart three times to re-enter app startup processing. All occurrences
# must be unique by source UID and occurrence date.
for n in 1 2 3; do
  adb shell am force-stop com.masarefy.app
  sleep 1
  adb shell am start -n com.masarefy.app/.MainActivity
  sleep 5
  dump_ui "restarted-$n"
done

adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/recurring-due-verification.txt" <<'PY'
import sqlite3,sys,datetime
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
rules=db.execute("SELECT id,uid,type,amount,category,frequency,intervalCount,isActive,startDate,nextRunDate FROM recurring_transactions WHERE name='QADUE26'").fetchall()
assert len(rules)==1,rules
id_,uid,type_,amount,cat,freq,interval,active,start,next_run=rules[0]
assert type_=='expense' and abs(amount-75)<.001 and cat=='QADUECAT26'
assert freq=='monthly' and interval==1 and active==1
tx=db.execute("SELECT uid,type,name,amount,category,date,recurringSourceId,recurringSourceUid,recurringOccurrenceDate FROM transactions WHERE recurringSourceUid=?",(uid,)).fetchall()
assert len(tx)==1, f'Expected exactly one due generated occurrence after three restarts, got {tx!r}'
tu,tt,tn,ta,tc,td,source_id,source_uid,occ_date=tx[0]
assert tt=='expense' and tn=='QADUE26' and abs(ta-75)<.001 and tc=='QADUECAT26'
assert source_id==id_ and source_uid==uid and occ_date==td==start
assert next_run>start, f'Next run date must be advanced, got start={start}, next={next_run}'
assert len(tu)>10
assert db.execute("SELECT count(*) FROM transactions WHERE recurringSourceUid=? AND recurringOccurrenceDate=?",(uid,start)).fetchone()[0]==1
print('PASS: active monthly recurring rule generated exactly one EGP 75 expense, advanced its next date, and did not duplicate occurrence across 3 app restarts.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/recurring-due-verification.txt"

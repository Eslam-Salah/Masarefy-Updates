#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-monthend"
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
labels=[n for n in nodes if n.attrib.get('text')=='نشطة']
if len(labels)!=1: raise SystemExit('Recurring active label not uniquely identified')
switches=[n for n in nodes if n.attrib.get('checkable')=='true' and n.attrib.get('clickable')=='true']
def cy(n):
    a=list(map(int,re.findall(r'\d+',n.attrib.get('bounds',''))))
    if len(a)!=4: raise SystemExit('Malformed accessibility bounds')
    return (a[1]+a[3])/2
if not switches: raise SystemExit('Missing checkable active switch')
n=min(switches,key=lambda sw:abs(cy(sw)-cy(labels[0])))
assert abs(cy(n)-cy(labels[0]))<90,'No switch adjacent to active label'
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
import re
labels=[x for x in n if x.attrib.get('text')=='نشطة']
sw=[x for x in n if x.attrib.get('checkable')=='true' and x.attrib.get('clickable')=='true']
assert len(labels)==1 and len(sw)>0,'Missing recurring switch or label'
def cy(x):
    a=list(map(int,re.findall(r'\d+',x.attrib.get('bounds',''))))
    return (a[1]+a[3])/2
chosen=min(sw,key=lambda x:abs(cy(x)-cy(labels[0])))
assert abs(cy(chosen)-cy(labels[0]))<90 and chosen.attrib.get('checked')=='false', 'Recurring switch was not paused'
PY
grep -Fq 'text="إضافة المعاملة المتكررة"' "$QA/recurring-paused.xml"
adb exec-out screencap -p > "$QA/recurring-paused.png"
tap_ui "$QA/recurring-paused.xml" text 'إضافة المعاملة المتكررة'
sleep 7
dump_ui recurring-saved
adb exec-out screencap -p > "$QA/recurring-saved.png"

# TEST-ONLY FIXTURE: convert an already saved paused rule into an
# active month-end rule in the emulator's disposable Room DB.
# Use Jan 31, 2026 -> Apr 30, 2026 to force February and leap logic.
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
adb shell 'stat -c "%u:%g" /data/user/0/com.masarefy.app/databases/masarefy.db' | tr -d '\r\n' > "$QA/owner.txt"
python3 - "$QA/masarefy.db" > "$QA/test-fixture.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
rows=db.execute("SELECT id,isActive,frequency FROM recurring_transactions WHERE name='QARECUR26'").fetchall()
assert len(rows)==1 and rows[0][1]==0 and rows[0][2]=='monthly',rows
assert db.execute("SELECT count(*) FROM transactions WHERE category='QARECURCAT26'").fetchone()[0]==0
db.execute("""UPDATE recurring_transactions
              SET startDate='2026-01-31', nextRunDate='2026-01-31',
                  anchorDayOfMonth=31, endDate='2026-04-30',
                  isActive=1 WHERE id=?""",(rows[0][0],))
db.commit()
db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
db.close()
print('Emulator-only synthetic rule: monthly 2026-01-31 through 2026-04-30, anchor=31')
PY
owner="$(cat "$QA/owner.txt")"
adb push "$QA/masarefy.db" /data/user/0/com.masarefy.app/databases/masarefy.db >/dev/null
adb shell "rm -f /data/user/0/com.masarefy.app/databases/masarefy.db-wal /data/user/0/com.masarefy.app/databases/masarefy.db-shm; chown '$owner' /data/user/0/com.masarefy.app/databases/masarefy.db; chmod 600 /data/user/0/com.masarefy.app/databases/masarefy.db"
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm" "$QA/owner.txt"

# The same signed APK launches and processes the due occurrences.
# Repeat launch to test idempotency without any production code modifications.
for attempt in 1 2 3; do
  adb shell am force-stop com.masarefy.app || true
  adb shell am start -n com.masarefy.app/.MainActivity
  sleep 7
  dump_ui "monthend-launch-$attempt"
done
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/monthend-verification.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
rows=db.execute("""SELECT uid,isActive,startDate,endDate,nextRunDate,anchorDayOfMonth
                   FROM recurring_transactions WHERE name='QARECUR26'""").fetchall()
assert len(rows)==1,rows
uid,active,start,end,next_run,anchor=rows[0]
assert start=='2026-01-31' and end=='2026-04-30' and anchor==31,rows
assert active==0 and next_run=='2026-05-31',rows
tx=db.execute("""SELECT date,amount,type,recurringOccurrenceDate,recurringSourceUid,uid
                 FROM transactions WHERE recurringSourceUid=? ORDER BY date""",(uid,)).fetchall()
dates=[t[0] for t in tx]
expected=['2026-01-31','2026-02-28','2026-03-31','2026-04-30']
assert dates==expected,f'Month-end recurring dates incorrect: {dates!r} != {expected!r}'
assert all(t[2]=='expense' and abs(t[1]-75)<.001 and t[0]==t[3] and t[4]==uid for t in tx),tx
assert len({t[5] for t in tx})==len(tx),'Duplicate generated UUID'
print('PASS: signed APK generated Jan31/Feb28/Mar31/Apr30 month-end occurrences once each, stopped after end date, and remained idempotent over 3 launches.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/monthend-verification.txt"

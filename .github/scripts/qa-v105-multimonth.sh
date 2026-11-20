#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-multimonth"
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
tap_ui "$QA/home-before.xml" 'content-desc' 'إضافة معاملة'
sleep 3
dump_ui editor-before
grep -Fq 'text="إضافة معاملة"' "$QA/editor-before.xml"
tap_ui "$QA/editor-before.xml" text 'إضافة يدوية'
sleep 3
dump_ui editor-form
grep -Fq 'text="المبلغ"' "$QA/editor-form.xml"

# Exactly one synthetic expense, on an isolated empty emulator.
# Amount and category are the editor's first two Compose EditText fields.
tap_ui "$QA/editor-form.xml" edit 0
adb shell input text '123'
adb shell input keyevent KEYCODE_BACK
sleep 2
dump_ui editor-amount
tap_ui "$QA/editor-amount.xml" edit 1
adb shell input text 'QA2026'
adb shell input keyevent KEYCODE_BACK
sleep 2
dump_ui editor-filled
adb exec-out screencap -p > "$QA/editor-filled.png"
tap_ui "$QA/editor-filled.xml" text 'إضافة المعاملة'
sleep 8
dump_ui after-save
adb exec-out screencap -p > "$QA/after-save.png"
if grep -Fq 'text="أدخل مبلغًا صحيحًا أكبر من صفر."' "$QA/after-save.xml"; then
  echo 'FAIL: invalid saved amount' >&2
  exit 1
fi



# Add a second transaction (income) in the current month to make filters and
# report arithmetic non-trivial. This emulator contains only synthetic data.
tap_ui "$QA/after-save.xml" content-desc 'إضافة معاملة'
sleep 2
dump_ui chooser-income
tap_ui "$QA/chooser-income.xml" text 'إضافة يدوية'
sleep 3
dump_ui income-editor
tap_ui "$QA/income-editor.xml" text 'دخل'
sleep 2
dump_ui income-selected
tap_ui "$QA/income-selected.xml" edit 0
adb shell input text '580'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui income-amount
tap_ui "$QA/income-amount.xml" edit 1
adb shell input text 'QAINCOME26'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui income-filled
tap_ui "$QA/income-filled.xml" text 'إضافة المعاملة'
sleep 6
dump_ui both-transactions


# Seed one prior-month transaction by changing the DATE of an expense
# previously created through official UI on a disposable emulator only.
# This isolates report boundary rendering without modifying source or user data.
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" "$QA/previous-month.txt" <<'PY'
import sqlite3,sys,datetime,calendar
db=sqlite3.connect(sys.argv[1])
rows=db.execute("SELECT id,type,category,amount,date FROM transactions WHERE category IN ('QA2026','QAINCOME26')").fetchall()
assert len(rows)==2,rows
expense=[r for r in rows if r[2]=='QA2026']
income=[r for r in rows if r[2]=='QAINCOME26']
assert len(expense)==len(income)==1,rows
id_,kind,cat,amount,date=expense[0]
assert kind=='expense' and abs(amount-123)<.001
assert income[0][1]=='income' and abs(income[0][3]-580)<.001
year,mon=map(int,date[:7].split('-'))
py,pm=(year-1,12) if mon==1 else (year,mon-1)
previous=f'{py:04d}-{pm:02d}-10'
db.execute("UPDATE transactions SET date=? WHERE id=?",(previous,id_))
db.commit()
db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
db.close()
open(sys.argv[2],'w').write(previous[:7])
print('Fixture: seeded QA2026 in previous month, income in current month')
PY
adb shell 'stat -c "%u:%g" /data/user/0/com.masarefy.app/databases/masarefy.db' | tr -d '\r\n' > "$QA/db-owner.txt"
owner="$(cat "$QA/db-owner.txt")"
adb push "$QA/masarefy.db" /data/user/0/com.masarefy.app/databases/masarefy.db >/dev/null
adb shell "rm -f /data/user/0/com.masarefy.app/databases/masarefy.db-wal /data/user/0/com.masarefy.app/databases/masarefy.db-shm; chown '$owner' /data/user/0/com.masarefy.app/databases/masarefy.db; chmod 600 /data/user/0/com.masarefy.app/databases/masarefy.db"
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm" "$QA/db-owner.txt"

adb shell am start -n com.masarefy.app/.MainActivity
sleep 8
dump_ui home-after-fixture
tap_ui "$QA/home-after-fixture.xml" text 'التقارير'
sleep 5
dump_ui current-month-report
adb exec-out screencap -p > "$QA/current-month-report.png"

# Expect current month income=580, zero expenses, net=580.
python3 - "$QA/current-month-report.xml" <<'PY'
import sys,xml.etree.ElementTree as ET,re,unicodedata
texts=[n.attrib.get('text','') for n in ET.parse(sys.argv[1]).getroot().iter('node')]
assert 'صافي الشهر' in texts
money=[s for s in texts if 'ج.م' in s]
norm=lambda s:''.join(str(unicodedata.digit(ch)) if ch.isdigit() else ch for ch in s).replace(',','').replace('٬','')
assert any(re.search(r'(?<!\d)580(?:\.0+)?(?!\d)',norm(x)) for x in money),money
assert not any(re.search(r'(?<!\d)123(?:\.0+)?(?!\d)',norm(x)) for x in money),'Previous-month expense leaked into current month'
PY
tap_ui "$QA/current-month-report.xml" text 'السابق'
sleep 5
dump_ui previous-month-report
adb exec-out screencap -p > "$QA/previous-month-report.png"
python3 - "$QA/previous-month-report.xml" "$QA/multimonth-verification.txt" <<'PY'
import sys,xml.etree.ElementTree as ET,re,unicodedata
texts=[n.attrib.get('text','') for n in ET.parse(sys.argv[1]).getroot().iter('node')]
assert 'صافي الشهر' in texts
money=[s for s in texts if 'ج.م' in s]
norm=lambda s:''.join(str(unicodedata.digit(ch)) if ch.isdigit() else ch for ch in s).replace(',','').replace('٬','').replace('−','-')
assert any(re.search(r'(?<!\d)123(?:\.0+)?(?!\d)',norm(x)) for x in money),f'Prior expense missing: {money}'
assert not any(re.search(r'(?<!\d)580(?:\.0+)?(?!\d)',norm(x)) for x in money),f'Current income leaked into previous: {money}'
assert any(re.search(r'(?<!\d)-123(?:\.0+)?(?!\d)',norm(x)) for x in money),f'Expected -123 previous net: {money}'
open(sys.argv[2],'w').write('PASS: official APK report boundaries: current month income EGP 580 and no prior expense; previous month expense EGP 123 and net -123, with no current income.\n')
PY
cat "$QA/multimonth-verification.txt"

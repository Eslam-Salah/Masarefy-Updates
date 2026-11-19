#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-search-reports"
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

# Confirm two different transactions are displayed before testing filters.
python3 - "$QA/both-transactions.xml" <<'PY'
import sys,xml.etree.ElementTree as E
txt=[n.attrib.get('text','') for n in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'QA2026' in txt and 'QAINCOME26' in txt, 'Both synthetic transactions must be visible'
PY

# Search should match the expense category only.
# List scroll is preserved after adding an item; return to the search toolbar.
for attempt in 1 2 3 4 5; do
  dump_ui "search-ready-$attempt"
  if grep -Fq 'text="بحث داخل السجل المعروض"' "$QA/search-ready-$attempt.xml"; then break; fi
  adb shell input swipe 550 750 550 1670 450
  sleep 2
done
grep -Fq 'text="بحث داخل السجل المعروض"' "$QA/search-ready-$attempt.xml"
tap_ui "$QA/search-ready-$attempt.xml" text 'بحث داخل السجل المعروض'
adb shell input text 'QA2026'
adb shell input keyevent KEYCODE_BACK
sleep 4
dump_ui search-expense
python3 - "$QA/search-expense.xml" <<'PY'
import sys,xml.etree.ElementTree as E
nodes=list(E.parse(sys.argv[1]).getroot().iter('node'))
texts=[x.attrib.get('text','') for x in nodes]
assert 'QA2026' in texts, 'Expected matching expense in search'
assert 'QAINCOME26' not in texts, 'Unmatched income leaked into search results'
PY

tap_ui "$QA/search-expense.xml" content-desc 'مسح البحث'
sleep 3
dump_ui search-cleared
tap_ui "$QA/search-cleared.xml" text 'الدخل'
sleep 3
dump_ui only-income
python3 - "$QA/only-income.xml" <<'PY'
import sys,xml.etree.ElementTree as E
texts=[x.attrib.get('text','') for x in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'QAINCOME26' in texts and 'QA2026' not in texts, 'Income filter returned unexpected transactions'
PY

tap_ui "$QA/only-income.xml" text 'المصروفات'
sleep 3
dump_ui only-expense
python3 - "$QA/only-expense.xml" <<'PY'
import sys,xml.etree.ElementTree as E
texts=[x.attrib.get('text','') for x in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'QA2026' in texts and 'QAINCOME26' not in texts, 'Expense filter returned unexpected transactions'
PY

# Return to all transactions before opening Reports.
tap_ui "$QA/only-expense.xml" text 'كل المعاملات'
sleep 2
dump_ui all-after-filters
tap_ui "$QA/all-after-filters.xml" text 'التقارير'
sleep 5
dump_ui reports-top
adb exec-out screencap -p > "$QA/reports-top.png"
python3 - "$QA/reports-top.xml" "$QA/report-verification.txt" <<'PY'
import sys,xml.etree.ElementTree as E,re,unicodedata
texts=[n.attrib.get('text','') for n in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'صافي الشهر' in texts, 'Report net heading absent'
def moneys():
    rows=[]
    for s in texts:
        if 'ج.م' not in s: continue
        digits=''.join(str(unicodedata.digit(ch)) if ch.isdigit() else ch for ch in s)
        digits=digits.replace(',','').replace('٬','').replace('−','-')
        nums=re.findall(r'[-+]?\d+(?:\.\d+)?',digits)
        if nums: rows.append((float(nums[0]),s))
    return rows
amounts=moneys()
assert any(abs(v-457)<0.001 for v,_ in amounts), f'Missing expected net EGP 457: {amounts!r}'
assert any(abs(v-580)<0.001 for v,_ in amounts), f'Missing income EGP 580: {amounts!r}'
assert any(abs(v-123)<0.001 for v,_ in amounts), f'Missing expense EGP 123: {amounts!r}'
open(sys.argv[2],'w').write('PASS: signed APK search and income/expense filters isolate correct transactions; Reports displays income EGP 580, expense EGP 123, net EGP 457.\n')
PY

# Check persisted SQLite separately; do not upload database bytes.
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" >> "$QA/report-verification.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
rows=db.execute("SELECT type,category,amount,date FROM transactions WHERE category IN ('QA2026','QAINCOME26')").fetchall()
assert len(rows)==2, rows
exp=[float(r[2]) for r in rows if r[0]=='expense']
inc=[float(r[2]) for r in rows if r[0]=='income']
assert exp==[123.] and inc==[580.],rows
assert len({r[3][:7] for r in rows})==1, 'Transactions must be in same report month'
print('PASS: Room expense/income totals and month match report assertions.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/report-verification.txt"

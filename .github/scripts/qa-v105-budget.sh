#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-budget"
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


# Budget settings on the current month for exactly one saved synthetic expense.
tap_ui "$QA/after-save.xml" text 'الإعدادات'
sleep 3
for n in 1 2 3 4 5 6; do
  dump_ui "settings-budget-$n"
  if grep -Fq 'text="الميزانية"' "$QA/settings-budget-$n.xml"; then break; fi
  adb shell input swipe 500 1700 500 650 420
  sleep 2
done
grep -Fq 'text="الميزانية"' "$QA/settings-budget-$n.xml"
tap_ui "$QA/settings-budget-$n.xml" text 'الميزانية'
sleep 4
dump_ui budget-before
grep -Fq 'text="الميزانية العامة"' "$QA/budget-before.xml"
tap_ui "$QA/budget-before.xml" edit 0
adb shell input text '1000'
adb shell input keyevent KEYCODE_BACK
sleep 2
dump_ui budget-filled
adb exec-out screencap -p > "$QA/budget-filled.png"
tap_ui "$QA/budget-filled.xml" text 'حفظ الميزانية'
sleep 5
dump_ui budget-saved
adb exec-out screencap -p > "$QA/budget-saved.png"

# Assert the real persistent Room budget for the same month as the expense.
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db' "$QA/masarefy.db" >/dev/null
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-wal' "$QA/masarefy.db-wal" >/dev/null || true
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-shm' "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/budget-verification.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
assert db.execute('pragma user_version').fetchone()[0]==11
rows=db.execute("SELECT type,amount,date FROM transactions WHERE category='QA2026'").fetchall()
assert len(rows)==1,rows
type_,amount,date=rows[0]
assert type_=='expense' and abs(amount-123)<0.001,rows
month=date[:7]
budgets=db.execute('SELECT monthKey,budget,budgetExclusion FROM monthly_budgets WHERE monthKey=?',(month,)).fetchall()
assert len(budgets)==1,budgets
key,budget,excluded=budgets[0]
assert abs(budget-1000)<0.001 and abs(excluded)<0.001,budgets
assert abs((budget-amount)-877)<0.001
print('PASS: signed APK saved EGP 1,000 monthly budget, EGP 123 expense, available EGP 877; Room month and exclusions correct.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/budget-verification.txt"

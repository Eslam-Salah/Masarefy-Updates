#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-finance-crud"
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


verify_state() {
  local stage="$1"
  adb shell am force-stop com.masarefy.app
  adb root >/dev/null
  adb wait-for-device
  adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db' "$QA/masarefy.db" >/dev/null
  adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-wal' "$QA/masarefy.db-wal" >/dev/null || true
  adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-shm' "$QA/masarefy.db-shm" >/dev/null || true
  python3 - "$QA/masarefy.db" "$stage" >> "$QA/finance-crud-results.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
stage=sys.argv[2]
rows=db.execute("SELECT type,name,amount,category,uid FROM transactions WHERE category LIKE 'QA%' ORDER BY id").fetchall()
assert db.execute('PRAGMA user_version').fetchone()[0]==11,'unexpected Room database version'
if stage=='edited':
    assert len(rows)==1, f'Expected one row after edit, got {rows!r}'
    type_,name,amount,category,uid=rows[0]
    assert type_=='expense' and name=='QAEDIT26' and category=='QAEDIT26' and abs(amount-321)<1e-6,rows
    assert isinstance(uid,str) and len(uid)>10, 'missing stable transaction UID'
elif stage=='deleted':
    assert len(rows)==0, f'Expected zero QA rows after delete, got {rows!r}'
elif stage=='income':
    assert len(rows)==1, f'Expected one income and no old expense, got {rows!r}'
    type_,name,amount,category,uid=rows[0]
    assert type_=='income' and name=='QAINCOME26' and category=='QAINCOME26' and abs(amount-580)<1e-6,rows
    assert isinstance(uid,str) and len(uid)>10
else: raise AssertionError('Unknown test stage')
print('PASS:',stage,'persisted state verified in signed app Room database')
PY
  rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
}

# Update the exact sole expense using the user's edit action.
dump_ui expense-list
tap_ui "$QA/expense-list.xml" content-desc 'تعديل'
sleep 3
dump_ui edit-form
grep -Fq 'text="تعديل المعاملة"' "$QA/edit-form.xml"

tap_ui "$QA/edit-form.xml" edit 0
adb shell input keyevent KEYCODE_MOVE_END
for n in 1 2 3 4 5 6; do adb shell input keyevent KEYCODE_DEL; done
adb shell input text '321'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui edit-amount
tap_ui "$QA/edit-amount.xml" edit 1
adb shell input keyevent KEYCODE_MOVE_END
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do adb shell input keyevent KEYCODE_DEL; done
adb shell input text 'QAEDIT26'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui edit-filled
tap_ui "$QA/edit-filled.xml" text 'حفظ التعديلات'
sleep 5
dump_ui after-edit
grep -Fq 'text="QAEDIT26"' "$QA/after-edit.xml"
verify_state edited
echo 'PASS: editing expense changed the persisted amount and category' 

# Reopen app and find Transactions via bottom navigation (text can occur in header too).
adb shell am start -n com.masarefy.app/.MainActivity
sleep 5
dump_ui reopened
read -r tx ty < <(python3 - "$QA/reopened.xml" <<'PY'
import re,sys,xml.etree.ElementTree as E
nodes=list(E.parse(sys.argv[1]).getroot().iter('node'))
matches=[n for n in nodes if n.attrib.get('text')=='المعاملات']
if not matches: raise SystemExit('Missing Transactions bottom tab')
n=max(matches,key=lambda n:int(re.findall(r'\d+',n.attrib['bounds'])[1]))
a,b,c,d=map(int,re.findall(r'\d+',n.attrib['bounds']))
print((a+c)//2,(b+d)//2)
PY
)
adb shell input tap "$tx" "$ty"
sleep 3
dump_ui before-delete
grep -Fq 'text="QAEDIT26"' "$QA/before-delete.xml"
tap_ui "$QA/before-delete.xml" content-desc 'حذف'
sleep 2
dump_ui delete-confirmation
grep -Fq 'text="حذف المعاملة؟"' "$QA/delete-confirmation.xml"
tap_ui "$QA/delete-confirmation.xml" text 'حذف'
sleep 4
dump_ui after-delete
verify_state deleted
echo 'PASS: delete confirmation removed the edited synthetic expense from Room'

# Add synthetic income after deletion, using the actual public APK's manual form.
adb shell am start -n com.masarefy.app/.MainActivity
sleep 5
dump_ui income-start
tap_ui "$QA/income-start.xml" content-desc 'إضافة معاملة'
sleep 2
dump_ui income-chooser
tap_ui "$QA/income-chooser.xml" text 'إضافة يدوية'
sleep 3
dump_ui income-form
tap_ui "$QA/income-form.xml" text 'دخل'
sleep 1
dump_ui income-type-selected
tap_ui "$QA/income-type-selected.xml" edit 0
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
dump_ui after-income
grep -Fq 'text="QAINCOME26"' "$QA/after-income.xml"
verify_state income
echo 'PASS: signed official v1.0.5 APK created an income of EGP 580 after edit-and-delete expense flow'
cat "$QA/finance-crud-results.txt"

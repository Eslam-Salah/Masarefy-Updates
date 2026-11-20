#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-split-remove"
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


# Create an expense of EGP 500 split into EGP 200 and EGP 300. The
# published APK itself performs validation; no direct database writes.
tap_ui "$QA/editor-form.xml" edit 0
adb shell input text '500'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui split-seed-amount
tap_ui "$QA/split-seed-amount.xml" edit 1
adb shell input text 'QASPLIT26'
adb shell input keyevent KEYCODE_BACK
sleep 2
dump_ui split-seed-filled
tap_ui "$QA/split-seed-filled.xml" text 'تقسيم المبلغ'
sleep 4
dump_ui split-editor

tap_ui "$QA/split-editor.xml" edit 0
adb shell input text '200'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui part1-amount
tap_ui "$QA/part1-amount.xml" edit 1
adb shell input text 'ALPHA'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui part1-note
tap_ui "$QA/part1-note.xml" edit 2
adb shell input text '300'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui part2-amount
tap_ui "$QA/part2-amount.xml" edit 3
adb shell input text 'BETA'
adb shell input keyevent KEYCODE_BACK
sleep 2
dump_ui split-ready
adb exec-out screencap -p > "$QA/split-ready.png"
tap_ui "$QA/split-ready.xml" text 'حفظ التقسيم'
sleep 3
dump_ui transaction-with-splits
tap_ui "$QA/transaction-with-splits.xml" text 'إضافة المعاملة'
sleep 8
dump_ui after-split-save
adb exec-out screencap -p > "$QA/after-split-save.png"


# Remove all split lines via the official editor and save, keeping parent total.
tap_ui "$QA/after-split-save.xml" content-desc 'تعديل'
sleep 4
dump_ui edit-before-removal
grep -Fq 'text="تعديل المعاملة"' "$QA/edit-before-removal.xml"
tap_ui "$QA/edit-before-removal.xml" text 'المبلغ موزع على 2 بنود'
sleep 3
dump_ui split-removal-dialog
grep -Fq 'text="إلغاء التقسيم"' "$QA/split-removal-dialog.xml"
tap_ui "$QA/split-removal-dialog.xml" text 'إلغاء التقسيم'
sleep 2
dump_ui unsplit-editor
grep -Fq 'text="تقسيم المبلغ"' "$QA/unsplit-editor.xml"
tap_ui "$QA/unsplit-editor.xml" text 'حفظ التعديلات'
sleep 7
dump_ui after-unsplit-save

adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db "$QA/masarefy.db" >/dev/null
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-wal "$QA/masarefy.db-wal" >/dev/null || true
adb pull /data/user/0/com.masarefy.app/databases/masarefy.db-shm "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/split-removal-verification.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
tx=db.execute("SELECT uid,type,amount,category FROM transactions WHERE category='QASPLIT26'").fetchall()
assert len(tx)==1,tx
uid,kind,amount,category=tx[0]
assert kind=='expense' and abs(amount-500)<.001
parts=db.execute("SELECT uid,amount FROM transaction_splits WHERE transactionUid=?",(uid,)).fetchall()
assert not parts, f'Unsplit transaction retained split line(s): {parts!r}'
assert db.execute("SELECT count(*) FROM transactions WHERE category='QASPLIT26'").fetchone()[0]==1
print('PASS: official signed APK removed both split lines and kept one EGP 500 parent expense without duplicate transactions.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
cat "$QA/split-removal-verification.txt"

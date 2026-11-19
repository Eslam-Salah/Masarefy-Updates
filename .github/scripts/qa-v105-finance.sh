#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-finance"
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

# Exactly one synthetic expense, on an isolated empty emulator.
# Amount and category are the editor's first two Compose EditText fields.
tap_ui "$QA/editor-before.xml" edit 0
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

# Force-stop and read the *actual* Room database from this disposable emulator.
# A pure unit test or in-memory transaction would not check app persistence.
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db' "$QA/masarefy.db" >/dev/null
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-wal' "$QA/masarefy.db-wal" >/dev/null || true
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-shm' "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/finance-verification.txt" <<'PY'
import sqlite3, sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro', uri=True)
rows=db.execute("SELECT type, name, amount, category FROM transactions WHERE category='QA2026'").fetchall()
assert len(rows)==1, f'Expected one persisted QA2026 transaction; found {len(rows)}'
type_, name, amount, category=rows[0]
assert type_=='expense', f'Incorrect transaction type: {type_}'
assert name=='QA2026', f'Unexpected transaction name: {name}'
assert abs(amount - 123.0)<0.001, f'Incorrect persisted amount: {amount}'
print('PASS: signed public APK persisted exactly one synthetic expense of EGP 123, category QA2026, in Room database.')
PY
cat "$QA/finance-verification.txt"
# Don't upload financial DB files, even though the QA data is synthetic.
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"
echo 'PASS: basic create and persistence finance smoke on isolated Android 14.'

#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-restore"
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


# Navigate to settings via bottom navigation and find backup entry within LazyColumn.
tap_ui "$QA/after-save.xml" text 'الإعدادات'
sleep 3
for attempt in 1 2 3 4 5 6; do
  dump_ui "settings-$attempt"
  if grep -Fq 'text="النسخ الاحتياطي والاستعادة"' "$QA/settings-$attempt.xml"; then
    break
  fi
  adb shell input swipe 500 1700 500 650 420
  sleep 2
done
if ! grep -Fq 'text="النسخ الاحتياطي والاستعادة"' "$QA/settings-$attempt.xml"; then
  echo 'FAIL: Backup entry not reachable from Settings' >&2
  exit 1
fi
tap_ui "$QA/settings-$attempt.xml" text 'النسخ الاحتياطي والاستعادة'
sleep 4
dump_ui backup-first
grep -Fq 'text="إعداد كلمة مرور النسخ"' "$QA/backup-first.xml"
tap_ui "$QA/backup-first.xml" text 'إعداد كلمة مرور النسخ'
sleep 2
dump_ui password-dialog
test_password='QABackup2026Secure'
tap_ui "$QA/password-dialog.xml" edit 0
adb shell input text "$test_password"
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui password-one
tap_ui "$QA/password-one.xml" edit 1
adb shell input text "$test_password"
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui password-two
tap_ui "$QA/password-two.xml" text 'حفظ كلمة المرور'
sleep 4
dump_ui password-set
grep -Fq 'text="إنشاء نسخة مشفرة"' "$QA/password-set.xml"
tap_ui "$QA/password-set.xml" text 'إنشاء نسخة مشفرة'
sleep 12
dump_ui after-backup
adb exec-out screencap -p > "$QA/backup-success.png"
test -s "$QA/backup-success.png"

# MediaStore-backed manual backup MUST have been published into Downloads.
backup_dir='/sdcard/Download/Masarefy/Manual'
mapfile -t names < <(adb shell ls -1 "$backup_dir" | tr -d '\r' | grep -E '^Masarefy_Manual_.*\.mfb$' || true)
if [ "${#names[@]}" -ne 1 ]; then
  echo "FAIL: expected exactly one published encrypted manual backup, found ${#names[@]}" >&2
  exit 1
fi
adb pull "$backup_dir/${names[0]}" "$QA/synthetic-backup.mfb" >/dev/null
test -s "$QA/synthetic-backup.mfb"
java .github/scripts/VerifyMasarefyBackup.java "$QA/synthetic-backup.mfb" "$test_password" > "$QA/encrypted-backup-verification.txt"
cat "$QA/encrypted-backup-verification.txt"
# Never upload even an encrypted backup or copy of the database.
rm -f "$QA/synthetic-backup.mfb"
echo 'PASS: initial encrypted manual backup independently verified.'

# Navigate back from Backup screen to transactions; only synthetic QA data exist.
adb shell input keyevent KEYCODE_BACK
sleep 3
dump_ui settings-return
tap_bottom() {
  local xml="$1" label="$2"
  read -r x y < <(python3 - "$xml" "$label" <<'PY'
import re,sys,xml.etree.ElementTree as ET
nodes=list(ET.parse(sys.argv[1]).getroot().iter('node'))
matches=[n for n in nodes if n.attrib.get('text')==sys.argv[2]]
if not matches: raise SystemExit('Missing bottom navigation tab')
def rect(n):
    vals=list(map(int,re.findall(r'\d+',n.attrib.get('bounds',''))))
    if len(vals)!=4: raise SystemExit('Unexpected Android bounds')
    return vals
n=max(matches,key=lambda n:rect(n)[1])
x1,y1,x2,y2=rect(n)
print((x1+x2)//2,(y1+y2)//2)
PY
  )
  adb shell input tap "$x" "$y"
}

tap_bottom "$QA/settings-return.xml" 'المعاملات'
sleep 3
dump_ui transactions-to-edit
grep -Fq 'text="QA2026"' "$QA/transactions-to-edit.xml"
tap_ui "$QA/transactions-to-edit.xml" content-desc 'تعديل'
sleep 3
dump_ui before-edit
grep -Fq 'text="تعديل المعاملة"' "$QA/before-edit.xml"

# Change the transaction after taking the backup. Restoration must revert this.
tap_ui "$QA/before-edit.xml" edit 0
adb shell input keyevent KEYCODE_MOVE_END
for n in 1 2 3 4 5 6; do adb shell input keyevent KEYCODE_DEL; done
adb shell input text '321'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui amount-edited
tap_ui "$QA/amount-edited.xml" edit 1
adb shell input keyevent KEYCODE_MOVE_END
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do adb shell input keyevent KEYCODE_DEL; done
adb shell input text 'QACHANGED26'
adb shell input keyevent KEYCODE_BACK
sleep 1
dump_ui edited-transaction
tap_ui "$QA/edited-transaction.xml" text 'حفظ التعديلات'
sleep 5
dump_ui after-edit
grep -Fq 'text="QACHANGED26"' "$QA/after-edit.xml"

# Re-open Backup from the Settings screen and select the actual saved .mfb.
tap_bottom "$QA/after-edit.xml" 'الإعدادات'
sleep 3
for attempt in 1 2 3 4 5 6; do
  dump_ui "settings-restore-$attempt"
  if grep -Fq 'text="النسخ الاحتياطي والاستعادة"' "$QA/settings-restore-$attempt.xml"; then
    break
  fi
  adb shell input swipe 500 1700 500 650 420
  sleep 2
done
grep -Fq 'text="النسخ الاحتياطي والاستعادة"' "$QA/settings-restore-$attempt.xml"
tap_ui "$QA/settings-restore-$attempt.xml" text 'النسخ الاحتياطي والاستعادة'
sleep 4
dump_ui backup-restore-menu
grep -Fq 'text="عرض النسخ المحفوظة"' "$QA/backup-restore-menu.xml"
tap_ui "$QA/backup-restore-menu.xml" text 'عرض النسخ المحفوظة'
sleep 3
dump_ui saved-backups-dialog
grep -Fq 'text="النسخ المحفوظة"' "$QA/saved-backups-dialog.xml"
tap_ui "$QA/saved-backups-dialog.xml" text 'فحص'
sleep 5
dump_ui preview-restorable
grep -Fq 'text="مراجعة النسخة"' "$QA/preview-restorable.xml"
grep -Fq 'text="استعادة النسخة"' "$QA/preview-restorable.xml"
adb exec-out screencap -p > "$QA/restore-preview.png"
tap_ui "$QA/preview-restorable.xml" text 'استعادة النسخة'
sleep 12
dump_ui after-restore
adb exec-out screencap -p > "$QA/after-restore.png"

# The original saved snapshot must replace edited financial data, not merge.
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db' "$QA/masarefy.db" >/dev/null
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-wal' "$QA/masarefy.db-wal" >/dev/null || true
adb pull '/data/user/0/com.masarefy.app/databases/masarefy.db-shm' "$QA/masarefy.db-shm" >/dev/null || true
python3 - "$QA/masarefy.db" > "$QA/restore-verification.txt" <<'PY'
import sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
rows=db.execute("SELECT type,name,amount,category,uid FROM transactions WHERE category LIKE 'QA%' ORDER BY id").fetchall()
assert len(rows)==1, f'Unexpected transactions after restore: {rows!r}'
kind,name,amount,category,uid=rows[0]
assert kind=='expense' and name=='QA2026' and category=='QA2026' and abs(amount-123)<1e-6,rows
assert uid and len(uid)>10
print('PASS: encrypted manual backup restored the original EGP 123 expense; edited EGP 321 record was replaced in Room.')
PY
rm -f "$QA/masarefy.db" "$QA/masarefy.db-wal" "$QA/masarefy.db-shm"

# Safety snapshot must preserve the edited pre-restore state for recovery.
mapfile -t safety < <(adb shell ls -1 "$backup_dir" | tr -d '\r' | grep -F 'Masarefy_BeforeRestore_' | grep -F '.mfb' || true)
if [ "${#safety[@]}" -lt 1 ]; then
  echo 'FAIL: no published pre-restore safety backup' >&2
  exit 1
fi
adb pull "$backup_dir/${safety[0]}" "$QA/safety-backup.mfb" >/dev/null
java .github/scripts/VerifyMasarefyBackup.java "$QA/safety-backup.mfb" "$test_password" 'QACHANGED26' > "$QA/safety-verification.txt"
cat "$QA/restore-verification.txt"
cat "$QA/safety-verification.txt"
rm -f "$QA/safety-backup.mfb"
unset test_password
echo 'PASS: restored encrypted backup replaces changed financial data AND pre-restore safety backup decrypts to previous edited state.'

 || true)
if [ "${#safety[@]}" -lt 1 ]; then
  echo 'FAIL: no published pre-restore safety backup' >&2
  exit 1
fi
adb pull "$backup_dir/${safety[0]}" "$QA/safety-backup.mfb" >/dev/null
java .github/scripts/VerifyMasarefyBackup.java "$QA/safety-backup.mfb" "$test_password" 'QACHANGED26' > "$QA/safety-verification.txt"
cat "$QA/restore-verification.txt"
cat "$QA/safety-verification.txt"
rm -f "$QA/safety-backup.mfb"
unset test_password
echo 'PASS: restored encrypted backup replaces changed financial data AND pre-restore safety backup decrypts to previous edited state.'


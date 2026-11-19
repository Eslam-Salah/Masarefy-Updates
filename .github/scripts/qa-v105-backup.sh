#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-backup"
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
unset test_password
echo 'PASS: protected manual backup written to Android Downloads and independently decrypted and authenticated.'

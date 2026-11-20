#!/usr/bin/env bash
set -euo pipefail

QA="${RUNNER_TEMP:?}/qa-v105-advanced-filters"
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

# The list scroll might have moved after creation. Find the compact filter
# icon by Android accessibility semantics rather than fixed screen coordinates.
for attempt in 1 2 3 4 5; do
  dump_ui "filter-ready-$attempt"
  if grep -Fq 'content-desc="فلاتر المعاملات، عدد الفلاتر النشطة 0"' "$QA/filter-ready-$attempt.xml"; then break; fi
  adb shell input swipe 550 750 550 1670 450
  sleep 2
done
grep -Fq 'content-desc="فلاتر المعاملات، عدد الفلاتر النشطة 0"' "$QA/filter-ready-$attempt.xml"
tap_ui "$QA/filter-ready-$attempt.xml" content-desc 'فلاتر المعاملات، عدد الفلاتر النشطة 0'
sleep 3
dump_ui filter-dialog
grep -Fq 'text="فلاتر البحث"' "$QA/filter-dialog.xml"
grep -Fq 'text="QA2026"' "$QA/filter-dialog.xml"
tap_ui "$QA/filter-dialog.xml" text 'QA2026'
sleep 1
dump_ui category-selected
tap_ui "$QA/category-selected.xml" text 'تطبيق'
sleep 4
dump_ui filtered-category

python3 - "$QA/filtered-category.xml" <<'PY'
import sys,xml.etree.ElementTree as E
txt=[n.attrib.get('text','') for n in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'QA2026' in txt,'Expense category not visible after filter'
assert 'QAINCOME26' not in txt,'Other category visible despite category filter'
print('PASS: advanced category filter isolates matching expense transaction')
PY

for attempt in 1 2 3; do
  dump_ui "filter-active-$attempt"
  if grep -Fq 'content-desc="فلاتر المعاملات، عدد الفلاتر النشطة 1"' "$QA/filter-active-$attempt.xml"; then break; fi
  adb shell input swipe 550 750 550 1670 450
  sleep 2
done
tap_ui "$QA/filter-active-$attempt.xml" content-desc 'فلاتر المعاملات، عدد الفلاتر النشطة 1'
sleep 2
dump_ui active-filter-dialog
tap_ui "$QA/active-filter-dialog.xml" text 'إعادة ضبط'
sleep 4
dump_ui filters-cleared
python3 - "$QA/filters-cleared.xml" <<'PY'
import sys,xml.etree.ElementTree as E
txt=[n.attrib.get('text','') for n in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'QA2026' in txt and 'QAINCOME26' in txt,'Reset did not restore all transactions'
print('PASS: advanced filters reset restored all matching month transactions')
PY
# Test range preset from Advanced dialog, with the current-date transactions.
for attempt in 1 2 3; do
  dump_ui "filter-again-$attempt"
  if grep -Fq 'content-desc="فلاتر المعاملات، عدد الفلاتر النشطة 0"' "$QA/filter-again-$attempt.xml"; then break; fi
  adb shell input swipe 550 750 550 1670 450
  sleep 1
done
tap_ui "$QA/filter-again-$attempt.xml" content-desc 'فلاتر المعاملات، عدد الفلاتر النشطة 0'
sleep 2
dump_ui period-dialog
tap_ui "$QA/period-dialog.xml" text '7 أيام'
sleep 1
dump_ui period-selected
tap_ui "$QA/period-selected.xml" text 'تطبيق'
sleep 4
dump_ui period-filtered
python3 - "$QA/period-filtered.xml" <<'PY'
import sys,xml.etree.ElementTree as E
txt=[n.attrib.get('text','') for n in E.parse(sys.argv[1]).getroot().iter('node')]
assert 'QAINCOME26' in txt,'Expected income on first visible viewport'
assert '2 من 2 معاملة' in txt,'7-day preset did not retain both current-day transactions'
assert any('الفترة: ' in s and ' → ' in s for s in txt),'Active date range indicator absent'
PY
# LazyColumn virtualizes offscreen rows. Scroll to the second expense instead
# of assuming all matching transactions appear in one viewport hierarchy.
for attempt in 1 2 3; do
  adb shell input swipe 520 1700 520 690 440
  sleep 2
  dump_ui "period-scrolled-$attempt"
  if grep -Fq 'text="QA2026"' "$QA/period-scrolled-$attempt.xml"; then break; fi
done
grep -Fq 'text="QA2026"' "$QA/period-scrolled-$attempt.xml"
printf '%s\n' 'PASS: category filtering, reset, and last-7-days range preserved both current-day transactions across scrollable viewports.' > "$QA/advanced-filter-results.txt"
cat "$QA/advanced-filter-results.txt"

#!/usr/bin/env bash
set -euo pipefail

QA="$RUNNER_TEMP/qa-v106"
OLD="$QA/Masarefy-v1.0.5.apk"
NEW="$QA/Masarefy-v1.0.6.apk"
mkdir -p "$QA"
test -s "$OLD" && test -s "$NEW"
DB="/data/user/0/com.masarefy.app/databases/masarefy.db"

pull_room() {
  local folder="$1"
  mkdir -p "$folder"
  adb pull "$DB" "$folder/masarefy.db" >/dev/null
  adb pull "$DB-wal" "$folder/masarefy.db-wal" >/dev/null 2>&1 || true
  adb pull "$DB-shm" "$folder/masarefy.db-shm" >/dev/null 2>&1 || true
}

verify_room() {
  local folder="$1"
  python3 - "$folder/masarefy.db" <<'PY'
import sqlite3,sys
d=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro", uri=True)
assert d.execute("PRAGMA user_version").fetchone()[0]==11, "Room schema changed"
cases=[
("transactions","SELECT uid,amount,type FROM transactions WHERE uid='qa-v106-expense'","qa-v106-expense",123.0,"expense"),
("savings_goals","SELECT uid,savedAmount,isActive FROM savings_goals WHERE uid='qa-v106-goal'","qa-v106-goal",450.0,1),
("obligations","SELECT uid,paidAmount,isActive FROM obligations WHERE uid='qa-v106-installment'","qa-v106-installment",200.0,1),
]
for table,sql,uid,amount,state in cases:
    rows=d.execute(sql).fetchall()
    assert len(rows)==1, f"{table}: expected exactly one record, got {rows}"
    assert rows[0][0]==uid and abs(rows[0][1]-amount)<.001 and rows[0][2]==state, rows
assert d.execute("SELECT totalAmount,installmentAmount,totalInstallments,paidInstallments FROM obligations WHERE uid='qa-v106-installment'").fetchone()==(1000.0,100.0,2,2)
assert d.execute("SELECT targetAmount FROM savings_goals WHERE uid='qa-v106-goal'").fetchone()[0]==1000.0
print("PASS: original financial transaction, savings, and outstanding installment retained without duplication")
PY
}

adb wait-for-device
test "$(adb shell getprop sys.boot_completed | tr -d '\r\n ')" = 1
test -z "$(adb shell pm list packages com.masarefy.app | grep -Fx 'package:com.masarefy.app' || true)"
adb install --no-streaming "$OLD"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 15
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
adb shell am force-stop com.masarefy.app
adb root >/dev/null
adb wait-for-device

pull_room "$QA/original"
python3 - "$QA/original/masarefy.db" <<'PY'
import sqlite3,sys,time
db=sqlite3.connect(sys.argv[1])
assert db.execute("pragma user_version").fetchone()[0] == 11
db.execute("pragma wal_checkpoint(truncate)")
db.execute("pragma journal_mode=DELETE")
now=int(time.time()*1000)
db.execute("""INSERT INTO transactions(uid,type,name,amount,category,date,notes,createdAt,updatedAt)
VALUES(?,?,?,?,?,?,?,?,?)""",
("qa-v106-expense","expense","QAV106EXP",123.0,"QAV106","2026-11-20","synthetic upgrade check",now,now))
db.execute("""INSERT INTO savings_goals(uid,title,targetAmount,savedAmount,targetDate,notes,isActive,createdAt,updatedAt)
VALUES(?,?,?,?,?,?,?,?,?)""",
("qa-v106-goal","QAV106GOAL",1000.0,450.0,"2027-12-31","synthetic upgrade check",1,now,now))
db.execute("""INSERT INTO obligations(uid,kind,title,counterparty,totalAmount,paidAmount,installmentAmount,
totalInstallments,paidInstallments,nextDueDate,category,notes,isActive,createdAt,updatedAt)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
("qa-v106-installment","installment","QAV106INSTALL","",1000.0,200.0,100.0,2,2,
"2027-01-31","QAV106","synthetic upgrade check",1,now,now))
db.commit()
db.close()
PY

# This is a dedicated, disposable, ROOTED emulator with synthetic data only.
owner="$(adb shell stat -c '%u:%g' /data/user/0/com.masarefy.app/databases | tr -d '\r\n ')"
[[ "$owner" =~ ^[0-9]+:[0-9]+$ ]]
adb shell rm -f "$DB-wal" "$DB-shm"
adb push "$QA/original/masarefy.db" "$DB" >/dev/null
adb shell chown "$owner" "$DB"
adb shell chmod 600 "$DB"

# Verify the PRE-upgrade installed APK still reads the populated Room DB.
adb shell am start -n com.masarefy.app/.MainActivity
sleep 10
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
adb shell am force-stop com.masarefy.app
pull_room "$QA/pre-upgrade"
verify_room "$QA/pre-upgrade"

# Install new, officially signed APK IN PLACE. Uninstall or clear-data is prohibited.
adb install -r --no-streaming "$NEW"
adb shell dumpsys package com.masarefy.app > "$QA/updated-package.txt"
grep -m1 'versionCode=7' "$QA/updated-package.txt"
adb shell am start -n com.masarefy.app/.MainActivity
sleep 15
adb shell pidof com.masarefy.app | grep -qE '[0-9]+'
adb exec-out screencap -p > "$QA/after-upgrade.png"
test -s "$QA/after-upgrade.png"
adb shell am force-stop com.masarefy.app
pull_room "$QA/post-upgrade"
verify_room "$QA/post-upgrade"

# Never publish even synthetic app database files as CI artifacts.
rm -rf "$QA/original" "$QA/pre-upgrade" "$QA/post-upgrade"
echo 'PASS: v1.0.5 -> v1.0.6 signed in-place upgrade retains 3 distinct financial Room records, amounts, active status, and schema version 11.'

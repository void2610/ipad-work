#!/bin/bash
# xcodebuild の出力からコードの警告を数え、1 件でもあれば失敗にする。App Intents の情報を作る道具の知らせ (使っていないので飛ばした) はコードの警告ではないので数えない
set -uo pipefail
log=$(mktemp)
"$@" > "$log" 2>&1
status=$?
warnings=$(grep -E "\.swift:[0-9]+:[0-9]+: warning:" "$log" | sort -u)
grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$log"
if [ $status -ne 0 ]; then
    grep -E "error:" "$log" | sort -u | head -20
    rm -f "$log"
    exit $status
fi
rm -f "$log"
if [ -n "$warnings" ]; then
    echo "コードの警告があります:" >&2
    echo "$warnings" >&2
    exit 1
fi
echo "コードの警告はありません"

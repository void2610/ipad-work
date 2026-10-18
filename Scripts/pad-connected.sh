#!/bin/bash
# 起動中の Host に iPad が接続していれば終了コード 0 で終わる。引数で Host のプロセス ID を渡すと、そのプロセスだけを調べる
set -uo pipefail
pids=("$@")
[ ${#pids[@]} -eq 0 ] && pids=($(pgrep -x "PadBridge Host"))
for pid in "${pids[@]}"; do
    # Network.framework が受け付けた接続は lsof に TCP として表示されないことがあり、22:05 から接続していた iPad を見落として更新してしまった。Host のログの接続と切断の記録で判定する
    # バックグラウンドの iPad は何日も接続したままでいられるので、固定の期間ではなく Host の起動時刻からログを読む (終了したプロセスを渡したときは直近 24 時間)
    started=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')
    if [ -n "$started" ]; then
        range=(--start "$(date -j -f "%a %b %d %T %Y" "$started" "+%Y-%m-%d %H:%M:%S")")
    else
        range=(--last 24h)
    fi
    last=$(/usr/bin/log show "${range[@]}" --style compact --predicate "processIdentifier == $pid AND subsystem == \"dev.void2610.padbridge.host\" AND category == \"server\"" 2>/dev/null | grep -E "\] (接続: |切断$)" | tail -1)
    case "$last" in *"] 接続: "*) exit 0 ;; esac
    # ヘルパーアプリとの接続はループバックなので、それ以外の接続を iPad とみなす
    if lsof -nP -a -p "$pid" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep TCP | grep -v -e "127.0.0.1" -e "\[::1\]" >/dev/null; then
        exit 0
    fi
done
exit 1

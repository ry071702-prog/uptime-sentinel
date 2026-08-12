#!/bin/bash
# 合成監視: targets.tsv の各URLを叩き、落ちていたら Issue を開き、復旧したら閉じる
#
# 設計:
#   - 200 かつ期待文字列あり = 正常  (期待文字列チェックで「200 だが白画面」も検知)
#   - 失敗は 30秒おいて1回だけリトライ (瞬断でフラップさせない)
#   - 障害 = サイトごとに Issue 1本 (既に開いていれば増やさない)  復旧 = 自動クローズ
#   - Issue にはレスポンスヘッダ等の一次切り分け材料を貼る  深掘り診断は
#     対話セッション (Claude Code) で Issue を読んで行う  この cron は LLM 不使用 ¥0
#   - GitHub の cron は 60日 push が無いと止まるため、月替わりに .keepalive を push する
set -uo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
down=0

while IFS=$'\t' read -r name url expect note; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac
  # タブは IFS 空白扱いで連続すると1つに潰れフィールドがずれるため、
  # 「期待文字列なし」は空欄でなく "-" で表す
  [ "$expect" = "-" ] && expect=""

  ok=1; detail=""; snippet=""
  for attempt in 1 2; do
    resp=$(curl -sS -m 20 -w '\n__META__ %{http_code} %{time_total}s' "$url" 2>&1)
    meta=$(printf '%s' "$resp" | grep '^__META__' | tail -1)
    code=$(printf '%s' "$meta" | awk '{print $2}')
    if [ "$code" = "200" ]; then
      if [ -n "$expect" ] && ! printf '%s' "$resp" | grep -q "$expect"; then
        ok=0; detail="HTTP 200 だが期待文字列「$expect」が本文に無い (白画面/壊れたデプロイの疑い)"
        snippet=$(printf '%s' "$resp" | head -c 300)
      else
        ok=1; detail="HTTP 200 (${meta#__META__ })"
      fi
      break
    fi
    ok=0; detail="HTTP ${code:-error} (${meta:-応答なし})"
    [ "$attempt" = 1 ] && sleep 30
  done

  title="🔴 ${name} が落ちている"
  existing=$(gh issue list --repo "$REPO" --state open --search "\"$title\" in:title" --json number --jq '.[0].number' 2>/dev/null || true)

  if [ "$ok" = 1 ]; then
    if [ -n "$existing" ]; then
      gh issue close "$existing" --repo "$REPO" \
        --comment "復旧を確認: $detail  ($(date -u '+%F %T') UTC)"
      echo "RECOVERED $name"
    else
      echo "OK $name  $detail"
    fi
  else
    down=$((down + 1))
    echo "DOWN $name  $detail"
    if [ -z "$existing" ]; then
      headers=$(curl -sSIv -m 20 "$url" 2>&1 | head -40 || true)
      gh issue create --repo "$REPO" --title "$title" --body "$(printf '%s\n' \
        "| 項目 | 値 |" \
        "|---|---|" \
        "| URL | $url |" \
        "| 症状 | $detail |" \
        "| 検知 (UTC) | $(date -u '+%F %T') |" \
        "| デプロイ元 | $note |" \
        "" \
        "レスポンスヘッダ:" \
        '```' \
        "$headers" \
        '```' \
        "" \
        "${snippet:+ランナーが受信した本文の先頭300字:}" \
        "${snippet:+\`\`\`}" \
        "${snippet:-}" \
        "${snippet:+\`\`\`}" \
        "" \
        "一次切り分け材料は上記  深掘りはローカルの Claude Code でこの Issue を読んで行う  復旧すると自動クローズ")"
    else
      echo "(Issue #$existing が既に開いているため追加起票しない)"
    fi
  fi
done < targets.tsv

# 60日無 push で cron が止まる対策: 月が替わったら .keepalive を push
month=$(date -u '+%Y-%m')
if [ "$(cat .keepalive 2>/dev/null)" != "$month" ]; then
  echo "$month" > .keepalive
  git config user.name "uptime-sentinel"
  git config user.email "actions@users.noreply.github.com"
  git add .keepalive && git commit -m "chore: keepalive $month" && git push || true
fi

echo "done: down=$down / $(grep -cv '^#' targets.tsv) targets"
exit 0

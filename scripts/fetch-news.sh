#!/usr/bin/env bash
# =============================================================================
# fetch-news.sh — Mac 端新闻抓取脚本
# 触发：每晚21:55由 LaunchAgent 运行，在 Claude 选题任务（22:00）之前抓好数据
# 职责：从 AI HOT API 拉取精选资讯 → 写入 news-raw.json 供 Claude 读取
# =============================================================================

set -euo pipefail

WORKSPACE="$HOME/Documents/vibe-coding/HyperFrames"
LOG="$WORKSPACE/scripts/fetch-news.log"
OUTPUT="$WORKSPACE/output/news-raw.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 保持日志不超过 500 行
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 500 ]; then
  tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "========== fetch-news triggered =========="

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 aihot-skill/0.2.0"

# 计算48小时前
SINCE=$(date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)

log "拉取精选资讯，since=$SINCE"

# 拉取精选条目
RESP=$(curl -sf \
  -H "User-Agent: $UA" \
  "https://aihot.virxact.com/api/public/items?mode=selected&since=$SINCE&take=50" \
  2>>"$LOG" || true)

if [ -z "$RESP" ]; then
  log "WARNING: API 返回为空，尝试7天窗口"
  SINCE7=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  RESP=$(curl -sf \
    -H "User-Agent: $UA" \
    "https://aihot.virxact.com/api/public/items?mode=selected&since=$SINCE7&take=50" \
    2>>"$LOG" || true)
fi

if [ -z "$RESP" ]; then
  log "ERROR: API 拉取失败，退出"
  exit 1
fi

COUNT=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo 0)
log "拉取成功，共 $COUNT 条"

# 写入原始数据文件（Claude 选题任务读取此文件）
mkdir -p "$(dirname "$OUTPUT")"
echo "$RESP" > "$OUTPUT"
log "已写入: $OUTPUT"
log "========== fetch-news finished =========="

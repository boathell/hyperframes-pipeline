#!/usr/bin/env bash
# =============================================================================
# HyperFrames process-queue.sh — 夜间 URL 队列处理脚本
# 触发：每晚 23:00 由 LaunchAgent 运行
# 职责：读 output/list.md Pending → 调用 claude 生成项目 → auto-render → 更新 list.md
# =============================================================================

set -euo pipefail

WORKSPACE="$HOME/Documents/vibe-coding/HyperFrames"
LIST="$WORKSPACE/output/list.md"
LOG="$WORKSPACE/scripts/process-queue.log"
PYTHON=$(command -v python3 || true)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 日志轮转
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 800 ]; then
  tail -n 600 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "========== process-queue triggered =========="

# PATH 补丁（兼容 nvm / homebrew）
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 检查 claude CLI
CLAUDE=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE" ]; then
  log "ERROR: claude CLI not found. Install via: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

# ─── 解析 list.md Pending 表 ─────────────────────────────────────────────────
PENDING_TSV=$("$PYTHON" - "$LIST" << 'PYEOF'
import sys, re

list_file = sys.argv[1]
with open(list_file) as f:
    content = f.read()

m = re.search(r'## 待处理 \(Pending\)(.*?)(?=\n## |\Z)', content, re.DOTALL)
if not m:
    sys.exit(0)

for line in m.group(1).split('\n'):
    line = line.strip()
    if not line.startswith('|'):
        continue
    cols = [c.strip() for c in line.strip('|').split('|')]
    if len(cols) < 5:
        continue
    if cols[0] in ('URL', '') or '---' in cols[0]:
        continue
    if not (cols[0].startswith('http://') or cols[0].startswith('https://')):
        continue
    # Pad to 6 columns
    while len(cols) < 6:
        cols.append('')
    print('\t'.join(cols[:6]))
PYEOF
) || true

if [ -z "$PENDING_TSV" ]; then
  log "No pending items. Exit."
  exit 0
fi

# ─── list.md 更新函数 ─────────────────────────────────────────────────────────
# 用法: update_list <action> <url> <proj> <title> <mp4> <reason>
update_list() {
  local action="$1" url="$2" proj="${3:-}" title="${4:-}" mp4="${5:-}" reason="${6:-}"
  "$PYTHON" - "$LIST" "$action" "$url" "$proj" "$title" "$mp4" "$reason" << 'PYEOF'
import sys, re
from datetime import datetime

list_file = sys.argv[1]
action    = sys.argv[2]
url       = sys.argv[3]
proj      = sys.argv[4] if len(sys.argv) > 4 else ""
title     = sys.argv[5] if len(sys.argv) > 5 else ""
mp4       = sys.argv[6] if len(sys.argv) > 6 else ""
reason    = sys.argv[7] if len(sys.argv) > 7 else ""
now       = datetime.now().strftime('%Y-%m-%d %H:%M')

with open(list_file) as f:
    content = f.read()

def remove_row_containing(content, *keywords):
    out = []
    for line in content.split('\n'):
        if (line.strip().startswith('|')
                and not line.strip().startswith('| URL')
                and not line.strip().startswith('| ---')
                and all(k in line for k in keywords if k)):
            continue
        out.append(line)
    return '\n'.join(out)

def add_row_to_section(content, section_header, new_row):
    # Find the separator line (|---|) in the section and insert after it
    idx = content.find(section_header)
    if idx == -1:
        return content + '\n' + new_row
    # Find the separator row (line starting with |---)
    after_header = content[idx:]
    sep_m = re.search(r'\|[-| ]+\|\n', after_header)
    if sep_m:
        insert_pos = idx + sep_m.end()
        return content[:insert_pos] + new_row + '\n' + content[insert_pos:]
    return content

if action == 'to_progress':
    content = remove_row_containing(content, url)
    new_row = f'| {proj} | {url} | {now} |'
    content = add_row_to_section(content, '## 处理中 (In Progress)', new_row)

elif action == 'to_done':
    content = remove_row_containing(content, url, proj)
    new_row = f'| {now} | {title} | {url} | `{mp4}` |'
    content = add_row_to_section(content, '## 已完成 (Done)', new_row)

elif action == 'to_failed':
    content = remove_row_containing(content, url)
    if proj:
        content = remove_row_containing(content, url, proj)
    short_reason = reason[:80] if reason else "unknown error"
    new_row = f'| {url} | {now} | {short_reason} |'
    content = add_row_to_section(content, '## 失败 (Failed)', new_row)

with open(list_file, 'w') as f:
    f.write(content)
PYEOF
}

# ─── 逐条处理 ─────────────────────────────────────────────────────────────────
while IFS=$'\t' read -r URL SIZE SCENES STYLE NOTES ADDED_TIME; do
  # 应用默认值
  [[ -z "$SIZE"   || "$SIZE"   == "-" ]] && SIZE="1920x1080"
  [[ -z "$SCENES" || "$SCENES" == "-" ]] && SCENES="6"
  [[ -z "$STYLE"  || "$STYLE"  == "-" ]] && STYLE="Dark-Tech"

  # 生成唯一项目名
  URL_HASH=$(echo -n "$URL" | md5 | cut -c1-6)
  PROJ_NAME="url-$(date +%Y%m%d)-${URL_HASH}"
  PROJ_DIR="$WORKSPACE/output/$PROJ_NAME"

  log "--- Processing: $URL"
  log "    Project=$PROJ_NAME  Size=$SIZE  Scenes=$SCENES  Style=$STYLE"

  # 移到 In Progress
  update_list to_progress "$URL" "$PROJ_NAME" "" "" "" 2>>"$LOG" || true

  PROMPT_FILE="/tmp/hf-prompt-${PROJ_NAME}.txt"
  OUTPUT_FILE="/tmp/hf-output-${PROJ_NAME}.txt"

  # ── 构建 claude 提示词 ──────────────────────────────────────────────────────
  cat > "$PROMPT_FILE" << PROMPT_EOF
工作区：$WORKSPACE
任务：将以下 URL 的文章制作成 HyperFrames 视频项目。全程不需要向用户确认任何操作。

URL: $URL
项目名: $PROJ_NAME
尺寸: $SIZE（格式 widthxheight，如 1920x1080）
场景数: $SCENES
风格: $STYLE

请严格按以下顺序执行：

1. 获取文章内容
   用 WebFetch 读取 $URL，提取正文（忽略导航、广告、页脚）。
   如果 WebFetch 失败，用 Bash: curl -sL "$URL" | python3 -c "import sys,re; print(re.sub(r'<[^>]+>','',sys.stdin.read()))"

2. 创建项目目录（在 $WORKSPACE/output/ 下执行）
   cd $WORKSPACE/output
   npx hyperframes@0.5.6 init $PROJ_NAME
   cd $PROJ_NAME
   npm install
   mkdir -p assets

3. 写旁白文本（$SCENES 段）
   根据文章写 $SCENES 段中文旁白，每段 50-80 字，口语化，自然流畅。
   保存到 $PROJ_DIR/assets/narration-s1.txt … narration-s${SCENES}.txt
   每个文件只含纯文本，无多余换行。

4. 校对旁白
   检查相邻词/短语重复、生硬表述，修改后覆盖写回各 .txt 文件。

5. 写 index.html
   遵循 $WORKSPACE/PIPELINE.md 中的时序规则：PRE_ROLL=0.5, INTER_GAP=1.2, TAIL=1.5
   估算各段时长：中文字数/5（秒）
   要求：
   - 尺寸 $SIZE，风格 $STYLE，$SCENES 个场景
   - 每场景有入场动画 + blur crossfade 转场
   - 每段旁白：<audio class="clip" id="narr-sN" src="assets/narration-sN.wav" data-start="X" data-duration="Y" data-track-index="N">
   - Timeline 注册：window.__timelines["main"] = tl（paused: true）
   - 安全字体：outfit, poppins, inter, jetbrains-mono
   - 禁止 Math.random() / Date.now() / 任何网络请求

6. 检查并修复
   cd $PROJ_DIR && npm run check
   如有 error，逐一修复直到 0 error。

7. 写 .ready-for-render
   cd $WORKSPACE
   python3 doubao_tts.py --pick-voice > $PROJ_DIR/.ready-for-render
   （文件内容仅为音色名，一行，无换行以外的内容）

8. 最后输出（只输出这一行，严格 JSON 格式）：
   成功：PIPELINE_RESULT: {"status":"done","title":"<视频中文标题，15字以内>"}
   失败：PIPELINE_RESULT: {"status":"failed","reason":"<原因，30字以内>"}
PROMPT_EOF

  # ── 调用 claude ─────────────────────────────────────────────────────────────
  log "  Calling claude (timeout ~30min)..."
  CLAUDE_EXIT=0
  timeout 1800 "$CLAUDE" \
    --print \
    --dangerously-skip-permissions \
    --allowedTools "Bash,Read,Write,Edit,WebFetch,Agent" \
    "$(cat "$PROMPT_FILE")" \
    2>>"$LOG" | tee "$OUTPUT_FILE" >> "$LOG" || CLAUDE_EXIT=$?

  # ── 解析 PIPELINE_RESULT ────────────────────────────────────────────────────
  RESULT_JSON=$("$PYTHON" - "$OUTPUT_FILE" << 'PYEOF'
import sys, json, re

output_file = sys.argv[1]
with open(output_file) as f:
    content = f.read()

for line in reversed(content.strip().split('\n')):
    line = line.strip()
    if line.startswith('PIPELINE_RESULT:'):
        try:
            payload = line[len('PIPELINE_RESULT:'):].strip()
            d = json.loads(payload)
            print(d.get('status', 'failed'))
            print(d.get('title', ''))
            print(d.get('reason', ''))
            sys.exit(0)
        except Exception:
            break

print('failed')
print('')
print('could not parse PIPELINE_RESULT')
PYEOF
) || true

  STATUS=$(echo "$RESULT_JSON" | sed -n '1p')
  TITLE=$(echo "$RESULT_JSON" | sed -n '2p')
  FAIL_REASON=$(echo "$RESULT_JSON" | sed -n '3p')

  if [ "$STATUS" != "done" ]; then
    log "  Claude failed: $FAIL_REASON"
    update_list to_failed "$URL" "$PROJ_NAME" "" "" "${FAIL_REASON:-claude pipeline failed}" 2>>"$LOG" || true
    rm -f "$PROMPT_FILE" "$OUTPUT_FILE"
    continue
  fi

  log "  Claude done. Title: $TITLE"

  # ── 调用 auto-render.sh（TTS + 时序修正 + 渲染）──────────────────────────
  log "  Running auto-render.sh..."
  RENDER_EXIT=0
  bash "$WORKSPACE/scripts/auto-render.sh" >> "$LOG" 2>&1 || RENDER_EXIT=$?

  # ── 检查 MP4 输出 ──────────────────────────────────────────────────────────
  RENDER_FILE=$(ls -t "$PROJ_DIR/renders/"*.mp4 2>/dev/null | head -1 || true)

  if [ -n "$RENDER_FILE" ]; then
    # 验证双流
    STREAMS=$(ffprobe -v quiet -show_streams "$RENDER_FILE" 2>/dev/null | grep "codec_type" || true)
    REL_PATH="${RENDER_FILE#$WORKSPACE/output/}"
    if echo "$STREAMS" | grep -q "video" && echo "$STREAMS" | grep -q "audio"; then
      update_list to_done "$URL" "$PROJ_NAME" "$TITLE" "$REL_PATH" "" 2>>"$LOG" || true
      log "  ✅ Done: $REL_PATH"
    else
      update_list to_failed "$URL" "$PROJ_NAME" "" "" "MP4 missing video or audio stream" 2>>"$LOG" || true
      log "  ❌ MP4 stream validation failed"
    fi
  else
    update_list to_failed "$URL" "$PROJ_NAME" "" "" "render produced no MP4" 2>>"$LOG" || true
    log "  ❌ No MP4 found after render"
  fi

  rm -f "$PROMPT_FILE" "$OUTPUT_FILE"

done <<< "$PENDING_TSV"

log "========== process-queue finished =========="

# 预约明天 02:29 自动唤醒（确保 02:30 定时任务能触发）
NEXT_WAKE=$(date -v+1d -v2H -v29M -v0S '+%m/%d/%Y %H:%M:%S')
sudo pmset schedule wake "$NEXT_WAKE" 2>>"$LOG" && log "Scheduled next wake: $NEXT_WAKE" || true

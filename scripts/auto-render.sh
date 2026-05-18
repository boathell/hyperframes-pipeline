#!/usr/bin/env bash
# =============================================================================
# HyperFrames Auto-Render — Mac 端自动接力脚本
# 触发：LaunchAgent WatchPaths 监测到 output/ 有变化时运行
# 职责：① TTS 合成  ② 用真实时长修正 HTML 时序  ③ npm run render
# =============================================================================

set -euo pipefail

WORKSPACE="$HOME/Documents/vibe-coding/HyperFrames"
LOG="$WORKSPACE/scripts/auto-render.log"
PYTHON=$(command -v python3 || true)

# ---------- 日志 ----------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 保持日志不超过 800 行
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 800 ]; then
  tail -n 600 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "========== auto-render triggered =========="

# ---------- 检查依赖 ----------
if [ -z "$PYTHON" ]; then
  log "ERROR: python3 not found"; exit 1
fi

# 确保 nvm/node 在 PATH 中
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ---------- 遍历待处理项目 ----------
shopt -s nullglob
MARKERS=("$WORKSPACE/output/"*"/.ready-for-render")

if [ ${#MARKERS[@]} -eq 0 ]; then
  log "No ready projects found. Exit."; exit 0
fi

for MARKER in "${MARKERS[@]}"; do
  [ -f "$MARKER" ] || continue

  PROJ_DIR="$(dirname "$MARKER")"
  PROJ_NAME="$(basename "$PROJ_DIR")"
  log "--- Processing: $PROJ_NAME ---"

  # ---------- 读取音色 ----------
  VOICE="$(cat "$MARKER" | tr -d '[:space:]')"
  if [ -z "$VOICE" ]; then
    VOICE=$("$PYTHON" "$WORKSPACE/doubao_tts.py" --pick-voice 2>/dev/null || echo "zh_female_sophie_uranus_bigtts")
  fi
  log "Voice: $VOICE"

  # ---------- 检测场景数 ----------
  SCENE_COUNT=0
  for f in "$PROJ_DIR/assets/narration-s"*.txt; do
    [ -f "$f" ] && SCENE_COUNT=$((SCENE_COUNT + 1))
  done
  if [ "$SCENE_COUNT" -eq 0 ]; then
    log "ERROR: No narration text files. Skipping."; continue
  fi
  log "Scenes: $SCENE_COUNT"

  # ---------- TTS 合成（3 个并行一批）----------
  TTS_OK=1
  for START in $(seq 1 3 "$SCENE_COUNT"); do
    PIDS=()
    for i in $(seq "$START" $((START + 2))); do
      [ "$i" -gt "$SCENE_COUNT" ] && break
      TXT="$PROJ_DIR/assets/narration-s${i}.txt"
      WAV="$PROJ_DIR/assets/narration-s${i}.wav"
      [ -f "$TXT" ] || continue
      log "  TTS S$i start"
      "$PYTHON" "$WORKSPACE/doubao_tts.py" "$(cat "$TXT")" "$WAV" 10 "$VOICE" >>"$LOG" 2>&1 &
      PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do
      wait "$pid" || { log "WARNING: TTS pid $pid failed"; TTS_OK=0; }
    done
  done
  [ "$TTS_OK" -eq 1 ] && log "TTS complete." || log "WARNING: Some TTS segments failed."

  # ---------- 用真实时长修正 HTML 时序 ----------
  log "Recalculating timing from real WAV durations..."
  "$PYTHON" - "$PROJ_DIR" "$SCENE_COUNT" << 'PYEOF'
import sys, re, subprocess

proj = sys.argv[1]
n    = int(sys.argv[2])

PRE_ROLL  = 0.5
INTER_GAP = 1.2
TAIL      = 1.5

# 获取真实时长（ffprobe），回退到估算
def get_dur(wav):
    try:
        out = subprocess.check_output(
            ["ffprobe","-v","quiet","-show_entries","format=duration",
             "-of","csv=p=0", wav], stderr=subprocess.DEVNULL)
        return round(float(out.strip()), 2)
    except Exception:
        return None

durations = []
for i in range(1, n+1):
    wav = f"{proj}/assets/narration-s{i}.wav"
    txt = f"{proj}/assets/narration-s{i}.txt"
    dur = get_dur(wav)
    if dur is None:
        with open(txt) as f:
            chars = len(re.sub(r'[^一-鿿]', '', f.read()))
        dur = round(chars / 5.0, 1)
        print(f"  S{i}: WAV missing, estimated {dur}s")
    else:
        print(f"  S{i}: real {dur}s")
    durations.append(dur)

t = PRE_ROLL
t_narr, t_trans = [], []
for i, d in enumerate(durations):
    t_narr.append(round(t, 2))
    if i < n - 1:
        t_trans.append(round(t + d + 0.2, 2))
    t += d + INTER_GAP
total = round(t - INTER_GAP + TAIL, 1)

print(f"  t_narr  = {t_narr}")
print(f"  t_trans = {t_trans}")
print(f"  total   = {total}s")

# 修正 index.html 中 audio clip 的 data-start / data-duration
html_path = f"{proj}/index.html"
with open(html_path) as f:
    html = f.read()

changed = False
for i in range(n):
    # 匹配 narr-s{i+1} 的 audio 元素，替换 data-start 和 data-duration
    pattern = (
        r'(<audio[^>]+id="narr-s' + str(i+1) + r'"[^>]+'
        r'data-start=")[^"]*("[^>]+data-duration=")[^"]*(")'
    )
    repl = rf'\g<1>{t_narr[i]}\2{durations[i]}\3'
    new_html, count = re.subn(pattern, repl, html)
    if count > 0:
        html = new_html
        changed = True
        print(f"  Patched S{i+1}: start={t_narr[i]} dur={durations[i]}")
    else:
        # 尝试反向属性顺序
        pattern2 = (
            r'(<audio[^>]+id="narr-s' + str(i+1) + r'"[^>]+'
            r'data-duration=")[^"]*("[^>]+data-start=")[^"]*(")'
        )
        repl2 = rf'\g<1>{durations[i]}\2{t_narr[i]}\3'
        new_html, count2 = re.subn(pattern2, repl2, html)
        if count2 > 0:
            html = new_html
            changed = True
            print(f"  Patched S{i+1} (rev order): start={t_narr[i]} dur={durations[i]}")
        else:
            print(f"  WARNING: Could not patch S{i+1} timing in HTML")

if changed:
    with open(html_path, "w") as f:
        f.write(html)
    print("  index.html timing updated.")
else:
    print("  No timing changes applied.")
PYEOF

  # ---------- npm install + render ----------
  cd "$PROJ_DIR"
  log "npm install..."
  npm install --silent >>"$LOG" 2>&1 || { log "ERROR: npm install failed"; rm -f "$MARKER"; continue; }

  log "npm run render..."
  npm run render >>"$LOG" 2>&1 || { log "ERROR: render failed"; rm -f "$MARKER"; continue; }

  # ---------- 验证双流 ----------
  RENDER_FILE=$(ls -t "$PROJ_DIR/renders/"*.mp4 2>/dev/null | head -1 || true)
  if [ -n "$RENDER_FILE" ]; then
    STREAMS=$(ffprobe -v quiet -show_streams "$RENDER_FILE" 2>/dev/null | grep "codec_type" || true)
    if echo "$STREAMS" | grep -q "video" && echo "$STREAMS" | grep -q "audio"; then
      log "✅ SUCCESS: $RENDER_FILE"
    else
      log "⚠️  Missing video or audio stream in $RENDER_FILE"
    fi
  else
    log "ERROR: No MP4 found after render."
  fi

  # ---------- 完成，移除标记 ----------
  rm -f "$MARKER"
  log "Done: $PROJ_NAME"
done

log "========== auto-render finished =========="

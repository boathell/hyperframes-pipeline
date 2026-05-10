# HyperFrames 文章 → 有声 MP4 流水线

## 目录结构

```
HyperFrames/
├── doubao_tts.py       # TTS 合成脚本（自动读 .env）
├── .env                # 豆包 API 凭证 + 音色列表
├── skills-lock.json    # HyperFrames skills 配置
├── output/             # 视频项目目录
│   ├── <project-name>/
│   │   ├── index.html        # 主合成文件
│   │   ├── assets/           # 旁白文本 + WAV 音频
│   │   │   ├── narration-s1.txt / .wav
│   │   │   └── ...
│   │   └── renders/          # 输出 MP4
│   └── ...
└── PIPELINE.md         # 本文档
```

同一份流水线也部署在 Mac Mini（192.168.5.10）：
`/Volumes/exFAT/workspace/hyperframes/`

---

## 流水线概览（旁白优先）

```
文章 URL
  → 1. 读取文章内容（firecrawl scrape）
  → 2. 用户三选（尺寸 / 场景数 / 视觉风格）
  → 3. 写旁白文本（每场景一个 .txt 文件）
  → 4. 旁白校对（LLM 自校验，修复重复/生硬表述）← 新增
  → 5. TTS 合成（doubao_tts.py，项目级固定音色）
  → 6. 自动验收：过短(<70%)扩写重合；过长(>100%)加速重合
  → 7. 计算场景时序（PRE_ROLL / INTER_GAP 公式）
  → 8. 写 index.html（GSAP blur crossfade + 音频 clip）
  → 9. npm run check（0 error）
  → 10. npm run render → MP4
```

---

## 用户三选

每次新项目，在写旁白前先确认：

| 选项 | 规格 |
|------|------|
| **尺寸** | 横屏 1920×1080 / 竖屏 1080×1920 |
| **场景数** | 精简 4 场景（~30s）/ 标准 6 场景（~60s）/ 完整 8 场景（~90s）|
| **视觉风格** | Dark-Tech / Clean-White / Gradient-Tech |

---

## 旁白校对（TTS 前必须执行）

所有 `narration-sN.txt` 写完后，在进 TTS 之前，逐段检查并就地修正。

### 检查项

| 类型 | 示例 | 处理 |
|------|------|------|
| 相邻字词重复 | "这个这个方案"、"了了" | 直接删除多余的 |
| 短语级重复 | "非常非常重要" | 保留一个 |
| 跨句语义重复 | 两句话表达同一意思 | 合并或删除一句 |
| 表述生硬 | 机器翻译腔、不像口语 | 改写为自然中文 |

### 执行方式

读取全部旁白文件，对每段执行检查，发现问题则修正后**覆盖写回** `.txt` 文件，最后输出变更摘要：

```
[校对] S1: 无修改
[校对] S2: "这个这个" → "这个"（相邻重复）
[校对] S3: 第2句与第3句语义重叠，已合并
[校对] S4: 无修改
```

没有任何修改时输出 `[校对] 全部通过，无需修改`，然后进入 TTS 合成。

---

## TTS 合成

```bash
cd output/<project-name>

# 第一步：为本项目选定一个音色（整个项目只执行一次）
VOICE=$(python3 ../../doubao_tts.py --pick-voice)
echo "本项目音色：$VOICE"

# 第二步：所有段使用同一音色合成（3 并发，适合 ≤6 段）
for i in 1 2 3; do
  python3 ../../doubao_tts.py "$(cat assets/narration-s${i}.txt)" assets/narration-s${i}.wav 0 "$VOICE" &
done
wait
# 剩余段同理，继续传入 $VOICE
```

合成完后每段输出 `[VOICE] <音色>`，全部一致。渲染完成后告知用户选中的是哪个音色。

### 修改音色列表

编辑 `.env` 中的 `APP_YINSE`（逗号分隔，不要空格）：

```
APP_YINSE=zh_female_sophie_uranus_bigtts,zh_female_cancan_uranus_bigtts,...
```

---

## 时序推导公式

```python
PRE_ROLL  = 0.5   # 场景出现 → 旁白开始的缓冲
INTER_GAP = 1.2   # 两段旁白之间（转场 0.7s + 前后缓冲 0.5s）
TAIL      = 1.5   # 最后旁白结束 → 视频结束

t = PRE_ROLL
t_narr, t_trans = [], []
for i, d in enumerate(durations):
    t_narr.append(round(t, 2))
    if i < len(durations) - 1:
        t_trans.append(round(t + d + 0.2, 2))  # 转场开始
    t += d + INTER_GAP

total_duration = round(t - INTER_GAP + TAIL, 1)
```

---

## 验收规则

| 检查 | 标准 | 处理 |
|------|------|------|
| 过短 | 实际时长 < 估算窗口 70% | 扩写旁白文本（约翻倍），rate=0 重合成 |
| 过长 | 实际时长 > 估算窗口 100% | 计算 speech_rate 加速重合成 |
| 正常 | 70%–100% | ✓ 直接用 |

speech_rate 计算：`int((actual / max_allowed - 1) * 100) + 8`

---

## 视觉风格

| 风格 | 背景 | Accent | 字体 |
|------|------|--------|------|
| Dark-Tech | `#080C14` | `#00B4D8` 青蓝 | outfit / inter |
| Clean-White | `#FFFFFF` | `#2563EB` 蓝 | outfit / inter |
| Gradient-Tech | `#0D0221→#1A0533` | `#A78BFA` 紫金 | poppins / inter |

**安全字体**（HyperFrames 渲染器已映射）：
`outfit` `poppins` `montserrat` `inter` `lato` `roboto` `open-sans` `nunito`
`jetbrains-mono` `ibm-plex-mono` `space-mono` `oswald` `playfair-display`

⚠ 禁用：`Bricolage Grotesque`（未映射，渲染时被静默替换为其他字体）

---

## 新建项目

```bash
cd output
npx hyperframes@0.5.6 init <project-name>
cd <project-name>
npm install
mkdir -p assets
```

## Lint & 渲染

```bash
npm run check    # 必须 0 error
npm run render   # 输出 renders/<name>_<timestamp>.mp4
```

验证音视频双流：
```bash
ffprobe -v quiet -show_streams renders/*.mp4 | grep codec_type
# 应同时出现 video 和 audio
```

---

## 关键规则（HyperFrames）

1. 有时序的元素必须有 `data-start` + `data-duration` + `data-track-index`
2. `<audio>` clip 必须加 `class="clip"`；视觉场景 div 由 GSAP 管理（不加 class="clip"）
3. Timeline 必须 `{ paused: true }` 并注册：`window.__timelines["main"] = tl`
4. 视频用 `muted`，音频单独 `<audio>` 元素
5. 禁止 `Math.random()` / `Date.now()` / 网络请求（非确定性）
6. 禁止 `repeat: -1`（用 `Math.ceil(duration/cycle)-1` 替代）
7. 多场景必须有转场（blur crossfade），每个场景必须有入场动画，出场动画只在最后一个场景允许

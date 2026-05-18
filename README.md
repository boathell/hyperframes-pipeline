# HyperFrames Pipeline

文字生成有声视频的本地工作流。输入文章 URL，整理成中文旁白，使用豆包 TTS 生成音频，再用 HyperFrames 渲染成 MP4。

当前工作流使用 `hyperframes@latest`。新建项目后会把项目内的 `dev`、`check`、`render`、`publish` 脚本也改为 `hyperframes@latest`，避免脚手架把版本固定到初始化当天的具体版本。

## 目录

```text
.
├── doubao_tts.py        # 豆包 TTS WebSocket 合成脚本
├── .env.example         # TTS 配置模板
├── CLAUDE.md            # Agent 工作区说明
├── PIPELINE.md          # 完整制作流程和视觉规范
├── scripts/             # 自动抓取、队列处理、自动渲染脚本
└── output/              # 生成的视频项目、音频和 MP4（不提交）
```

## 环境要求

- macOS
- Node.js 22+
- `npm` / `npx`
- Python 3
- FFmpeg / FFprobe
- Chrome 或 HyperFrames 可用的 headless browser
- 豆包 TTS 凭证

## 配置

复制配置模板并填入真实凭证：

```bash
cp .env.example .env
```

`.env` 需要包含：

```env
APP_ID=your_app_id
APP_TOKEN=your_app_token
RESOURCE_ID=seed-tts-2.0
APP_YINSE=zh_female_sophie_uranus_bigtts,zh_female_cancan_uranus_bigtts
```

`.env`、`output/`、日志和本地运行状态目录都已在 `.gitignore` 中忽略。

## 新建视频项目

```bash
cd output
npx hyperframes@latest init <project-name>
cd <project-name>
npm pkg set \
  scripts.dev="npx --yes hyperframes@latest preview" \
  scripts.check="npx --yes hyperframes@latest lint && npx --yes hyperframes@latest validate && npx --yes hyperframes@latest inspect" \
  scripts.render="npx --yes hyperframes@latest render" \
  scripts.publish="npx --yes hyperframes@latest publish"
npm install
mkdir -p assets
```

## TTS

在项目目录内合成旁白：

```bash
VOICE=$(python3 ../../doubao_tts.py --pick-voice)
python3 ../../doubao_tts.py "$(cat assets/narration-s1.txt)" assets/narration-s1.wav 0 "$VOICE"
```

一个项目应固定使用同一个 `VOICE`，避免不同片段声音不一致。

## 检查与渲染

```bash
npm run check
npm run render
```

渲染后验证 MP4 同时包含视频流和音频流：

```bash
ffprobe -v quiet -show_streams renders/*.mp4 | grep codec_type
```

应同时看到 `video` 和 `audio`。

## 自动化脚本

- `scripts/fetch-news.sh`：抓取精选资讯，写入 `output/news-raw.json`
- `scripts/pick-news.sh`：选择候选新闻
- `scripts/process-queue.sh`：读取 `output/list.md` 队列，调用 Agent 生成项目
- `scripts/auto-render.sh`：合成 TTS、修正时序、执行渲染
- `scripts/*.plist`：macOS LaunchAgent 示例

## 制作规范

完整规则见 [PIPELINE.md](./PIPELINE.md)，核心约束：

- `<audio>` 必须有 `class="clip"`
- 定时元素必须包含 `data-start`、`data-duration`、`data-track-index`
- GSAP timeline 必须 `{ paused: true }`，并注册到 `window.__timelines["main"]`
- 禁止 `Math.random()`、`Date.now()` 和渲染时网络请求
- 使用 HyperFrames 已映射的安全字体，例如 `outfit`、`poppins`、`inter`

## 安全

不要提交：

- `.env`
- `output/`
- `scripts/*.log`
- 本地缓存或运行状态目录

提交前建议运行：

```bash
git status --short --ignored=matching
```

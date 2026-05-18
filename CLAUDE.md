# HyperFrames 视频流水线工作区

## 环境说明

- **TTS 合成脚本**：工作区根目录下的 `doubao_tts.py`
- **TTS 凭证**：同目录 `.env`（见 `.env.example`），脚本自动读取
- **视频项目**：在 `output/` 下创建，每个项目一个子目录
- **Node / ffmpeg / npx**：需本机已安装（macOS 推荐 Homebrew）

## Skills — 创作前必须调用

| Skill                 | Command              | 使用时机                                       |
| --------------------- | -------------------- | ---------------------------------------------- |
| **hyperframes**       | `/hyperframes`       | 创建或编辑 HTML 合成、音频响应动画              |
| **hyperframes-cli**   | `/hyperframes-cli`   | Dev-loop CLI: init, lint, inspect, preview, render |
| **gsap**              | `/gsap`              | GSAP 动画                                      |
| **css-animations**    | `/css-animations`    | CSS keyframes                                  |

## 流水线（旁白优先）

```
文章 URL → [用户三选] → 写旁白文本 → 旁白校对（LLM 自校验）
         → TTS 合成 → 计算场景时序 → 写 index.html → lint → render
```

详细步骤见 `PIPELINE.md`。

### 新建项目

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

### TTS 合成（从工作区根运行）

```bash
# 在项目目录内调用，脚本路径相对于工作区根
python3 ../../doubao_tts.py "$(cat assets/narration-s1.txt)" assets/narration-s1.wav 0
```

合成完后输出 `[VOICE] <选中音色>`，每次随机从 `.env` 的 `APP_YINSE` 中选取。

### Lint & 渲染

```bash
npm run check    # 必须 0 error
npm run render   # 输出 renders/<name>_<timestamp>.mp4
```

## 关键规则

1. 有时序的元素必须有 `data-start` + `data-duration` + `data-track-index`
2. `<audio>` clip 必须加 `class="clip"`
3. Timeline 必须 `{ paused: true }` 并注册：`window.__timelines["main"] = tl`
4. 禁止 `Math.random()` / `Date.now()` / 网络请求
5. 安全字体：`outfit` `poppins` `inter` `jetbrains-mono` 等（详见 PIPELINE.md）
6. ⚠ 禁用 `Bricolage Grotesque`（渲染器未映射）

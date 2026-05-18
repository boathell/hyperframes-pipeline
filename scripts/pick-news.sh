#!/usr/bin/env bash
# =============================================================================
# pick-news.sh — 设置今晚视频使用的新闻序号
# 用法：bash ~/Documents/vibe-coding/HyperFrames/scripts/pick-news.sh <序号>
# 示例：bash .../pick-news.sh 3   → 选第3条新闻
# =============================================================================

CANDIDATES="$HOME/Documents/vibe-coding/HyperFrames/output/news-candidates.json"

if [ ! -f "$CANDIDATES" ]; then
  echo "❌ 候选文件不存在：$CANDIDATES"
  echo "   请等待晚上10点的选题任务运行后再使用。"
  exit 1
fi

NUM="${1:-}"
if [ -z "$NUM" ]; then
  echo "用法：bash $(basename "$0") <序号>"
  echo ""
  echo "当前候选列表："
  python3 - "$CANDIDATES" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
sel = data.get('selectedIndex', 0)
for i, c in enumerate(data['candidates']):
    mark = "✅" if i == sel else "  "
    print(f"  {mark} {i+1}. {c['title']}")
    print(f"       {c.get('source','')} | {c.get('published','')}")
print(f"\n当前选择：第 {sel+1} 条")
PYEOF
  exit 0
fi

# 验证输入是数字
if ! [[ "$NUM" =~ ^[0-9]+$ ]]; then
  echo "❌ 序号必须是数字，例如：bash $(basename "$0") 2"
  exit 1
fi

# 设置选择
python3 - "$CANDIDATES" "$NUM" << 'PYEOF'
import json, sys

path = sys.argv[1]
num  = int(sys.argv[2])

with open(path) as f:
    data = json.load(f)

total = len(data['candidates'])
if num < 1 or num > total:
    print(f"❌ 序号超出范围，请输入 1~{total} 之间的数字")
    sys.exit(1)

idx = num - 1
data['selectedIndex'] = idx
with open(path, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

c = data['candidates'][idx]
print(f"✅ 已选择第 {num} 条：")
print(f"   标题：{c['title']}")
print(f"   来源：{c.get('source','')} | 发布：{c.get('published','')}")
print(f"   摘要：{c.get('summary','')}")
print(f"\n凌晨1点的视频任务将使用此新闻。")
PYEOF

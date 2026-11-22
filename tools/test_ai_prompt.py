"""AI 提示词回归工具：直接调 DeepSeek 验证解析效果，不必装机。

用法：
    python tools/test_ai_prompt.py [样例编号]

- 提示词从 app/lib/services/ai_service.dart 里正则提取，保证与 App 一致。
- 结果写到 tools/ai_probe_out.txt（PowerShell 会吞 stdout，写文件更可靠）。
"""

import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DART = os.path.join(ROOT, "app", "lib", "services", "ai_service.dart")
OUT = os.path.join(ROOT, "tools", "ai_probe_out.txt")

API_KEY = os.environ.get("DEEPSEEK_KEY", "")
BASE_URL = "https://api.deepseek.com"
MODEL = "deepseek-chat"

if not API_KEY:
    sys.exit("没找到 key。先设环境变量：export DEEPSEEK_KEY=sk-xxx")

# 固定"现在"为 2026-11-21 21:19（周六），便于复现
NOW = "2026-11-21"
WEEKDAY = "六"
HHMM = "21:19"

SAMPLES = {
    "long": """🔔【活动提醒】工学院党委“党旗下的青春”（第四十七期）——东海岸校区新生专场活动
⏰活动时间：2026年11月22日（周日）15:00—17:00
🎯 活动地点：东海岸校区E教101-阶梯教室
参与对象：工学院2026级全体新生（入党申请人如无特殊情况均需参加）
✅请各位报名同学提前10分钟到场签到，仍有意向参加的同学，可填写下方报名问卷：
https://v.wjx.cn/vm/Pc9A5ho.aspx
🔥期待在活动现场见到大家！不见不散~""",
    "multi": "周五17点E栋104考试，周日交作业",
    "short": "12.03E栋103听讲座",
    "course": "每周一早上八点到九点四十高数E104，上到1月15号",
    "relative": "明天下午三点去图书馆还书，后天早上九点半体检",
}


def load_prompt():
    with open(DART, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"static const String systemPrompt = '''(.*?)''';", src, re.S)
    if not m:
        raise SystemExit("未能从 ai_service.dart 提取 systemPrompt")
    prompt = m.group(1)
    return (
        prompt.replace("{TODAY}", NOW)
        .replace("{WEEKDAY}", WEEKDAY)
        .replace("{HHMM}", HHMM)
    )


def call(system_prompt, user_text):
    body = json.dumps(
        {
            "model": MODEL,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_text},
            ],
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE_URL}/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"]


def main():
    picked = sys.argv[1:] or list(SAMPLES)
    system_prompt = load_prompt()
    lines = []
    for name in picked:
        text = SAMPLES[name]
        lines.append("=" * 60)
        lines.append(f"### 样例 {name}")
        lines.append("--- 输入 ---")
        lines.append(text)
        try:
            raw = call(system_prompt, text)
            lines.append("--- 原始返回 ---")
            lines.append(raw)
            parsed = json.loads(raw)
            lines.append("--- 格式化 ---")
            lines.append(json.dumps(parsed, ensure_ascii=False, indent=2))
        except Exception as exc:  # noqa: BLE001
            lines.append(f"!!! 失败：{exc}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"OK -> {OUT}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline inspection report -> LLM review helper.

- Reads a Report_*.json produced by the iOS app.
- Builds a strict, production-friendly prompt (persona + output schema).
- Calls an OpenAI-compatible endpoint (e.g., Baidu AI Studio) via openai SDK.

Security:
- Do NOT hard-code API keys. Use environment variables.

Example:
  pip install openai
  export AI_API_KEY='...'
  export AI_BASE_URL='https://aistudio.baidu.com/llm/lmapi/v3'
  python tools/ai_report_review.py --report /path/to/Report_123.json --model ernie-x1.1-preview
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict

try:
    from openai import OpenAI
except Exception:
    print("Missing dependency: openai. Install with: pip install openai", file=sys.stderr)
    raise


SYSTEM_PERSONA = """你是一名工业锅炉巡检【报告审核与风险研判助手】。

目标：
- 读懂巡检报告字段（温度/压力/水位/阀位/异常状态/备注/附件）。
- 用工程化语言给出：风险点、可能原因、需要立刻做什么、需要补充什么信息。
- 不要编造不存在的现场事实；不确定要明确写“不确定/需补充”。

输出要求（必须严格遵守）：
- 仅输出一个 JSON（不要 Markdown，不要解释，不要多余文字）。
- 字段必须齐全、类型必须正确；没有内容就用空数组/空字符串。

输出 JSON Schema：
{
  "overall_level": "LOW|MEDIUM|HIGH|CRITICAL",
  "one_sentence_summary": "...",
  "key_findings": ["..."],
  "immediate_actions": ["..."],
  "recommended_followups": ["..."],
  "suspected_causes": ["..."],
  "missing_information": ["..."],
  "data_quality_flags": ["..."],
  "checklist": {
    "leakage": {"reported": true/false, "risk": "...", "action": "..."},
    "abnormal_noise": {"reported": true/false, "risk": "...", "action": "..."},
    "vibration": {"reported": true/false, "risk": "...", "action": "..."},
    "smoke_or_steam": {"reported": true/false, "risk": "...", "action": "..."},
    "over_temp_or_pressure": {"reported": true/false, "risk": "...", "action": "..."},
    "alarm_triggered": {"reported": true/false, "risk": "...", "action": "..."}
  }
}
"""


USER_TEMPLATE = """这是一次巡检报告（来自移动端离线巡检 App，字段为字符串或布尔值）。

请根据报告内容输出【严格 JSON】审核结果。

【报告 JSON】\n{report_json}\n
【额外要求】
- 若温度/压力/水位/阀位字段为空字符串，请在 data_quality_flags 标注“读数缺失”。
- 若备注中出现“紧急/停机/危险/严重/爆/火/泄漏”等词，overall_level 至少 MEDIUM，并解释原因。
- 若存在附件文件名（照片或签名），在 data_quality_flags 写明“有附件可核验”；若缺签名则提示“缺签名”。

【现场提问（可选）】\n{question}\n"""


def load_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, help="Path to Report_*.json")
    parser.add_argument("--model", default=os.environ.get("AI_MODEL", "ernie-x1.1-preview"))
    parser.add_argument("--question", default="", help="Optional extra question to ask the model")
    parser.add_argument("--base-url", default=os.environ.get("AI_BASE_URL", "https://aistudio.baidu.com/llm/lmapi/v3"))
    parser.add_argument("--api-key", default=os.environ.get("AI_API_KEY", ""))
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--max-tokens", type=int, default=8192)
    parser.add_argument("--no-stream", action="store_true")
    args = parser.parse_args()

    if not args.api_key:
        print("Missing AI_API_KEY. Set env var or pass --api-key.", file=sys.stderr)
        return 2

    report = load_json(args.report)
    report_json = json.dumps(report, ensure_ascii=False, indent=2)

    user_content = USER_TEMPLATE.format(report_json=report_json, question=args.question or "")

    client = OpenAI(api_key=args.api_key, base_url=args.base_url)

    if args.no_stream:
        resp = client.chat.completions.create(
            model=args.model,
            messages=[
                {"role": "system", "content": SYSTEM_PERSONA},
                {"role": "user", "content": user_content},
            ],
            temperature=args.temperature,
            max_completion_tokens=args.max_tokens,
        )
        print(resp.choices[0].message.content)
        return 0

    stream = client.chat.completions.create(
        model=args.model,
        messages=[
            {"role": "system", "content": SYSTEM_PERSONA},
            {"role": "user", "content": user_content},
        ],
        temperature=args.temperature,
        stream=True,
        max_completion_tokens=args.max_tokens,
        extra_body={"web_search": {"enable": False}},
    )

    for chunk in stream:
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta
        content = getattr(delta, "content", None)
        if content:
            print(content, end="", flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

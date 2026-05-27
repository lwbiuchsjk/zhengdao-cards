#!/usr/bin/env python3
"""
CSV 契约文档完整性检查。

背景：CSV 配置流水线的契约真源是 Design/共享/配置流水线/配置翻译指南.md。
本脚本通过 pre-commit 阻断"误删文档"或"误删关键契约章节"的提交，
保证 CSV 翻译脚本、校验脚本、引擎装配器三端始终能对齐到同一份契约。

检查项：
  1. 契约文档文件存在
  2. 文档包含全部约定的 HTML 锚点对（CSV_CONTRACT_ANCHOR / CSV_CONTRACT_ANCHOR_END）

用法：
  python3 tools/check_csv_contract_docs.py
退出码：0 通过；1 失败（任一检查未过即失败）。
"""

from __future__ import annotations

import sys
from pathlib import Path


# 契约文档路径（相对仓库根）
CONTRACT_DOC = "Design/共享/配置流水线/配置翻译指南.md"

# 必须存在的契约锚点名（同时检查 START 与 END）
REQUIRED_ANCHORS = [
    "resolution_target_routing",
    "rule_types",
    "condition_types",
    "presents_values",
    "presentation_condition",  # 需求 2 新增：event_presentations.csv condition 差分字段
    "option_outcome_text",     # MVP A 新增：option_outcomes.csv 字段约定 + branch fallback 链
    # Line B S1 期新增（2026-05-27）：
    "attribute_categories",    # attribute_names.csv category 合法集合（含 hidden_attribute）
    "ability_progression",     # ability_progression.csv schema（S1 期空表，S4 期填）
]


def find_repo_root() -> Path:
    """返回仓库根目录（含 .git 的最近父目录）。"""
    here = Path(__file__).resolve().parent
    for p in [here, *here.parents]:
        if (p / ".git").exists():
            return p
    # 回退：以脚本所在 tools 目录的父目录为根
    return here.parent


def main() -> int:
    root = find_repo_root()
    doc_path = root / CONTRACT_DOC

    # 1. 文件存在性
    if not doc_path.exists():
        print(f"[CSV 契约检查] 失败：契约真源文档缺失：{CONTRACT_DOC}", file=sys.stderr)
        print(
            "  此文档定义了 CSV 流水线的 target 路由/rule_type/condition_type 契约，"
            "删除会使翻译脚本/校验脚本/引擎装配器失去同步依据。",
            file=sys.stderr,
        )
        print("  若确需删除，请先与项目负责人确认并迁移契约到新位置。", file=sys.stderr)
        return 1

    text = doc_path.read_text(encoding="utf-8")

    # 2. 锚点完整性
    missing: list[str] = []
    for anchor in REQUIRED_ANCHORS:
        start_tag = f"<!-- CSV_CONTRACT_ANCHOR: {anchor} -->"
        end_tag = f"<!-- CSV_CONTRACT_ANCHOR_END: {anchor} -->"
        if start_tag not in text or end_tag not in text:
            missing.append(anchor)

    if missing:
        print(
            f"[CSV 契约检查] 失败：{CONTRACT_DOC} 中以下契约锚点缺失或不完整：",
            file=sys.stderr,
        )
        for anchor in missing:
            print(
                f"  - {anchor}："
                f"需要 `<!-- CSV_CONTRACT_ANCHOR: {anchor} -->` 与 "
                f"`<!-- CSV_CONTRACT_ANCHOR_END: {anchor} -->` 配对",
                file=sys.stderr,
            )
        print(
            "  锚点标记的段落是契约真源的关键章节，误删会破坏"
            "CSV 流水线三件套（translator/validator/engine）的同步契约。",
            file=sys.stderr,
        )
        return 1

    print(
        f"[CSV 契约检查] 通过（文档齐全，{len(REQUIRED_ANCHORS)} 个锚点对完整）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

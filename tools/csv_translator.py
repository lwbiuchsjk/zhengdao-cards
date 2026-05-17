#!/usr/bin/env python3
"""
事件卡 → CSV 机械翻译脚本

功能：读取 Design/events/{stage_dir}/ 下的新格式事件卡（含结构化 frontmatter），
     结合查表文件，自动生成 6 个 CSV 文件到指定配置目录。

覆盖范围（机械映射）：
  - events.csv
  - event_conditions.csv
  - event_presentations.csv
  - options.csv
  - option_rules.csv（cost / check / resolution）

不覆盖（需人工补全）：
  - event_outcomes.csv（骨架事件的 flag 设置，逐卡不同）
  - tasks.csv（骨架专用，数量少）
  - option_outcomes.csv（事件叙事反馈 MVP A，2026-05-09 新增；选项级 outcome 叙事文本，
    按 (option_id, branch) 分组配多屏。该字段不在事件卡 frontmatter 范围内，由 LLM 在
    叙事撰写阶段人工填充。脚本不消费、不产出）

demo 期约束（2026-05-09 [[鉴定 demo 期表现规约]] 决议，软约束不在脚本硬化）：
  - 鉴定相关字段：DC（hitThreshold）demo 期单一 6；鉴定只在骨架事件出现；
    单事件最多 1 个 check 选项；保留 cost spirit 1
  - option_outcomes.csv：demo 期只写 success/fail 两 branch；**不写 critical_success
    / critical_fail**（引擎自动 fallback 到 success/fail）
  - 心性相关：option_rules.csv / event_outcomes.csv 不写 xinxing 字段（心性是行为
    驱动属性，引擎自动累积；demo 期完全不暴露给玩家，详见 [[代码重构_预启动]] §4.1）
  - 重构期约束变更入口：[[鉴定 demo 期表现规约]] §六 维护说明 + [[代码重构_预启动]]
    §4.2 / §4.3

用法：
  python tools/csv_translator.py --cards Design/events/stage_2 --out scripts/config/world_event_mvp
"""

import argparse
import csv
import os
import re
import sys
import yaml
from pathlib import Path
from typing import Any


# ============================================================
# 查表加载
# ============================================================

def load_csv_as_dicts(path: str) -> list[dict[str, str]]:
    """读取 CSV 文件为字典列表。"""
    with open(path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return list(reader)


def build_attribute_map(rows: list[dict[str, str]]) -> dict[str, str]:
    """display_name → internal_key 映射（如 百艺→craft）。"""
    result: dict[str, str] = {}
    for row in rows:
        display = row.get("display_name", "").strip()
        key = row.get("internal_key", "").strip()
        if display and key:
            result[display] = key
    return result


def build_magnitude_map(rows: list[dict[str, str]]) -> dict[str, dict[str, Any]]:
    """
    构建效果量值查表。
    key = (dimension, direction)，value = {"small": int, "large": int, "effect_target": str}
    """
    result: dict[str, dict[str, Any]] = {}
    for row in rows:
        dim = row.get("dimension", "").strip()
        direction = row.get("direction", "").strip()
        result[(dim, direction)] = {
            "small": int(row.get("small", "0")),
            "large": int(row.get("large", "0")),
            "effect_target": row.get("effect_target", "").strip(),
        }
    return result


def build_npc_display_to_id(rows: list[dict[str, str]]) -> dict[str, str]:
    """display_name → role_id 映射（如 秦素娘→npc_qin）。"""
    result: dict[str, str] = {}
    for row in rows:
        display = row.get("display_name", "").strip()
        role_id = row.get("role_id", "").strip()
        if display and role_id:
            result[display] = role_id
    return result


def build_affinity_set(rows: list[dict[str, str]]) -> set[str]:
    """已注册的关系对集合（如 player_001->npc_qin）。"""
    result: set[str] = set()
    for row in rows:
        from_id = row.get("from_role_id", "").strip()
        to_id = row.get("to_role_id", "").strip()
        if from_id and to_id:
            result.add(f"{from_id}->{to_id}")
    return result


# ============================================================
# 事件卡解析
# ============================================================

def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """解析 YAML frontmatter，返回 (metadata, body)。"""
    if not text.startswith("---"):
        return {}, text
    end_idx = text.find("---", 3)
    if end_idx == -1:
        return {}, text
    yaml_text = text[3:end_idx]
    body = text[end_idx + 3:].lstrip("\n")
    try:
        meta = yaml.safe_load(yaml_text) or {}
    except yaml.YAMLError:
        meta = {}
    return meta, body


def parse_event_card(filepath: str) -> dict[str, Any] | None:
    """
    解析单张事件卡，返回结构化数据。
    返回 None 表示该文件不是有效事件卡。
    """
    with open(filepath, encoding="utf-8") as f:
        text = f.read()

    meta, body = parse_frontmatter(text)
    event_id = meta.get("event_id", "")
    if not event_id:
        return None

    card: dict[str, Any] = {
        "event_id": event_id,
        "meta": meta,
        "title": "",
        "presentations": [],
        "options": [],
    }

    # 提取标题（# event_id：标题 格式）
    title_match = re.search(r"^#\s+\S+[：:]\s*(.+)$", body, re.MULTILINE)
    if title_match:
        card["title"] = title_match.group(1).strip()

    # 提取叙事段落（> 开头的引用块）
    # 只取"## 叙事段落"和"## 选项"之间的引用块
    narrative_section = re.search(
        r"##\s*叙事段落\s*\n(.*?)(?=\n##\s)", body, re.DOTALL
    )
    if narrative_section:
        section_text = narrative_section.group(1)
        # 提取连续的 > 行组成的段落
        paragraphs: list[str] = []
        current_para_lines: list[str] = []
        for line in section_text.split("\n"):
            stripped = line.strip()
            if stripped.startswith(">"):
                # 去掉 > 前缀
                content = stripped.lstrip(">").strip()
                if content:
                    current_para_lines.append(content)
            else:
                if current_para_lines:
                    paragraphs.append(" ".join(current_para_lines))
                    current_para_lines = []
        if current_para_lines:
            paragraphs.append(" ".join(current_para_lines))
        card["presentations"] = paragraphs

    # 提取选项
    options_section = re.search(r"##\s*选项\s*\n(.*)", body, re.DOTALL)
    if options_section:
        card["options"] = parse_options(options_section.group(1))

    return card


def parse_options(text: str) -> list[dict[str, Any]]:
    """解析选项区，返回选项列表。"""
    # 按 ### 选项 N 拆分
    option_blocks = re.split(r"###\s+选项\s*\d+\s*[：:]\s*", text)
    options: list[dict[str, Any]] = []

    for block in option_blocks[1:]:  # 第一个是空或前导文本
        opt = parse_single_option(block)
        if opt:
            options.append(opt)
    return options


def parse_single_option(block: str) -> dict[str, Any] | None:
    """解析单个选项块。"""
    lines = block.split("\n")
    if not lines:
        return None

    # 第一行是选项文本
    opt_text = lines[0].strip()

    opt: dict[str, Any] = {
        "text": opt_text,
        "precondition": "",
        "cost": "",
        "check": "",
        "effects": [],
        "narrative_outcome": "",
    }

    # 逐行解析配置字段
    i = 1
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith("- 前提：") or line.startswith("- 前提:"):
            opt["precondition"] = line.split("：", 1)[-1].split(":", 1)[-1].strip()
        elif line.startswith("- 代价：") or line.startswith("- 代价:"):
            opt["cost"] = line.split("：", 1)[-1].split(":", 1)[-1].strip()
        elif line.startswith("- 检定：") or line.startswith("- 检定:"):
            opt["check"] = line.split("：", 1)[-1].split(":", 1)[-1].strip()
        elif line.startswith("- 后果方向：") or line.startswith("- 后果方向:"):
            # 后续缩进行是效果
            effects: list[str] = []
            i += 1
            while i < len(lines):
                eline = lines[i]
                stripped = eline.strip()
                # 效果行以 - 开头且有缩进（属于后果方向子项）
                if stripped.startswith("- ") and (eline.startswith("  ") or eline.startswith("\t")):
                    effects.append(stripped.lstrip("- ").strip())
                elif stripped.startswith("- 叙事后果") or stripped.startswith("- 备注"):
                    break
                elif stripped.startswith("- "):
                    # 其他顶级字段，退出
                    break
                else:
                    if stripped and not stripped.startswith("*"):
                        effects.append(stripped)
                i += 1
            opt["effects"] = effects
            continue  # 不再 i += 1
        elif line.startswith("- 叙事后果：") or line.startswith("- 叙事后果:"):
            # 取冒号后的文本，忽略原始设计斜体行
            outcome = line.split("：", 1)[-1].split(":", 1)[-1].strip()
            opt["narrative_outcome"] = outcome

        i += 1

    return opt


# ============================================================
# 效果表达式解析
# ============================================================

# 标准术语到 (dimension, direction) 的映射
EFFECT_PATTERNS: list[tuple[str, str, str, str]] = [
    # (正则, dimension, direction, key_source)
    # key_source: "attr" 需要从属性名提取 key，"fixed" 直接使用 dimension 对应的 key
]

def parse_effect_expression(
    expr: str,
    attr_map: dict[str, str],
    magnitude_map: dict[str, dict[str, Any]],
    npc_display_to_id: dict[str, str],
) -> dict[str, Any] | None:
    """
    解析效果标准术语表达式，返回 CSV 字段值。

    【CSV 契约边界】本函数的 target/op/key/value 产出是 CSV 契约三件套的 "自动翻译" 端。
    契约真源：Design/配置翻译指南.md（锚点 resolution_target_routing）。
    修改本函数的产出格式时，必须同步回看：
      1. Design/配置翻译指南.md（resolution target/op/key/value 映射表）
      2. tools/csv_validator.py（target/key 校验规则，特别是规则 7）
      3. scripts/systems/world_event_config_assembler.gd::_apply_effect_or_resolution_action

    示例输入：
      "百艺积累小"      → {target: "player",   op: "add", key: "craft",  value: 1}
      "心气消耗大"      → {target: "player",   op: "add", key: "spirit", value: -3}
      "心性偏向+小"     → {target: "player",   op: "add", key: "xinxing", value: 1}
      "秦素娘.信任提升小" → {target: "affinity", op: "",    key: "affinityDeltas",
                          value: "player_001->npc_qin:+5"}
      "npc_qin.信任提升小" → 同上（新格式用 npc_id）

    target 语义（必须与引擎装配器对齐，参见 scripts/systems/world_event_config_assembler.gd）：
      - target=player   → RoleState 属性/资源（attribute_names.csv 白名单）
      - target=affinity → 关系变动，key 固定为 affinityDeltas，value 为 "from->to:±N;..." 段
      - target=params   → 世界参数（prosperity/morale/danger 等自由命名计数器），本函数不产出
    """
    expr = expr.strip()
    if not expr or expr == "维持":
        return None

    # 关系效果：xxx.信任提升/下降 小/大
    rel_match = re.match(r"(.+)\.(信任)(提升|下降)(小|大)$", expr)
    if rel_match:
        npc_ref = rel_match.group(1).strip()
        direction = "increase" if rel_match.group(3) == "提升" else "decrease"
        magnitude = rel_match.group(4)

        # 尝试直接作为 npc_id 使用，或通过显示名查找
        npc_id = npc_ref
        if npc_ref in npc_display_to_id:
            npc_id = npc_display_to_id[npc_ref]

        mag_entry = magnitude_map.get(("trust", direction))
        if mag_entry:
            value = mag_entry["small"] if magnitude == "小" else mag_entry["large"]
            # value 已带方向正负号；组装成 "player_001->npc_x:±N" 的单段 affinityDeltas 文本，
            # 后续在 generate_option_rules_csv 中按 (option_id, branch) 合并为分号分隔串。
            signed = f"+{value}" if value >= 0 else str(value)
            return {
                "target": "affinity",
                "op": "",
                "key": "affinityDeltas",
                "value": f"player_001->{npc_id}:{signed}",
            }

    # 关系维持
    rel_maintain = re.match(r"(.+)\.(信任)维持$", expr)
    if rel_maintain:
        return None  # 维持 = 无效果

    # 心性效果：心性偏向+小/大 或 心性偏向-小/大
    xinxing_match = re.match(r"心性偏向([+\-])(小|大)$", expr)
    if xinxing_match:
        direction = "positive" if xinxing_match.group(1) == "+" else "negative"
        magnitude = xinxing_match.group(2)
        mag_entry = magnitude_map.get(("xinxing", direction))
        if mag_entry:
            value = mag_entry["small"] if magnitude == "小" else mag_entry["large"]
            # 心性存在 RoleState.attributes 中，target=player 走 _apply_world_state_patch.player 分支
            # 最终经 RoleState.set_value → set_xinxing 自动裁剪到 [-2, +2]。
            return {
                "target": "player",
                "op": "add",
                "key": "xinxing",
                "value": value,
            }

    # 能力效果：{属性名}{方向}{程度}
    # 方向词映射
    direction_map = {
        "积累": "accumulate",
        "受损": "damage",
    }
    for display_name, internal_key in attr_map.items():
        for cn_dir, en_dir in direction_map.items():
            for cn_mag, en_mag in [("小", "small"), ("大", "large")]:
                pattern = f"{display_name}{cn_dir}{cn_mag}"
                if expr == pattern:
                    dim = "ability"
                    mag_entry = magnitude_map.get((dim, en_dir))
                    if mag_entry:
                        value = mag_entry[en_mag]
                        # 能力属性写入 RoleState，target=player 对齐引擎玩家状态路径
                        return {
                            "target": "player",
                            "op": "add",
                            "key": internal_key,
                            "value": value,
                        }

    # 状态效果：精力/心气 消耗/恢复 小/大
    resource_map = {
        "精力消耗": ("energy", "consume"),
        "精力恢复": ("energy", "recover"),
        "心气消耗": ("spirit", "consume"),
        "心气恢复": ("spirit", "recover"),
    }
    for cn_prefix, (dim, direction) in resource_map.items():
        for cn_mag, en_mag in [("小", "small"), ("大", "large")]:
            if expr == f"{cn_prefix}{cn_mag}":
                mag_entry = magnitude_map.get((dim, direction))
                if mag_entry:
                    value = mag_entry[en_mag]
                    # 资源（energy/spirit）也挂在 RoleState.resources，走 target=player
                    return {
                        "target": "player",
                        "op": "add",
                        "key": dim,
                        "value": value,
                    }

    # 未识别的表达式
    print(f"  [WARNING] 未识别的效果表达式: '{expr}'", file=sys.stderr)
    return None


# ============================================================
# 效果行分类（default / success / fail 分支）
# ============================================================

def classify_effects(
    effect_lines: list[str],
    has_check: bool,
    attr_map: dict[str, str],
    magnitude_map: dict[str, dict[str, Any]],
    npc_display_to_id: dict[str, str],
) -> list[dict[str, Any]]:
    """
    将后果方向行分类为带 branch 标签的效果列表。
    返回 [{target, op, key, value, branch}, ...]

    分支规则：
    - "检定成功：xxx" → default 分支
    - "检定失败：xxx" → fail 分支
    - "状态/关系/心性/能力：xxx"（非检定前缀的通用标签行）：
      - 无检定时 → default 分支
      - 有检定时 → 同时写入 default 和 fail 两个分支（共有效果）
    """
    results: list[dict[str, Any]] = []
    current_branch = "default"
    # 标记当前行是否为通用标签行（有检定时需双写）
    is_common_effect = False

    for line in effect_lines:
        line = line.strip()
        if not line:
            continue

        is_common_effect = False

        # 检测分支标记
        if line.startswith("检定成功：") or line.startswith("检定成功:"):
            current_branch = "default"  # 成功 = default
            effect_text = line.split("：", 1)[-1].split(":", 1)[-1].strip()
        elif line.startswith("检定失败：") or line.startswith("检定失败:"):
            current_branch = "fail"
            effect_text = line.split("：", 1)[-1].split(":", 1)[-1].strip()
        else:
            # 带标签前缀的行（如 "能力：xxx"、"状态：xxx"、"关系：xxx"、"心性：xxx"）
            if "：" in line:
                label, effect_text = line.split("：", 1)
                label = label.strip()
                effect_text = effect_text.strip()
                if label in ("能力", "状态", "关系", "心性"):
                    if not has_check:
                        current_branch = "default"
                    else:
                        # 有检定时，通用标签行同时归属两个分支
                        is_common_effect = True
            elif ":" in line:
                label, effect_text = line.split(":", 1)
                label = label.strip()
                effect_text = effect_text.strip()
                if label in ("能力", "状态", "关系", "心性"):
                    if not has_check:
                        current_branch = "default"
                    else:
                        is_common_effect = True
            else:
                effect_text = line

        # 解析效果表达式（可能有 + 分隔的多个效果）
        for sub_expr in re.split(r"\s*[+＋]\s*", effect_text):
            sub_expr = sub_expr.strip()
            parsed = parse_effect_expression(
                sub_expr, attr_map, magnitude_map, npc_display_to_id
            )
            if parsed:
                if is_common_effect:
                    # 通用效果行：同时写入 default 和 fail 分支
                    for branch in ("default", "fail"):
                        entry = dict(parsed)
                        entry["branch"] = branch
                        results.append(entry)
                else:
                    parsed["branch"] = current_branch
                    results.append(parsed)

    return results


# ============================================================
# CSV 生成
# ============================================================

def generate_events_csv(cards: list[dict[str, Any]]) -> list[dict[str, str]]:
    """生成 events.csv 行。"""
    rows: list[dict[str, str]] = []
    for card in cards:
        meta = card["meta"]
        event_id = card["event_id"]
        event_type = meta.get("type", "filler")
        stage = meta.get("stage", 2)
        archetype = meta.get("archetype", "")

        # 构建 tags
        tags_parts: list[str] = []
        tags_parts.append("skeleton" if event_type == "skeleton" else "filler")
        tags_parts.append(f"stage_{stage}")
        if archetype:
            # 原型缩写映射
            archetype_abbr = {
                "日常劳作": "daily", "休息恢复": "rest", "见闻消息": "news",
                "身体压力": "strain", "人际往来": "social", "闲暇时光": "free",
            }
            abbr = archetype_abbr.get(archetype, archetype)
            tags_parts.append(abbr)

        has_options = len(card["options"]) > 0
        choice_point_id = f"cp_{event_id}" if has_options else ""

        row = {
            "event_id": event_id,
            "title": card["title"],
            "background_art": "",
            "base_weight": str(meta.get("base_weight", 10)),
            "continuation_policy": "ReturnToScheduler",
            "choice_point_id": choice_point_id,
            "tags": ";".join(tags_parts),
            "task_links": meta.get("task_links", ""),
            "is_ending_event": "FALSE",
            "type": "",
        }
        rows.append(row)
    return rows


def generate_event_conditions_csv(cards: list[dict[str, Any]]) -> list[dict[str, str]]:
    """生成 event_conditions.csv 行。"""
    rows: list[dict[str, str]] = []
    for card in cards:
        event_id = card["event_id"]
        meta = card["meta"]

        # required_flags（仅骨架）
        required_flags = meta.get("required_flags", [])
        if isinstance(required_flags, str):
            required_flags = [required_flags] if required_flags else []
        for flag_expr in required_flags:
            parsed = parse_condition_expr(flag_expr)
            if parsed:
                rows.append({
                    "event_id": event_id,
                    "condition_type": "required_flag",
                    "left": parsed["left"],
                    "op": parsed["op"],
                    "right": parsed["right"],
                    "delta": "",
                })

        # weight_rules
        weight_rules = meta.get("weight_rules", [])
        if isinstance(weight_rules, str):
            weight_rules = [weight_rules] if weight_rules else []
        for rule_expr in weight_rules:
            # 格式："params.energy <= 2 → +5" 或 "flags.met_cheng == true → +10"
            arrow_match = re.match(r"(.+?)\s*[→->]+\s*([+\-]?\d+)$", rule_expr)
            if arrow_match:
                condition_part = arrow_match.group(1).strip()
                delta = arrow_match.group(2).strip()
                parsed = parse_condition_expr(condition_part)
                if parsed:
                    rows.append({
                        "event_id": event_id,
                        "condition_type": "weight_rule",
                        "left": parsed["left"],
                        "op": parsed["op"],
                        "right": parsed["right"],
                        "delta": delta,
                    })

    return rows


def parse_condition_expr(expr: str) -> dict[str, str] | None:
    """解析条件表达式 "left op right" 格式。"""
    operators = [">=", "<=", "==", "!=", ">", "<"]
    for op in operators:
        token = f" {op} "
        if token in expr:
            parts = expr.split(token, 1)
            if len(parts) == 2:
                return {
                    "left": parts[0].strip(),
                    "op": op,
                    "right": parts[1].strip(),
                }
    return None


def generate_event_presentations_csv(cards: list[dict[str, Any]]) -> list[dict[str, str]]:
    """生成 event_presentations.csv 行。

    presents 字段默认填 "text"（纯叙事）；非默认值（如 location_select）需在拆解稿
    手动指定，由翻译者按 presents_values 契约白名单填写，不在脚本自动生成范围。

    condition 字段（需求 2 新增）：脚本产出的行统一留空（空 = 通用 fallback 行，
    无差分过滤）。condition 差分行仅 sys_reflection 等特殊自省事件使用，需人工在
    CSV 中手动填写；普通事件卡不使用 condition，留空即可兼容引擎过滤逻辑。

    换行表达：脚本当前用空格 join 同 `>` 段落内多行，不产出真换行也不产出字面 \\n。
    若未来设计稿需要单屏内显式换行，应当产出字面 \\n 两字符（引擎装配层 unescape）；
    禁止产出真换行（触发 quoted multi-line cell，编辑器/diff 显示伪行）。详见
    CLAUDE.md §CSV 配置静态检查规范·叙事换行用字面 \\n。
    """
    rows: list[dict[str, str]] = []
    for card in cards:
        event_id = card["event_id"]
        for idx, para in enumerate(card["presentations"], start=1):
            rows.append({
                "event_id": event_id,
                "presentation_id": f"{event_id}_p{idx}",
                "display_order": str(idx),
                "item_type": "text",
                "speaker": "旁白",
                "text": para,
                "presents": "text",
                "condition": "",  # 脚本产出行 condition 统一留空（无差分过滤）
            })
    return rows


def generate_options_csv(cards: list[dict[str, Any]]) -> list[dict[str, str]]:
    """生成 options.csv 行。"""
    rows: list[dict[str, str]] = []
    for card in cards:
        event_id = card["event_id"]
        for idx, opt in enumerate(card["options"], start=1):
            rows.append({
                "option_id": f"{event_id}_opt_{idx}",
                "choice_point_id": f"cp_{event_id}",
                "text": opt["text"],
                "display_order": str(idx),
            })
    return rows


def generate_option_rules_csv(
    cards: list[dict[str, Any]],
    attr_map: dict[str, str],
    magnitude_map: dict[str, dict[str, Any]],
    npc_display_to_id: dict[str, str],
) -> list[dict[str, str]]:
    """生成 option_rules.csv 行。"""
    rows: list[dict[str, str]] = []

    for card in cards:
        event_id = card["event_id"]
        for idx, opt in enumerate(card["options"], start=1):
            option_id = f"{event_id}_opt_{idx}"

            # cost 行
            cost_effects = parse_cost_expression(opt.get("cost", ""), magnitude_map)
            for ce in cost_effects:
                rows.append({
                    "option_id": option_id,
                    "rule_type": "cost",
                    "branch": "",
                    "left": "",
                    "op": "",
                    "right": "",
                    "target": "",
                    "key": ce["key"],
                    "value": str(abs(ce["value"])),
                })

            # check 行
            check_text = opt.get("check", "").strip()
            if check_text and check_text != "无":
                check_rows = parse_check_expression(check_text)
                for cr in check_rows:
                    rows.append({
                        "option_id": option_id,
                        "rule_type": "check",
                        "branch": "",
                        "left": "",
                        "op": "",
                        "right": "",
                        "target": "check",
                        "key": cr["key"],
                        "value": cr["value"],
                    })

            # resolution 行
            has_check = check_text and check_text != "无"
            effects = classify_effects(
                opt.get("effects", []),
                has_check,
                attr_map,
                magnitude_map,
                npc_display_to_id,
            )
            # 合并同一 branch 下的多条 affinityDeltas：引擎装配器对 key=affinityDeltas 是覆盖写入，
            # 多行 target=affinity 会互相覆盖，必须合并为单行 ";" 分隔的 value。
            # 见 scripts/systems/world_event_config_assembler.gd:_apply_effect_or_resolution_action
            affinity_segments: dict[str, list[str]] = {}
            for eff in effects:
                if eff.get("target") == "affinity" and eff.get("key") == "affinityDeltas":
                    affinity_segments.setdefault(eff["branch"], []).append(str(eff["value"]))
                    continue
                rows.append({
                    "option_id": option_id,
                    "rule_type": "resolution",
                    "branch": eff["branch"],
                    "left": "",
                    "op": eff["op"],
                    "right": "",
                    "target": eff["target"],
                    "key": eff["key"],
                    "value": str(eff["value"]),
                })
            for branch, segments in affinity_segments.items():
                rows.append({
                    "option_id": option_id,
                    "rule_type": "resolution",
                    "branch": branch,
                    "left": "",
                    "op": "",
                    "right": "",
                    "target": "affinity",
                    "key": "affinityDeltas",
                    "value": ";".join(segments),
                })

    return rows


def parse_cost_expression(
    cost_text: str,
    magnitude_map: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    """解析代价表达式。如 "精力消耗小" → [{key: "energy", value: 1}]"""
    if not cost_text or cost_text == "无":
        return []

    results: list[dict[str, Any]] = []
    resource_cost_map = {
        "精力消耗": ("energy", "consume"),
        "心气消耗": ("spirit", "consume"),
    }

    for sub in re.split(r"\s*[+＋]\s*", cost_text):
        sub = sub.strip()
        for cn_prefix, (dim, direction) in resource_cost_map.items():
            for cn_mag, en_mag in [("小", "small"), ("大", "large")]:
                if sub == f"{cn_prefix}{cn_mag}":
                    mag_entry = magnitude_map.get((dim, direction))
                    if mag_entry:
                        results.append({
                            "key": dim,
                            "value": abs(mag_entry[en_mag]),
                        })
    return results


def parse_check_expression(check_text: str) -> list[dict[str, str]]:
    """
    解析检定行。
    新格式："craft，低难度" 或 "physique，低难度"
    旧格式（兼容）："百艺鉴定，低难度"
    """
    check_text = check_text.strip()
    if not check_text or check_text == "无":
        return []

    # 拆分能力和难度
    parts = re.split(r"[，,]", check_text)
    ability_part = parts[0].strip() if parts else ""
    difficulty_part = parts[1].strip() if len(parts) > 1 else "低难度"

    # 能力 key：新格式直接是代码侧 key，旧格式需要映射
    ability_key = ability_part
    # 旧格式兼容：去掉"鉴定"后缀，映射显示名
    old_format_map = {
        "百艺鉴定": "craft",
        "武学鉴定": "physique",
        "学识鉴定": "insight",
        "百艺": "craft",
        "武学": "physique",
        "学识": "insight",
    }
    if ability_part in old_format_map:
        ability_key = old_format_map[ability_part]

    # 难度参数
    difficulty_params = {
        "低难度": {"hitThreshold": "6", "requiredHits": "1"},
    }
    params = difficulty_params.get(difficulty_part, difficulty_params["低难度"])

    return [
        {"key": "type", "value": "assessment"},
        {"key": "items", "value": f"{ability_key}:positive"},
        {"key": "hitThreshold", "value": params["hitThreshold"]},
        {"key": "requiredHits", "value": params["requiredHits"]},
    ]


# ============================================================
# CSV 写入
# ============================================================

CSV_HEADERS = {
    "events.csv": [
        "event_id", "title", "background_art", "base_weight",
        "continuation_policy", "choice_point_id", "tags", "task_links",
        "is_ending_event", "type",
    ],
    "event_conditions.csv": [
        "event_id", "condition_type", "left", "op", "right", "delta",
    ],
    "event_presentations.csv": [
        "event_id", "presentation_id", "display_order", "item_type",
        "speaker", "text", "presents",
        # 需求 2 新增：presentation condition 差分字段（空 = 通用 fallback 行；
        # 非空 = 按 world_state 过滤，见 Design/配置翻译指南.md 锚点 presentation_condition）。
        # 脚本自动产出的 event_presentations 行 condition 字段统一留空
        # （条件差分行由 LLM/人工在 CSV 中手动填写；前提：通常只有 sys_reflection 等特殊自省
        # 事件才使用 condition 差分，普通事件卡不指定 condition）。
        "condition",
    ],
    "options.csv": [
        "option_id", "choice_point_id", "text", "display_order",
    ],
    "option_rules.csv": [
        "option_id", "rule_type", "branch", "left", "op", "right",
        "target", "key", "value",
    ],
}


def write_csv(filepath: str, headers: list[str], rows: list[dict[str, str]]) -> None:
    """写入 CSV 文件。"""
    with open(filepath, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


# ============================================================
# 主流程
# ============================================================

def find_event_cards(cards_dir: str) -> list[str]:
    """查找目录下所有事件卡文件（排除索引文件和非 .md 文件）。"""
    result: list[str] = []
    for entry in sorted(os.listdir(cards_dir)):
        if entry.startswith("_"):
            continue
        if not entry.endswith(".md"):
            continue
        result.append(os.path.join(cards_dir, entry))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="事件卡 → CSV 机械翻译")
    parser.add_argument(
        "--cards", required=True,
        help="事件卡目录路径（如 Design/events/stage_2）",
    )
    parser.add_argument(
        "--out", required=True,
        help="CSV 输出目录（如 scripts/config/world_event_mvp）",
    )
    parser.add_argument(
        "--config-root", default="scripts/config",
        help="查表文件根目录（默认 scripts/config）",
    )
    parser.add_argument(
        "--preserve-existing", action="store_true",
        help="保留输出目录中已存在的非脚本产出 CSV（如 event_outcomes.csv）",
    )
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cards_dir = os.path.join(project_root, args.cards)
    out_dir = os.path.join(project_root, args.out)
    config_root = os.path.join(project_root, args.config_root)

    # 加载查表文件
    print("[1/4] 加载查表文件...")
    attr_map = build_attribute_map(
        load_csv_as_dicts(os.path.join(config_root, "attribute_names.csv"))
    )
    magnitude_map = build_magnitude_map(
        load_csv_as_dicts(os.path.join(config_root, "effect_magnitude.csv"))
    )
    npc_display_to_id = build_npc_display_to_id(
        load_csv_as_dicts(os.path.join(config_root, "roles.csv"))
    )
    affinity_set = build_affinity_set(
        load_csv_as_dicts(os.path.join(config_root, "affinity.csv"))
    )
    print(f"  属性映射: {len(attr_map)} 项")
    print(f"  NPC 映射: {len(npc_display_to_id)} 项")
    print(f"  关系注册: {len(affinity_set)} 对")

    # 扫描并解析事件卡
    print(f"\n[2/4] 扫描事件卡目录: {cards_dir}")
    card_files = find_event_cards(cards_dir)
    print(f"  找到 {len(card_files)} 个文件")

    cards: list[dict[str, Any]] = []
    skipped = 0
    for filepath in card_files:
        card = parse_event_card(filepath)
        if card:
            # 检查是否为新格式（有 base_weight 字段）
            if "base_weight" not in card["meta"]:
                print(f"  [SKIP] 旧格式（无 base_weight）: {os.path.basename(filepath)}")
                skipped += 1
                continue
            cards.append(card)
        else:
            print(f"  [SKIP] 无效事件卡: {os.path.basename(filepath)}")
            skipped += 1

    print(f"  有效事件卡: {len(cards)} 个，跳过: {skipped} 个")

    if not cards:
        print("\n没有找到有效的新格式事件卡，退出。")
        sys.exit(0)

    # 生成 CSV
    print(f"\n[3/4] 生成 CSV 文件...")
    os.makedirs(out_dir, exist_ok=True)

    csv_data = {
        "events.csv": generate_events_csv(cards),
        "event_conditions.csv": generate_event_conditions_csv(cards),
        "event_presentations.csv": generate_event_presentations_csv(cards),
        "options.csv": generate_options_csv(cards),
        "option_rules.csv": generate_option_rules_csv(
            cards, attr_map, magnitude_map, npc_display_to_id
        ),
    }

    for filename, rows in csv_data.items():
        filepath = os.path.join(out_dir, filename)
        headers = CSV_HEADERS[filename]
        write_csv(filepath, headers, rows)
        print(f"  {filename}: {len(rows)} 行")

    # 汇总
    print(f"\n[4/4] 完成。")
    print(f"  输出目录: {out_dir}")
    print(f"  脚本产出: {len(csv_data)} 个 CSV")
    print(f"  需人工补全: event_outcomes.csv, tasks.csv")


if __name__ == "__main__":
    main()

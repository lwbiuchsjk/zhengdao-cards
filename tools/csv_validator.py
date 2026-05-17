#!/usr/bin/env python3
"""
CSV 配置静态检查脚本

功能：对事件引擎 CSV 配置（常规阶段 6 表）进行自动化静态检查，报告结构性问题。

用法：
  python tools/csv_validator.py --dir scripts/config/world_event_mvp
  python tools/csv_validator.py --dir scripts/config/world_event_mvp --ref-dir scripts/config
"""

import argparse
import csv
import re
import sys
from pathlib import Path


# ============================================================
# 【CSV 契约边界】知识来源声明
# ============================================================
# 本脚本是 CSV 配置契约三件套之一（契约真源：Design/配置翻译指南.md）。
# 修改本脚本的校验规则、常量集合前，必须同步回看契约真源与引擎装配器；
# 反之，引擎或翻译指南变动时也需回看本脚本（见 CLAUDE.md "CSV 契约三件套" 规则）。
#
# 【运行时读取】（引擎侧改了 CSV，本脚本自动生效）
#   - {ref_dir}/attribute_names.csv — 合法属性 key 集合
#
# 【硬编码常量】（引擎侧改了代码，需人工同步本脚本）
#   - RESOURCE_KEYS
#     来源: scripts/systems/world_event_engine.gd（资源消耗/恢复的 key）
#   - KNOWN_RULE_TYPES
#     来源: scripts/systems/world_event_config_assembler.gd（option_rules 行类型）
#   - KNOWN_CONDITION_TYPES
#     来源: scripts/systems/world_event_config_assembler.gd（event_conditions 行类型）
#   - AFFINITY_KEY_PATTERN
#     来源: scripts/systems/rule_engine.gd（关系效果 key 格式）
#
# ------------------------------------------------------------
# 【CSV 契约摘要 — target 路由】（冗余备份，真源见翻译指南锚点 resolution_target_routing）
# ------------------------------------------------------------
# 若翻译指南丢失，按下表反推 resolution 的 target 路由：
#
#   target=player   → RoleState 属性/资源（attribute_names.csv 白名单 + RESOURCE_KEYS）
#                     举例：insight/craft/physique/aptitude/xinxing/energy/spirit
#   target=affinity → AffinityMap 关系变动，key 固定为 affinityDeltas，
#                     value 为 "from->to:±N" 多段（分号拼接）
#   target=params   → world_state.params（自由命名的世界计数器，非玩家属性）
#   target=flags    → world_state.flags（op=set）
#   target=world    → 世界动作（set_location / set_forced_next / end_chain / clear_forced_next）
#   target=chain_context → 链上下文补丁（op=patch）
#   target=focus    → 自省关注列表补丁
#   target=task     → 任务 accept/complete/fail 动作
#
# 常见错误（本脚本规则 7 会拒绝）：
#   - 把玩家属性/资源写成 target=params（应为 player）
#   - 把关系变化写成 target=params, key=affinity.xxx（应为 target=affinity, key=affinityDeltas）
# ============================================================

# 资源 key（引擎硬编码，不在 attribute_names.csv 中）
# 议题 A 收口（2026-05-10）：hp / energy 设计层移除，cost / resolution 不应再使用这两 key。
# 状态栏 5 印章 = 气(spirit) / 银(gold) / 武(physique) / 艺(craft) / 识(insight)；
#   spirit / gold 是 RESOURCE_KEYS 范围，physique/craft/insight 在 attribute_names 范围。
# 保留 gold 防御性（未来如有 cost gold 选项可自动通过校验）。
RESOURCE_KEYS = {"spirit", "gold"}

# cost 黑名单（议题 A 收口，2026-05-10）：检查 7 cost 分支补丁。
# attribute_names.csv 仍保留 hp/energy 行作为 schema reference（roles.csv 列对齐），
# 但 cost 行不应再使用——单独黑名单拦截。
# 修复 csv_validator 漏检 BUG：之前仅缩 RESOURCE_KEYS 不够，cost energy 仍通过 attribute_names 路径合法。
DISALLOWED_COST_KEYS = {"hp", "energy"}

# option_rules 的合法 rule_type
KNOWN_RULE_TYPES = {
    "visibility", "eligibility", "cost",
    "check", "resolution", "preemptive_bet",
}

# event_conditions 的合法 condition_type
KNOWN_CONDITION_TYPES = {
    "required_flag", "weight_rule",
    "required_npc", "required_location", "required_location_flag",
}

# event_presentations 的合法 presents 值（Step 2 新增）
# 来源：Design/配置翻译指南.md 锚点 presents_values
# demo 期引擎/UI 仅实现 text 与 location_select 两种渲染分支；
# adjust_relation / focus_select / focus_remove 配置层留口、运行时未实现，
# 出现即提示设计/配置错误（demo 期 reflection 事件不应配置这些值）。
KNOWN_PRESENTS_VALUES = {
    "text",
    "location_select",
    "adjust_relation",
    "focus_select",
    "focus_remove",
}
DEMO_UNSUPPORTED_PRESENTS = {
    "adjust_relation",
    "focus_select",
    "focus_remove",
}

# option_outcomes.csv 的合法 branch 值（事件叙事反馈 MVP A，2026-05-09 新增）
# 来源：Design/配置翻译指南.md 锚点 option_outcome_text
# 引擎 _resolve_outcome_branch_texts fallback 链：
#   critical_success → success → default
#   critical_fail    → fail    → default
#   success / fail   → default
KNOWN_OUTCOME_BRANCHES = {
    "default", "success", "fail", "critical_success", "critical_fail",
}

# event_presentations.condition 字段（需求 2 新增，2026-05-11）
# 来源：Design/配置翻译指南.md 锚点 presentation_condition
# 引擎消费侧：world_event_engine.gd::_get_event_presentation_filtered
# 格式：`<world_state_path> <op> <literal>`（空 = 通用 fallback 行）
# 合法 world_state 顶层 key 白名单（引擎侧硬编码可用的顶层字段）：
KNOWN_PRESENTATION_CONDITION_WORLD_STATE_KEYS = {
    "last_consumed_skeleton_event_id",
    "flags",
    "params",
    "currentLocationId",
    "finalEventPoolConsumed",
}

# 旧版关系 key 的正则（affinity.player_001->npc_xxx）——已废弃，仅用于识别误用
AFFINITY_KEY_RE = re.compile(r"^affinity\.\w+->\w+$")

# target=affinity 对应的合法 value 段格式：from->to:±N（允许空白与多段分号分隔）
AFFINITY_DELTA_SEGMENT_RE = re.compile(r"^\s*\w+->\w+\s*:\s*[+\-]?\d+\s*$")


# ============================================================
# 工具函数
# ============================================================

def load_csv(path: Path) -> list[dict[str, str]]:
    """读取 CSV 为字典列表。文件不存在时返回空列表并打印提示。"""
    if not path.exists():
        print(f"  [跳过] 文件不存在: {path.name}")
        return []
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def load_attribute_keys(ref_dir: Path) -> set[str]:
    """从 attribute_names.csv 读取合法属性 key。"""
    path = ref_dir / "attribute_names.csv"
    if not path.exists():
        return set()
    rows = load_csv(path)
    keys: set[str] = set()
    for row in rows:
        key = row.get("internal_key", "").strip()
        if key:
            keys.add(key)
    return keys


def is_player_attr_key(key: str, attribute_keys: set[str]) -> bool:
    """判定 key 是否为玩家属性/资源（应使用 target=player 路径）。"""
    return key in attribute_keys or key in RESOURCE_KEYS


# ============================================================
# 检查结果
# ============================================================

class ValidationResult:
    """收集检查结果并输出报告。"""

    def __init__(self) -> None:
        self.p1: list[str] = []
        self.p2: list[str] = []
        self.stats: dict[str, int] = {}

    def add_p1(self, msg: str) -> None:
        self.p1.append(msg)

    def add_p2(self, msg: str) -> None:
        self.p2.append(msg)

    def print_report(self) -> None:
        if self.p1:
            print("\n=== P1（必须修复） ===")
            for msg in self.p1:
                print(f"  {msg}")
        if self.p2:
            print("\n=== P2（建议检查） ===")
            for msg in self.p2:
                print(f"  {msg}")

        parts = [f"{len(self.p1)} P1", f"{len(self.p2)} P2"]
        stats_items = " / ".join(f"{k}: {v}" for k, v in sorted(self.stats.items()))
        status = "通过" if not self.p1 else "有问题"
        print(f"\n=== 检查完成: {', '.join(parts)} | {stats_items} | {status} ===")

    @property
    def ok(self) -> bool:
        return len(self.p1) == 0


# ============================================================
# 核心检查逻辑
# ============================================================

def validate(csv_dir: Path, ref_dir: Path) -> ValidationResult:
    """对指定目录执行全部静态检查。"""
    result = ValidationResult()

    # ── 加载配置表 ──
    events = load_csv(csv_dir / "events.csv")
    event_conditions = load_csv(csv_dir / "event_conditions.csv")
    event_outcomes = load_csv(csv_dir / "event_outcomes.csv")
    event_presentations = load_csv(csv_dir / "event_presentations.csv")
    options = load_csv(csv_dir / "options.csv")
    option_rules = load_csv(csv_dir / "option_rules.csv")
    # Step 2 新增：可选表（缺失时静默跳过对应校验）。
    transition_text_pool = load_csv(csv_dir / "transition_text_pool.csv")
    # location_graph.csv 优先在 csv_dir 找；找不到回 ref_dir 找（兼容嵌套结构：
    # 正式路径 scripts/config/world_event_mvp/ 不含 location_graph，它在 scripts/config/ 根目录）。
    location_graph_rows = load_csv(csv_dir / "location_graph.csv")
    if not location_graph_rows:
        location_graph_rows = load_csv(ref_dir / "location_graph.csv")
    # 事件叙事反馈 MVP A：option_outcomes.csv 可选表（缺失时静默跳过对应校验）。
    option_outcomes = load_csv(csv_dir / "option_outcomes.csv")
    # 任务评价系统：tasks.csv 与 task_eval_*.csv 的 FK 一致性（2026-05-09 新增；
    # Phase A 后期暴露的"task_eval 引用 tasks 已删 task_id"事故触发的硬化校验）。
    tasks_rows = load_csv(csv_dir / "tasks.csv")
    task_eval_grades = load_csv(csv_dir / "task_eval_grades.csv")
    task_eval_indicators = load_csv(csv_dir / "task_eval_indicators.csv")
    task_eval_grade_overrides = load_csv(csv_dir / "task_eval_grade_overrides.csv")
    task_eval_effects = load_csv(csv_dir / "task_eval_effects.csv")

    # ── 加载参考数据 ──
    attribute_keys = load_attribute_keys(ref_dir)
    if not attribute_keys:
        result.add_p2(f"未找到 {ref_dir / 'attribute_names.csv'}，跳过 key 合法性检查")

    # ── 构建索引 ──
    event_ids: set[str] = {
        r.get("event_id", "").strip() for r in events
        if r.get("event_id", "").strip()
    }
    event_cp_ids: set[str] = {
        r.get("choice_point_id", "").strip() for r in events
        if r.get("choice_point_id", "").strip()
    }
    option_ids: set[str] = {
        r.get("option_id", "").strip() for r in options
        if r.get("option_id", "").strip()
    }

    result.stats["事件"] = len(event_ids)
    result.stats["选项"] = len(option_ids)

    # ── 检查 1: FK — option_rules.option_id → options.option_id ──
    rule_option_ids: set[str] = {
        r.get("option_id", "").strip() for r in option_rules
        if r.get("option_id", "").strip()
    }
    for oid in sorted(rule_option_ids - option_ids):
        result.add_p1(f"option_rules: option_id '{oid}' 不存在于 options.csv")

    # ── 检查 2: FK — options.choice_point_id → events.choice_point_id ──
    for row in options:
        cp_id = row.get("choice_point_id", "").strip()
        if cp_id and cp_id not in event_cp_ids:
            oid = row.get("option_id", "")
            result.add_p1(f"options: '{oid}' 的 choice_point_id '{cp_id}' 不存在于 events.csv")

    # ── 检查 3: FK — 从表 event_id → events.event_id ──
    for table_name, rows in [
        ("event_conditions", event_conditions),
        ("event_presentations", event_presentations),
        ("event_outcomes", event_outcomes),
    ]:
        seen_eids: set[str] = {
            r.get("event_id", "").strip() for r in rows
            if r.get("event_id", "").strip()
        }
        for eid in sorted(seen_eids - event_ids):
            result.add_p1(f"{table_name}: event_id '{eid}' 不存在于 events.csv")

    # ── 检查 4: fail 分支缺失 ──
    options_with_check: set[str] = set()
    options_with_fail: set[str] = set()
    for row in option_rules:
        oid = row.get("option_id", "").strip()
        rule_type = row.get("rule_type", "").strip()
        branch = row.get("branch", "").strip()
        if rule_type == "check":
            options_with_check.add(oid)
        if rule_type == "resolution" and branch == "fail":
            options_with_fail.add(oid)

    for oid in sorted(options_with_check - options_with_fail):
        result.add_p1(
            f"option_rules: '{oid}' 有 check 但无 resolution,fail 行"
            "（引擎将 fallback 到 default，导致失败=成功）"
        )

    result.stats["鉴定选项"] = len(options_with_check)
    result.stats["有fail分支"] = len(options_with_check & options_with_fail)

    # ── 检查 5: rule_type 合法性 ──
    for row in option_rules:
        rt = row.get("rule_type", "").strip()
        if rt and rt not in KNOWN_RULE_TYPES:
            oid = row.get("option_id", "")
            result.add_p2(f"option_rules: '{oid}' 使用未知 rule_type '{rt}'")

    # ── 检查 6: condition_type 合法性 ──
    for row in event_conditions:
        ct = row.get("condition_type", "").strip()
        if ct and ct not in KNOWN_CONDITION_TYPES:
            eid = row.get("event_id", "")
            result.add_p2(f"event_conditions: '{eid}' 使用未知 condition_type '{ct}'")

    # ── 检查 6.1: required_location 缺失防御（2026-05-12 新增）──
    # 触发场景：Phase B 跑测发现 evt_s2_fl_zhou_* / evt_s2_fl_pharmacy_{4,5,6}
    # 漏配 required_location，导致跨地点抽到。调度器按 required_location 过滤事件池，
    # 缺失 = 任何地点都可命中。
    #
    # 豁免规则（不进调度器的事件不需要 required_location）：
    #   - type == "reflection"  → 系统自省事件，由阶段触发器 / forced_next 强制注入
    #   - tags 含 "chain"       → 链式事件，由 set_forced_next 或 final_event_pool_exhausted_forced_id
    #                             强制注入，调度器不抽
    events_with_required_location: set[str] = {
        r.get("event_id", "").strip() for r in event_conditions
        if r.get("condition_type", "").strip() == "required_location"
        and r.get("event_id", "").strip()
    }
    for row in events:
        eid = row.get("event_id", "").strip()
        if not eid:
            continue
        event_type = row.get("type", "").strip()
        tags_raw = row.get("tags", "").strip()
        tags_set = {t.strip() for t in tags_raw.split(";") if t.strip()}
        # 豁免：系统自省 + 链式事件
        if event_type == "reflection":
            continue
        if "chain" in tags_set:
            continue
        if eid not in events_with_required_location:
            result.add_p1(
                f"event_conditions: 事件 '{eid}' 缺 required_location 行"
                "（非 reflection / chain 事件需指定调度地点，否则任意地点都可命中）"
            )

    # ── 检查 6.5: event_presentations.presents 合法性（Step 2 新增）──
    # presents 字段空 → 引擎默认 text；非空必须在 KNOWN_PRESENTS_VALUES 白名单内。
    # demo 期不应出现 DEMO_UNSUPPORTED_PRESENTS 中的值（引擎/UI 渲染分支未实现）。
    for row in event_presentations:
        presents = row.get("presents", "").strip()
        if not presents:
            continue
        pid = row.get("presentation_id", "")
        if presents not in KNOWN_PRESENTS_VALUES:
            result.add_p1(
                f"event_presentations: '{pid}' 使用未知 presents '{presents}'"
            )
        elif presents in DEMO_UNSUPPORTED_PRESENTS:
            result.add_p2(
                f"event_presentations: '{pid}' 使用 demo 期未实现的 presents '{presents}' "
                "（引擎/UI 渲染分支待正式期补，demo 期 reflection 事件不应配置）"
            )
        # presents=location_select 行必须 text 非空（同屏渲染需要叙事文本作 caption）
        if presents == "location_select":
            text = row.get("text", "").strip()
            if not text:
                result.add_p1(
                    f"event_presentations: '{pid}' presents=location_select 但 text 为空"
                    "（同屏渲染需要末段叙事文本作 caption）"
                )

    # ── 检查 6.5b: event_presentations.condition 语法合法性（需求 2 新增）──
    # 【CSV 契约边界】来源：Design/配置翻译指南.md 锚点 presentation_condition。
    # 合法 condition 语法：`<world_state_key_path> <op> <literal>`，其中：
    #   - key_path 为点分路径（如 last_consumed_skeleton_event_id 或 flags.met_he）
    #   - op 为 == / != / > / >= / < /<=
    #   - literal 为双引号字符串、数字、true/false
    # 合法 world_state 顶层 key 白名单：KNOWN_PRESENTATION_CONDITION_WORLD_STATE_KEYS（头部常量）
    _CONDITION_OPS = {"==", "!=", ">", ">=", "<", "<="}

    def _parse_presentation_condition(cond: str) -> str | None:
        """返回 None 表示合法，返回错误描述表示不合法。"""
        cond = cond.strip()
        if not cond:
            return None  # 空 condition 合法（fallback 行）
        for op in sorted(_CONDITION_OPS, key=len, reverse=True):  # 长 op 优先
            token = f" {op} "
            if token in cond:
                parts = cond.split(token, 1)
                if len(parts) != 2:
                    return f"条件表达式格式错误（无法按 '{op}' 分割）: {cond!r}"
                left = parts[0].strip()
                right = parts[1].strip()
                # 检查 left 路径首段是否在已知 world_state key 白名单中
                root_key = left.split(".")[0]
                if root_key not in KNOWN_PRESENTATION_CONDITION_WORLD_STATE_KEYS:
                    return (
                        f"条件左值 '{root_key}' 不在已知 world_state 字段集"
                        f"（当前白名单: {sorted(KNOWN_PRESENTATION_CONDITION_WORLD_STATE_KEYS)}）"
                    )
                # 检查 right 是否为合法 literal（双引号字符串 / 数字 / true / false）
                if right in ("true", "false"):
                    return None
                if right.lstrip("-").isdigit():
                    return None
                if right.startswith('"') and right.endswith('"') and len(right) >= 2:
                    return None
                return f"条件右值 '{right}' 不是合法 literal（需为双引号字符串、整数或 true/false）"
        return f"条件表达式缺少合法操作符（期望 {sorted(_CONDITION_OPS)}）: {cond!r}"

    for row in event_presentations:
        cond = row.get("condition", "").strip()
        if not cond:
            continue
        pid = row.get("presentation_id", "")
        err = _parse_presentation_condition(cond)
        if err:
            result.add_p1(f"event_presentations: '{pid}' condition 语法错误 — {err}")

    # ── 检查 6.6: transition_text_pool.csv 结构 + location_id 一致性（Step 2 新增）──
    # 文件可选（demo 期可能尚未创建）；存在时校验：
    #   - pool_id / location_id / text 非空，seq 为正整数
    #   - location_id 必须存在于 location_graph.csv（防止配置漂移）
    if transition_text_pool:
        # 构建 location_graph location_id 集合（也校验 location_graph.csv 自身存在性）。
        location_ids: set[str] = set()
        if location_graph_rows:
            location_ids = {
                r.get("location_id", "").strip() for r in location_graph_rows
                if r.get("location_id", "").strip()
            }
        else:
            result.add_p2(
                "transition_text_pool.csv 存在但 location_graph.csv 为空/缺失，"
                "无法做 location_id 一致性校验"
            )

        for idx, row in enumerate(transition_text_pool, start=1):
            pool_id = row.get("pool_id", "").strip()
            location_id = row.get("location_id", "").strip()
            seq_raw = row.get("seq", "").strip()
            text = row.get("text", "")
            row_label = f"transition_text_pool 第 {idx} 行"
            if not pool_id:
                result.add_p1(f"{row_label}: pool_id 为空")
            if not location_id:
                result.add_p1(f"{row_label}: location_id 为空")
            if not text.strip():
                result.add_p1(f"{row_label}: text 为空（或仅空白字符）")
            if not seq_raw or not seq_raw.lstrip("-").isdigit() or int(seq_raw) <= 0:
                result.add_p1(f"{row_label}: seq 必须为正整数（当前 '{seq_raw}'）")
            if location_id and location_ids and location_id not in location_ids:
                result.add_p1(
                    f"{row_label}: location_id '{location_id}' 不存在于 location_graph.csv"
                )
        result.stats["过渡叙事行"] = len(transition_text_pool)

    # ── 检查 6.7: option_outcomes.csv（事件叙事反馈 MVP A）──
    # 文件可选；存在时校验：
    #   - option_id 在 options.csv 存在（FK）
    #   - branch 值在白名单内（KNOWN_OUTCOME_BRANCHES）
    #   - seq 为正整数
    #   - text 非空（含 strip）
    #   - 同 (option_id, branch) 下 seq 连续无跳号（从 1 起递增）
    if option_outcomes:
        # 按 (option_id, branch) 收集 seq，最后做连续性校验。
        seq_groups: dict[tuple[str, str], list[int]] = {}
        for idx, row in enumerate(option_outcomes, start=1):
            row_label = f"option_outcomes 第 {idx} 行"
            option_id = row.get("option_id", "").strip()
            branch = row.get("branch", "").strip()
            seq_raw = row.get("seq", "").strip()
            text = row.get("text", "")

            if not option_id:
                result.add_p1(f"{row_label}: option_id 为空")
                continue
            if option_id not in option_ids:
                result.add_p1(
                    f"{row_label}: option_id '{option_id}' 不存在于 options.csv"
                )
                continue
            if not branch:
                result.add_p1(f"{row_label}: branch 为空")
                continue
            if branch not in KNOWN_OUTCOME_BRANCHES:
                result.add_p1(
                    f"{row_label}: branch '{branch}' 非法"
                    f"（合法值：{sorted(KNOWN_OUTCOME_BRANCHES)}）"
                )
                continue
            if not text.strip():
                result.add_p1(f"{row_label}: text 为空（或仅空白字符）")
            if not seq_raw or not seq_raw.lstrip("-").isdigit() or int(seq_raw) <= 0:
                result.add_p1(
                    f"{row_label}: seq 必须为正整数（当前 '{seq_raw}'）"
                )
                continue

            key = (option_id, branch)
            seq_groups.setdefault(key, []).append(int(seq_raw))

        # 同 (option_id, branch) 下 seq 必须从 1 起连续（1, 2, 3, ...），无跳号无重复。
        for (option_id, branch), seqs in seq_groups.items():
            seqs_sorted = sorted(seqs)
            expected = list(range(1, len(seqs_sorted) + 1))
            if seqs_sorted != expected:
                result.add_p1(
                    f"option_outcomes: ({option_id}, {branch}) 的 seq 序列 {seqs_sorted} "
                    f"非从 1 起连续（期望 {expected}）"
                )

        result.stats["outcome 行"] = len(option_outcomes)

    # ── 检查 6.8: task_eval_*.csv 与 tasks.csv 的 FK 一致性 ──
    # 文件可选；存在时校验 task_eval_grades / task_eval_indicators /
    #   task_eval_grade_overrides / task_eval_effects 中的 task_id 必须在 tasks.csv 内。
    # 历史教训（2026-05-09）：Phase A 落地时 tasks.csv 改为 4 个新 task，但 task_eval_*.csv
    #   仍引用早期 milestone 1 的 task_exam，dataset_dir 设空后两表同源导致 assembler
    #   FK 校验失败、main_game 提前 return 出现 UI 空白。csv_validator 当时未覆盖此层。
    task_id_set: set[str] = {
        r.get("task_id", "").strip() for r in tasks_rows
        if r.get("task_id", "").strip()
    }

    def _check_task_eval_fk(rows: list[dict[str, str]], file_label: str) -> None:
        """通用 task_id FK 校验：每行 task_id 必须在 tasks.csv 中。"""
        for idx, row in enumerate(rows, start=1):
            task_id = row.get("task_id", "").strip()
            if not task_id:
                continue  # 空 task_id 由各表自身的更严格校验处理
            if task_id not in task_id_set:
                result.add_p1(
                    f"{file_label} 第 {idx} 行: task_id '{task_id}' 不存在于 tasks.csv"
                )

    if tasks_rows:
        _check_task_eval_fk(task_eval_grades, "task_eval_grades")
        _check_task_eval_fk(task_eval_indicators, "task_eval_indicators")
        _check_task_eval_fk(task_eval_grade_overrides, "task_eval_grade_overrides")
        _check_task_eval_fk(task_eval_effects, "task_eval_effects")
        result.stats["task 数"] = len(task_id_set)
    else:
        # tasks.csv 缺失时仅警告（兼容历史 / 测试数据集）。
        if any([task_eval_grades, task_eval_indicators, task_eval_grade_overrides, task_eval_effects]):
            result.add_p2("task_eval_*.csv 存在数据但 tasks.csv 缺失，跳过 FK 校验")

    # ── 检查 7: cost / resolution key 合法性 ──
    # 语义分工（与 world_event_config_assembler._apply_effect_or_resolution_action 对齐）：
    #   target=player   → 玩家属性/资源（attribute_names.csv + RESOURCE_KEYS）
    #   target=affinity → 关系变动，key 固定 affinityDeltas，value 段为 from->to:±N
    #   target=params   → 世界参数（prosperity/morale/danger 等自由命名），不应写属性/关系
    if attribute_keys:
        for row in option_rules:
            rt = row.get("rule_type", "").strip()
            key = row.get("key", "").strip()
            oid = row.get("option_id", "")
            target = row.get("target", "").strip()
            value = row.get("value", "").strip()
            if not key and rt != "resolution":
                continue

            if rt == "cost":
                # 黑名单优先：议题 A 收口后 hp/energy 作 cost 不合法（即便 attribute_names 仍含这两行）
                if key in DISALLOWED_COST_KEYS:
                    result.add_p1(
                        f"option_rules: '{oid}' cost key '{key}' 已被议题 A 决议移除，"
                        f"请改为 cost spirit 或删除 cost 行（[[UI风格快速翻调_demo期进度]] §议题 A）"
                    )
                elif not is_player_attr_key(key, attribute_keys):
                    result.add_p1(
                        f"option_rules: '{oid}' cost key '{key}' 不是玩家属性/资源"
                    )
                continue

            if rt != "resolution":
                continue

            # target=params 不应承载玩家属性 / 资源 / 关系（早期格式错误的主来源）。
            if target == "params":
                if is_player_attr_key(key, attribute_keys):
                    result.add_p1(
                        f"option_rules: '{oid}' resolution 写错位置: "
                        f"target=params,key='{key}' 属于玩家状态，应改为 target=player"
                    )
                elif AFFINITY_KEY_RE.match(key):
                    result.add_p1(
                        f"option_rules: '{oid}' resolution 写错位置: "
                        f"target=params,key='{key}' 属于关系变动，应改为 "
                        f"target=affinity,key=affinityDeltas,value='{key[len('affinity.'):]}:±N'"
                    )
            elif target == "player":
                if key and not is_player_attr_key(key, attribute_keys):
                    result.add_p1(
                        f"option_rules: '{oid}' target=player 的 key '{key}' 不是玩家属性/资源"
                    )
            elif target == "affinity":
                if key != "affinityDeltas":
                    result.add_p1(
                        f"option_rules: '{oid}' target=affinity 的 key 必须为 affinityDeltas，当前='{key}'"
                    )
                # value 段格式校验：分号分段，每段 from->to:±N
                if value:
                    for segment in value.split(";"):
                        seg = segment.strip()
                        if not seg:
                            continue
                        if not AFFINITY_DELTA_SEGMENT_RE.match(seg):
                            result.add_p1(
                                f"option_rules: '{oid}' target=affinity value 段格式非法: '{seg}'"
                            )

    # ── 检查 8: cost value 应为正数 ──
    for row in option_rules:
        rt = row.get("rule_type", "").strip()
        if rt != "cost":
            continue
        val_str = row.get("value", "").strip()
        oid = row.get("option_id", "")
        if val_str:
            try:
                val = float(val_str)
                if val < 0:
                    result.add_p2(
                        f"option_rules: '{oid}' cost value={val_str} 为负数"
                        "（cost 应为正数，引擎自动扣除）"
                    )
            except ValueError:
                result.add_p1(f"option_rules: '{oid}' cost value '{val_str}' 不是有效数字")

    # ── 检查 9: 叙事文本字段中的 ASCII 半角双引号（2026-05-12 新增）──
    # 背景：Godot file_access::get_csv_line 严格按 CSV 标准；叙事文本中混入 ASCII 半角 "..."
    # 包裹的台词可能触发"end of file before closing"运行时报错（事故记录见 memory
    # feedback_csv_agent_delegation_safety）。统一为中文全角 "..." 避开 CSV 字段包裹机制。
    # 检测策略：Python csv 库标准解析后，字段值中残留的 ASCII 半角 " 必然是叙事台词引号
    # （CSV 字段包裹符已被解析层剥离）。condition / cost value 等工程字段不在此检查范围。
    narrative_text_specs = [
        ("event_presentations.csv", event_presentations, "text", "presentation_id"),
        ("option_outcomes.csv", option_outcomes, "text", "option_id"),
        ("transition_text_pool.csv", transition_text_pool, "text", "location_id"),
    ]
    for csv_name, rows, text_field, id_field in narrative_text_specs:
        for row in rows:
            text = row.get(text_field, "")
            if '"' in text:
                id_value = row.get(id_field, "?")
                result.add_p2(
                    f"{csv_name}: '{id_value}' {text_field} 含 ASCII 半角双引号 "
                    "（叙事台词应改为中文全角 “ ”；ASCII 半角可能触发 "
                    "Godot file_access::get_csv_line 报 'end of file before closing'）"
                )

    # ── 检查 10: 叙事文本字段中的真换行（2026-05-12 新增）──
    # 背景：叙事 text 字段统一用字面 \n（两字符）表达换行；引擎装配层会做
    # text.replace("\\n", "\n") 转义。CSV 字段内含真换行（\n / \r / \r\n）会触发
    # quoted multi-line cell，在编辑器/diff/grep 中显示为"伪行"且跨工具兼容差。
    # 详见 CLAUDE.md §CSV 配置静态检查规范·叙事换行用字面 \n。
    # 复用 narrative_text_specs（与 ASCII 双引号检查同位）。
    for csv_name, rows, text_field, id_field in narrative_text_specs:
        for row in rows:
            text = row.get(text_field, "")
            if "\n" in text or "\r" in text:
                id_value = row.get(id_field, "?")
                result.add_p1(
                    f"{csv_name}: '{id_value}' {text_field} 含真换行符 "
                    "（应改为字面 \\n 两字符；CSV 真换行触发 quoted multi-line cell，"
                    "编辑器/diff 工具显示为伪行，跨工具兼容差。"
                    "迁移工具：tools/migrate_narrative_newlines.py）"
                )

    return result


# ============================================================
# 入口
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="CSV 配置静态检查（常规阶段事件引擎 6 表）"
    )
    parser.add_argument("--dir", required=True, help="待检查的 CSV 配置目录")
    parser.add_argument(
        "--ref-dir", default="scripts/config",
        help="参考 CSV 目录，含 attribute_names.csv 等（默认 scripts/config）",
    )
    args = parser.parse_args()

    csv_dir = Path(args.dir)
    ref_dir = Path(args.ref_dir)

    if not csv_dir.exists():
        print(f"错误：目录不存在 {csv_dir}")
        sys.exit(1)

    print(f"检查目录: {csv_dir}")
    print(f"参考目录: {ref_dir}")

    result = validate(csv_dir, ref_dir)
    result.print_report()

    sys.exit(0 if result.ok else 1)


if __name__ == "__main__":
    main()

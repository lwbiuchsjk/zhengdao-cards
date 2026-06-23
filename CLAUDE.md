# 项目说明

## 项目概述

- **zhengdao-cards** 是 **vibe-test 的卡牌交互版续作**——只动前端表现交互层(改为卡牌),引擎层(事件调度 / 事件包 / 能力 / 鉴定 / 心性 / 自省 / 任务)整体保留并新增选项层调度。
- 修真问道题材,涌现式叙事(用系统创造剧情),与 vibe-test **同一世界观和叙事内核**。
- 当前阶段: **MVP 工程骨架就绪 → C 阶段 ✅ 完成 + Godot 4.6.2 升级 → D 阶段(MVP 1 期前置)三议题全部收口: §7.2 资源种类集合 ✅ + §7.3 普通事件回馈原则 ✅ + §7.1 普通事件撰写规格 ✅(A 模板层 + B/C/D 原则层, 2026-05-21) → MVP 1 期实施**。
- 完整方案见 [前端表现卡牌化_MVP草案](Design/zhengdao-cards/进度/前端表现卡牌化_MVP草案.md)(详见 §7.8 工程启动 checklist)。

## 技术栈

Godot 4.6.2,GDScript,Git submodule(共用 Design 与 vibe-test 同源)。

## 项目结构

- `scripts/`     脚本文件(已从 vibe-test 整体复制核心引擎 + 状态机;systems/models/config 三分 + main_game.gd 启动器)
- `assets/`     资源文件(图片、音效等;卡牌方案新生产,不直接复用 vibe-test mosaic)
- `test/`       测试文件
- `Design/`     设计文档目录(Git submodule → 私有仓库 `vibe-test-design`,**与 vibe-test 共用同一份**)
- `tools/`      工程工具脚本(配置流水线工具共享 vibe-test 同源)

## 路径指定

- 项目环境配置: `tools/local_env.json`(模板见 `tools/local_env.example.json`,git ignored)
- 共享 CLAUDE.md(`E:/Godot/project/CLAUDE.md`)中"设计文档目录"对应本项目 `design_dir` 字段
- **新增文档默认放** `Design/zhengdao-cards/<对应子目录>/`,frontmatter `tags` 必含 `项目/zhengdao-cards`

## Obsidian CLI

- 路径和 vault 名称配置在 `tools/local_env.json`(**与 vibe-test 共用同一 vault `Design`**)。
- 使用规范同 vibe-test CLAUDE.md `Obsidian CLI` 段(优先用 backlinks / links / outline / tags / properties)。

## Design 操作规范(三档分区下的项目纪律)

Design submodule 已按三档分区组织(2026-05-15 落地):

- `Design/共享/` — 跨项目通用资产(工艺规范、系统设计、配置流水线、文风规范等)
- `Design/vibe-test/` — vibe-test 专属(角色线、阶段拆解、事件卡、UI 美术、进度等)
- `Design/zhengdao-cards/` — 本项目专属(目前只有卡牌方案草案,后续增加)

**操作纪律**:

- **查询文档**: 优先读 `Design/_MOC.md` 顶层"## zhengdao-cards 分区"定位本项目专属;共享资产去"## 共享分区";vibe-test 资产仅作只读引用
- **新增文档**: 默认放 `Design/zhengdao-cards/<对应子目录>/`,frontmatter `tags` 必含 `项目/zhengdao-cards`,加入 `Design/_MOC.md` 对应分区索引
- **修改共享资产**: 共享资产改动同时影响 vibe-test 与 zhengdao-cards,**谨慎评估跨项目影响**
- **不修改 vibe-test 专属资产**: `Design/vibe-test/` 下仅读不写;若发现 vibe-test 资产有跨项目通用价值,讨论后迁移到 `Design/共享/`(慎)
- **`状态/已归档` 文件非必要不读取** —— 同 vibe-test 规范
- **删除 / 重命名文档前**: 用 `backlinks` 检查引用关系,避免断链
- **优先用 Obsidian CLI `move` 命令**: 移动文档时自动更新所有 `[[]]` 链接

**文档分层(L0–L3 + 横向;新文档前向生效,旧文档零回填)**:

吸收 tile-adventure 治理体系(见 [文档治理与进度看板_MVP实施](Design/zhengdao-cards/进度/文档治理与进度看板_MVP实施.md))。**新建**设计文档按层归位:

- **L0 方向** → [开发路线图](Design/zhengdao-cards/进度/开发路线图.md)(新方向先入此 → 再同步 `progress.yaml` entries)
- **L1 单模块设计** → 按 [MVP设计文档规范](Design/共享/工艺规范/MVP设计文档规范.md),放 `设计/` 或 `进度/`
- **L2 跨模块发包** → [八字段实装包模板](Design/zhengdao-cards/实装包模板.md)(仅大改动跨模块时切包)
- **L3 待办** → [待跟踪事项索引](Design/zhengdao-cards/待跟踪事项索引.md)(P0–P3)
- **横向灵感** → [设计候选库](Design/zhengdao-cards/设计候选库.md)
- **进度真相** → `Design/zhengdao-cards/_progress_board/progress.yaml`(机器态单点;`check_board.py` 校验、`serve.ps1` 看板网页)

> **覆盖逻辑与文档约定正交**: 进度看板 node 只链接文档(`docs[].path`),不关心文档是旧混层还是新分层写法 —— 一套 schema,新约定只把可选字段(如 `impl.modules`)填得更满。

**两步提交**(代码 + 设计文档一起改时):

1. 先 Design submodule 内 commit + push
2. 再主项目 commit + push(submodule 指针更新)

## CSV 配置流水线

**契约三件套完全继承 vibe-test**:

1. 设计契约: [配置翻译指南](Design/共享/配置流水线/配置翻译指南.md) —— 真源,关键章节由 `<!-- CSV_CONTRACT_ANCHOR: xxx -->` 标记
2. 自动翻译: `tools/csv_translator.py::parse_effect_expression`
3. 静态校验: `tools/csv_validator.py`(pre-commit 自动对涉及 `events.csv` 的目录执行)

**契约边界**(代码侧改动需同步回看三件套):

- `scripts/systems/world_event_config_assembler.gd::_apply_effect_or_resolution_action`(target 路由分支)— 迁移后路径
- 引擎新增/删除的 `rule_type` / `condition_type` 行为分支
- 资源 key 集合(`RESOURCE_KEYS`)、affinity value 格式

**卡牌方案特别注意**: MVP 1 期会有 CSV 字段层微调(`options.csv` 新增 `is_base`/`weight`/`trigger_condition`;`option_costs.cost_type` 改为接受资源类型列表等)。具体改动见 [前端表现卡牌化_MVP草案](Design/zhengdao-cards/进度/前端表现卡牌化_MVP草案.md) §5 接口边界。CSV 字段调整时**必须同步**契约三件套(指南文档锚点 / 翻译脚本 / 校验脚本)。

## 提交流程

**未经用户明确要求,禁止执行 `git commit` 或 `git push`。**

当用户要求提交时,根据改动类型决定是否需要审查:

- **需要审查**(feat/fix/refactor 等影响运行时行为的代码改动): 同 vibe-test 流程
- **可跳过审查**(`.gitignore` / 文档 / 纯配置文件等): 直接总结 + 提交 + 推送

提交信息使用中文,格式参照 `feat:/fix:/chore:` 前缀。

### 设计文档提交(两步提交)

设计文档目录是独立 Git submodule(共用 `vibe-test-design`),提交时需要两步:

1. **先提交 submodule 内部**: 进入 Design,add → commit → push
2. **再更新主项目 submodule 指针**: 回到本项目,add Design → commit → push

## 提交兜底(pre-commit hook)

`.git/hooks/pre-commit` 内容与 vibe-test 同源(Windows + WSL 兼容 PATTERN),自动运行:

1. `tools/fix_csv_imports.py`(CSV 导入格式检查)
2. `tools/check_design_submodule.py`(Design submodule 模式检查)
3. `tools/check_csv_contract_docs.py`(CSV 契约文档完整性检查)
4. 动态对涉及 `events.csv` 的目录运行 `tools/csv_validator.py`

任一失败即阻断提交。hook 只在 `.git/hooks/` 本地生效,**不入 repo**;跨机器克隆后需手动重建(从 vibe-test 拷贝)。

**Design submodule 另有独立 hook**(`Design/.git/hooks/pre-commit`,同样不入 repo、需手动重建): ①`_scripts/check_doc_tags.py` 标签合规检查(vault 全量,**阻断**);②`_scripts/check_progress_board_sync.py --partition zhengdao-cards` 看板漂移提醒(改了 `zhengdao-cards/进度/*.md` 却没同步 `progress.yaml` 时提示,**分区作用域、非阻断、对 vibe-test 零触发**)。与 vibe-test 的 Design checkout hook 各自独立。

### Python 命令兼容(Windows + WSL)

hook 内 Python 调用用 `PYTHON=$(command -v python 2>/dev/null || command -v python3 2>/dev/null)` 探测,同 vibe-test 规范。`PYTHONUTF8=1` 始终保留。

## 测试流程

Godot 统一通过 `tools/run_godot.ps1` 调用,不要假设系统 PATH 中存在 `godot`(同 vibe-test 规范)。

## 忽略文件

- `.claude/settings.local.json` 由用户自行管理,Claude 不主动提交。
- `tools/local_env.json` 是本地配置(含部署密钥等),git ignored,跨机器需手动重建(参考 `tools/local_env.example.json`)。

# 当前进度

> 进度详情在 `Design/zhengdao-cards/进度/` 下；本节仅维护索引(每条 ≤20 字状态摘要)。
> 方向总览 → [开发路线图](Design/zhengdao-cards/进度/开发路线图.md)(L0 真源);机器状态/焦点 → `Design/zhengdao-cards/_progress_board/progress.yaml`(`check_board.py` 校验、`serve.ps1` 看板网页);跨文档待办 → [待跟踪事项索引](Design/zhengdao-cards/待跟踪事项索引.md)。

## 活跃(≤10 条硬上限)

- [完整事件流程_实施](Design/zhengdao-cards/进度/完整事件流程_实施.md) — **🔧 当前焦点**:E0→批次三 ✅,剩 **UE 调优 pass**(参数归拢+体验+美术)→ I1 收尾。流程真源 [事件包交互流程_持久盘面与流程驱动_MVP](Design/zhengdao-cards/设计/事件包交互流程_持久盘面与流程驱动_MVP.md)
- [文档治理与进度看板_MVP实施](Design/zhengdao-cards/进度/文档治理与进度看板_MVP实施.md) — ✅ 已实施(S0–S5 + 冒烟 A–E):开发路线图/看板/待跟踪/候选库/八字段/分区 hook 落地

## 预启动(方向已认可,等启动时机)

- 普通事件资产 B④(§7.1) — 需可跑循环 playtest 后([开发路线图](Design/zhengdao-cards/进度/开发路线图.md) e3)
- 鉴定难度·成功率·标记 X.4 — 解 adapter `FALLBACK_DIFFICULTY` 占位(开发路线图 e4)

## 已归档

> 不在此常驻;查 `Design/zhengdao-cards/进度/` 对应文档或 `_progress_board/progress.yaml` 看板。已落地:Line A / Line B(前端核心循环,`6be2f63`→`ef8e086` + S8 鉴定算法)、D 阶段前置三议题(§7.1/7.2/7.3)。

## 核心设计真源

- [前端表现卡牌化_MVP草案](Design/zhengdao-cards/进度/前端表现卡牌化_MVP草案.md) — 卡牌交互版核心设计草案(§7.x 资源/回馈/撰写规格)
- [卡牌前端交互设计](Design/zhengdao-cards/设计/卡牌前端交互设计.md) — 前端表现+交互层规格(§2.9 聚焦循环 / §3 揭示 / §3.X 卡牌化前置)

## 进度维护规则

详情在进度文档、本节每条 ≤20 字;**活跃 ≤10 条硬上限**。状态变化时**三处同 commit**:进度文档 + 本节索引 + `Design/zhengdao-cards/_progress_board/progress.yaml`(pre-commit `check_progress_board_sync` 提醒、非阻断),改完跑 `_progress_board/check_board.py` 应全绿。新建进度文档加索引;**新增开发方向先入开发路线图 → 再加 progress.yaml entries**;新建/改设计文档按「Design 操作规范 § 文档分层」归层(旧文档零回填)。归档需冒烟通过。会话启动延续活跃进度时先读该文档顶部「新会话启动必读」。

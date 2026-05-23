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

### Python 命令兼容(Windows + WSL)

hook 内 Python 调用用 `PYTHON=$(command -v python 2>/dev/null || command -v python3 2>/dev/null)` 探测,同 vibe-test 规范。`PYTHONUTF8=1` 始终保留。

## 测试流程

Godot 统一通过 `tools/run_godot.ps1` 调用,不要假设系统 PATH 中存在 `godot`(同 vibe-test 规范)。

## 忽略文件

- `.claude/settings.local.json` 由用户自行管理,Claude 不主动提交。
- `tools/local_env.json` 是本地配置(含部署密钥等),git ignored,跨机器需手动重建(参考 `tools/local_env.example.json`)。

# 当前进度

进度详情在 `Design/zhengdao-cards/进度/` 下,此处仅维护索引。

## 活跃

- [前端表现卡牌化_MVP草案](Design/zhengdao-cards/进度/前端表现卡牌化_MVP草案.md) — **草案 v3 + 工程启动 checklist** + **§7.2 资源体系 + §7.3 回馈原则双议题收口**(2026-05-18~19):取消消耗类(保留金钱卡牌化外部循环)/ 心性系统重构(心性标记 + xinxing 切换 + 行为驱动)/ 关系标记分配机制 / 孤注一掷形态 / **能力 + 人际经验值升阶机制** / §7.3 涌现两路径(调度 + 鉴定)+ 5 条回馈原则 + 鉴定丰富度首要指标. 章节更新 §7.2 / §3.4 / §3.5 / §7.3 / §7.4 / §7.7 / §五. **§7.8 工程启动**: A/B/C ✅ + Godot 4.6.2 ✅. **§7.1 普通事件撰写规格 ✅ 全节收口**(2026-05-21, A 模板层: 处境模板/三类文字长度/选项两型+经济/5 类原型/四档结果; B/C/D 原则层: 鉴定分布三维度/两层回馈模型/金钱消费场景). **D 阶段 MVP 1 期前置三议题(§7.1/§7.2/§7.3)全部完成 → MVP 1 期实施**。

- [卡牌前端交互设计](Design/zhengdao-cards/设计/卡牌前端交互设计.md) — **前端表现 + 交互层设计规格**(2026-05-22): §0 原则 + §1 基础交互原语 + §2 整体布局 + **§3 结果揭示 ✅ 收口**(结果卡=统一反馈 / 投入产出隔离 / 数值变动=类标记点击领取 / 翻牌通用+四档 payload+显式 tier / 经验成长标记 / 取消弹窗;§3.2 引擎衍生问题待 B①)+ **「技术基础」节**(架构选型 Node2D+Camera2D+Control + B③ 实跑清单,收口 _explore #014). 前端技术储备 _explore #014(架构)/ #015(参考游戏设计)已完成并收口入本 doc。留后续:各卡视觉 / 投入鉴定细节(边原型边定)/ 牌库平移 / 心性·NPC 呈现。

## 下一阶段工作顺序(MVP 1 期实施 — 可新会话接手)

**路线**(2026-05-22 主对话决议): "骨架够用即转实施、细节边原型边回填";详见 [前端表现卡牌化_MVP草案](Design/zhengdao-cards/进度/前端表现卡牌化_MVP草案.md) §7.8 D 段。**当前切入 = B①**。

1. **B① 引擎扩展 + CSV 契约**(切入点,设计最完备、不依赖前端细节): §五 引擎能力 + CSV 字段调整 + 同步契约三件套。
2. **B② 前端表现层**: 落 [卡牌前端交互设计](Design/zhengdao-cards/设计/卡牌前端交互设计.md) §1 / §2;开工前补「各卡视觉结构」+「投入鉴定交互细节」两节。
3. **B③ 接入跑通 → vertical slice 原型验证交互细节 → 回填前端设计 doc**。
4. **B④ 少量普通事件资产(§7.1)+ 数值标定**(需可跑循环 playtest)。

## 预启动工作项(follow-up,可新会话接手)

- ~~**explore 四件套 queue 格式统一**~~ **✅ 已解决(2026-05-22)** — 采纳「混合·按需开问题段」方案:扁平任务为默认 + 问题段为可选增量层,`explore-supervise` 双模式自适应(扁平轻模式 / 问题模式),启动检查不再硬性要求问题段。改动落用户级 skill(supervise/kickoff + 各 references)+ setup 模板 + 实例侧 queue/README 契约文档,跨项目即时共享。#013 扁平场景冒烟走通(启动检查判扁平轻模式 → 扎实度 4/4 + 6 源全满足 → 确认归档)。详见 [Design/共享/进度/explore_skill_通用化进度.md](Design/共享/进度/explore_skill_通用化进度.md) 2026-05-22(三) 历史。

## 进度维护规则

同 vibe-test:详情在进度文档,索引在此处 ≤ 一行;更新时机=会话产生实质性进展;新建进度文档需在此添加索引;归档需冒烟测试通过;活跃区控制 ≤ 10 条;会话启动延续某活跃进度时先读该文档顶部「新会话启动必读」段。

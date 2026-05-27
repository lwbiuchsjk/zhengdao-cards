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

- [卡牌前端交互设计](Design/zhengdao-cards/设计/卡牌前端交互设计.md) — **前端表现 + 交互层设计规格**(2026-05-22): §0 原则 + §1 基础交互原语 + §2 整体布局 + **§3 结果揭示 ✅ 收口**(结果卡=统一反馈 / 投入产出隔离 / 数值变动=类标记点击领取 / 翻牌通用+四档 payload+显式 tier / 经验成长标记 / 取消弹窗;§3.2 引擎衍生问题待 B①)+ **「技术基础」节**(架构选型 Node2D+Camera2D+Control + B③ 实跑清单,收口 _explore #014). 前端技术储备 _explore #014(架构)/ #015(参考游戏设计)已完成并收口入本 doc。 **§2.5/§2.6 镜头驱动聚焦 + 双入口投入 改版收口**(2026-05-26 S3b 原型反馈,覆盖原汇聚模型)。留后续:各卡视觉 / 投入鉴定细节(边原型边定)/ 牌库平移 / 心性·NPC 呈现。

- [前端骨架_LineA_实施](Design/zhengdao-cards/进度/前端骨架_LineA_实施.md) — **Line A 前端骨架 + 架构验证 实施文档**(2026-05-25 启动 ~ 2026-05-26 收口):S1 牌桌底座+原语 + S2 锚点簇/因果链/手牌 + S3a 揭示循环(屏息→翻牌→显式档位→标记领取)+ S3b 鉴定聚焦(镜头驱动 zoom+居中+收起)+投入双入口(点击手牌为主/拖标记备)+ tier 由投入定. **Line A 全段 ✅,核心循环用 mock 跑通 → 新会话接 Line B**(提交 `6be2f63`→`ef8e086`)。

- [前端骨架_LineB_实施](Design/zhengdao-cards/进度/前端骨架_LineB_实施.md) — **Line B 引擎扩展 + CSV 契约 实施文档**(2026-05-27 落盘 + 推进):MVP 1 期**核心版**切片 = S1 数据契约层 → S2 资源标记系统 → S3 选项层调度 → **S8.0 标记投入鉴定算法**(独立支柱模块) → S8.2-S8.7 §3.2 汇合(待开). **S1/S2/S3/S8.0 ✅ 全段完成**(提交主项目 `d9bb63d`→`df5e0a0` + S8.0 待提交);单元 3/3 + 4/4 + 5/5 + 12/12 + 8/8 + 12/12 全过 / csv_validator 0 P1 0 P2 / 契约 8 锚点完整 / Godot --headless --quit 无报错. **S4-S7 增强切片延后**(字段先建, 行为后填). 详写 S1/S2/S3 + S8.0 (§3.6/3.7/3.8 算法独立支柱 + 12 项单元); S8 占位推进时增量。

## 下一阶段工作顺序(MVP 1 期实施 — 可新会话接手)

**路线**(2026-05-22 主对话决议): "骨架够用即转实施、细节边原型边回填",MVP 先建**基础骨架 + 核心体验循环**、增强类后置(见记忆 mvp-scope-skeleton-core-first);§7.8 D 段为底,**实施模型 = 双线并行 + §3.2 汇合**(2026-05-22 细化,以此处为准)。

**Line A ✅ 全段完成**(2026-05-25~26, 主项目 `6be2f63`→`ef8e086`): S1 牌桌底座+原语 / S2 锚点簇+因果链+手牌 / S3a 揭示循环 / S3b 鉴定聚焦(镜头驱动)+投入双入口. 核心循环用 mock 跑通; 详见 [前端骨架_LineA_实施](Design/zhengdao-cards/进度/前端骨架_LineA_实施.md) §八。

**Line B 进展状态**(2026-05-27):

- **S1 数据契约层 ✅** (`d9bb63d`): CSV 字段 +12 (options/attribute_names/ability_progression) + 契约三件套同步 (翻译指南 +3 锚点 / csv_translator / csv_validator) + ConfigRuntime 加载链路占位. 单元 3/3 + 4/4 + 5/5 (P2 修复). codex 审查 P1 无.
- **S2 资源标记系统 ✅** (`db68fce`): attribute_names +3 行 token + 新建 `resource_marker_pool.gd` (190 行 class_name ResourceMarkerPool) + world_event_engine `_apply_world_state_patch` 路由扩展 + `reflection_settle` 接入回流. ResourceMarkerPool 单元 12/12 + 引擎整合 8/8.
- **S3 选项层调度 ✅** (`df5e0a0`): assembler 读 4 新字段 + `_build_option_set` 五步算法 (trigger 门控/分组/必出+加权抽/排序/state) + `_weighted_sample_options`. 单元 8/8. 向后兼容: 现有 mvp 每 cp ≤3 选项走全产出分支行为不变.
- **S8.0 标记投入鉴定算法 ✅** (待提交): 独立支柱模块 `scripts/systems/marker_check_resolver.gd` (~140 行 class_name MarkerCheckResolver) + LineB §3.6/3.7/3.8 (设计依据 / 接口契约 / 冒烟测试). 算式 `r=(inv+1)/D` 线性 + 必然成功点 `inv=D-1` + 超额段 `p_gs=min(P_GS_MAX, STEP_PER_INV×excess)` + great_fail 恒 0 (§7.7 孤注链路产出). STEP_PER_INV=0.10 模块内固定 / DEFAULT_P_GS_MAX=0.50 可传入覆盖 / inv_max 随 P_GS_MAX 自动派生. 单元 12/12.

**新会话默认接手: Line B S8.2-S8.7 §3.2 汇合** (任务清单见 LineB 文档 §S8 占位段):

- **S8.2 引擎对外桥接接口**: 暴露 mock_data 所需接口形状 (events_for_pile / options_for_event / outcome_for_option) 桥接到 world_event_engine + MarkerCheckResolver
- **S8.3 mock_data.gd 改造**: 加 USE_ENGINE 开关 (true=引擎真数据 / false=旧 mock fallback); 保留双路并存供调试
- **S8.4 前端账单对齐 §3.2 stub**: tier 由引擎 (MarkerCheckResolver.resolve) 计算, markers/kind=entity 走标记领取
- **S8.5 测试数据补齐**: 给 world_event_mvp 至少 1 事件补 is_base/weight/trigger_condition/check_whitelist 字段
- **S8.6 整合冒烟**: 手动 playtest 跑核心循环用真数据 + headless 不报错 + mock 模式可切回验证
- **S8.7 文档收口**: LineB §3.14 (原 §3.11 顺延) 详写 + CLAUDE.md 活跃区 Line B 改为 ✅ 全段完成

**契约 mismatch 决议**(2026-05-27):

- Line A "投入标记 → vibe-test 骰子鉴定" 不对齐 → **新设计独立鉴定算法** (S8.0 已落地 MarkerCheckResolver)
- 算法核心: 投入 < D-1 始终有失败 / 投入 = D-1 必然成功 / 投入 > D-1 提升大成功 / 投入达上限封顶大成功率
- great_fail 不由常规鉴定产出 → 由 §7.7 孤注一掷链路产出 (fail → 选孤注 → 再败 → great_fail)

**之后**(S8 全段完成后): 各卡视觉 / 投入鉴定细节边原型边定 → **B④ 少量普通事件资产(§7.1)+ 数值标定**(需可跑循环 playtest)。

> **接口对齐状态**: Line A 的 mock 已朝 §3.2 stub 对齐(`scripts/ui/mock_data.gd` + `card_table.gd::_expand_result`); Line B 产出朝同一接口靠, S8.2-S8.4 接通时只做校准、避免大返工。**鉴定算式独立模块** (`MarkerCheckResolver`) → playtest 调参只改本模块, 外部调用方零改动。

## 预启动工作项(follow-up,可新会话接手)

- ~~**explore 四件套 queue 格式统一**~~ **✅ 已解决(2026-05-22)** — 采纳「混合·按需开问题段」方案:扁平任务为默认 + 问题段为可选增量层,`explore-supervise` 双模式自适应(扁平轻模式 / 问题模式),启动检查不再硬性要求问题段。改动落用户级 skill(supervise/kickoff + 各 references)+ setup 模板 + 实例侧 queue/README 契约文档,跨项目即时共享。#013 扁平场景冒烟走通(启动检查判扁平轻模式 → 扎实度 4/4 + 6 源全满足 → 确认归档)。详见 [Design/共享/进度/explore_skill_通用化进度.md](Design/共享/进度/explore_skill_通用化进度.md) 2026-05-22(三) 历史。

## 进度维护规则

同 vibe-test:详情在进度文档,索引在此处 ≤ 一行;更新时机=会话产生实质性进展;新建进度文档需在此添加索引;归档需冒烟测试通过;活跃区控制 ≤ 10 条;会话启动延续某活跃进度时先读该文档顶部「新会话启动必读」段。

# 自动科研多 Agent 使用指南

本指南用于当前工作区的多 Agent 科研闭环，覆盖从主题输入到论文修改与 `.tex` 投稿包生成的完整流程。

## 1. 适用场景

适合以下任务：
1. 给定主题，自动完成文献检索与研究现状总结。
2. 自动分析开源代码与可复现基线。
3. 自动构造创新点并评估可行性。
4. 自动设计实验、写代码、调试、运行与迭代。
5. 自动撰写论文、生成评审意见并给出修改方案。
6. 对已有项目做增量迭代：补跑实验缺口、更新论文、重新审稿，无需从头开始。
7. 将完成的 .md 论文草稿转换为指定学术会议格式的 .tex 投稿版本。
8. 降低论文的 AI 检测率，在保留全部科学内容的前提下重写句式与结构。

## 2. 角色分工

总控：
1. RND_AUTOPILOT：全流程编排与状态管理（从零开始）。
2. ITERATIVE_RND：已有项目的增量迭代编排（补跑实验、更新论文、重新审稿），复用已有产物，不重做已完成工作。

子 Agent：
1. PAPER_SCOUT：论文检索、证据表、SOTA 总结。
2. CODE_SCOUT：开源仓库地形、复现成本、扩展点。
3. INNOVATION_DESIGNER：创新假设与可行性矩阵。
4. EXPERIMENT_ENGINEER：实验计划、实现、调试、运行、迭代。
5. WRITING_AGENT：论文草稿生成。
6. REVIEWER_AGENT：审稿与修订计划。
7. TEX_WRITER：将 .md 论文草稿转换为符合学术会议要求的 .tex 论文（支持 AAAI / NeurIPS / ICML / ICLR / ACL 等）。
8. HUMANIZER：降低论文 AI 检测率，重写句式与结构，保留全部科学内容、数据和公式。

兼容入口：
1. RESEARCH_AUTOPILOT：仅文献侧流程。
2. TOPIC_INIT：仅检索和初筛。

## 3. 一键启动（推荐）

### 3.1 Chat 全流程模式
在 Copilot Chat 输入：

```
/rnd-autopilot-oneclick
Topic: 你的研究主题
Method description: （可选）大致描述你想用的方法或模型架构
```

默认行为：自动执行全流程阶段（含实验命令执行），并在可行时补齐缺失的最小可运行实验脚本后完成 smoke run。若提供 `Target venue/task`，流程在修订收敛后会自动生成对应会议格式的 `.tex` 投稿包；未提供时会生成 `generic` 版本。
建议开启严格执行：`Strict execution: true`。开启后若缺少可执行代码、数据或命令，流程会直接报错并停止，不再用 stub 继续。

可选覆盖参数（留空则使用默认值）：

| 参数 | 默认值 | 说明 |
|---|---|---|
| Method description | 无 | 用户对方法/模型的大致描述，提供后 INNOVATION_DESIGNER 会围绕该方法细化创新假设 |
| Year range | 2022 至今 | 检索年份范围 |
| Language | 与输入一致 | 产物语言 |
| Preferred sources | arXiv, Semantic Scholar, Google Scholar | 检索源 |
| Target venue/task | 无 | 目标会议或任务 |
| Compute budget | 无限制 | GPU 小时上限 |
| Deadline | 无 | 提交截止日 |
| Baseline repositories | 自动搜索 | GitHub 链接列表 |

### 3.2 研究模式（仅文献）
在 Copilot Chat 输入：

```
/research-autopilot-oneclick
Topic: 你的研究主题
```

适用于先做综述和证据积累，不涉及代码与实验执行。

### 3.3 迭代模式（已有项目增量更新）

适用于项目已有运行目录和部分产物，需要**补跑实验、更新论文、重新审稿**等增量操作，而不是全流程从头构建。

#### Chat 模式
在 Copilot Chat 输入：

```
/iterative-rnd-oneclick
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Iteration mode: full
```

可选迭代模式（`Iteration mode`）：

| 模式 | 说明 |
|---|---|
| `audit` | 仅审计：扫描已有产物，生成差距报告，不执行任何修改 |
| `experiment` | 补跑实验：根据差距报告中的实验缺口执行补充实验 |
| `paper` | 更新论文：使用最新实验结果重写论文草稿 |
| `review` | 重新评审：对最新论文草稿重新生成评审意见与修订计划 |
| `revision` | 修订闭环：评审 → 修改假设 → 补跑实验 → 重写论文 → 再评审，多轮迭代直至收敛 |
| `full` | 全量迭代：audit + experiment + paper + review，一次性完成所有增量更新 |

可选覆盖参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| Experiment gaps | 自动从 audit 检测 | 手动指定要补跑的实验名称列表 |
| Paper sections | 全部 | 指定只更新论文的某些章节 |
| Skip phases | 无 | 跳过指定阶段（如 `paper_scout,code_scout`） |

### 3.4 LaTeX 排版模式（.md → .tex）

将完成的 .md 论文草稿转换为符合指定学术会议格式的 .tex 投稿版本。

在 Copilot Chat 输入：

```
/tex-writer-oneclick
Paper draft: research_runs/tabular-foundation-multimodal-causal/20260331_run01/12_paper_draft_v17.md
Target venue: NeurIPS
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
```

支持的目标会议：AAAI、NeurIPS、ICML、ICLR、ACL（不指定时使用通用双栏模板）。

TEX_WRITER 会自动完成：
1. 解析 .md 草稿的逻辑结构（标题、章节、表格、图片、公式、算法）
2. 提取引用键并与 `references.bib` 交叉校验
3. 将 Markdown 表格转换为 LaTeX `tabular` / `booktabs` 格式
4. 将行内/块级数学公式转换为 LaTeX 数学环境
5. 生成符合目标会议要求的 preamble 和文档结构
6. 输出 `build.sh` / `build.ps1` 编译脚本

输出文件保存在 `<run_dir>/paper/<venue>/` 目录下。

### 3.6 AI 率优化模式（降低 AI 检测率）

对已完成的论文草稿进行人工化改写，降低 GPTZero、Turnitin AI 等工具的检测率，同时保留所有实验数据、公式和引用。

在 Copilot Chat 输入：

```
/humanizer
Paper draft: research_runs/tabular-foundation-multimodal-causal/20260331_run01/paper_draft_v17.md
```

可选参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| Target AI rate | <15% | 目标 AI 检测率上限 |
| Focus sections | 全部 | 只改写指定章节（如 `abstract, intro, conclusion`） |
| Run directory | 自动检测 | 运行目录路径 |

HUMANIZER 的改写策略：
- 消除 AI 典型句式开头（"In recent years..."、"It is worth noting..."等）
- 打破段落/句子的均匀长度和平行结构
- 增加信息密度，减少填充性语句
- 保留所有数字、公式、表格和引用不变

输出文件：`<filename>_humanized.md`（或 `.tex`）+ `humanization_report.md`。

## 4. 输出目录与文件

### 4.1 全流程模式输出
目录：research_runs/<topic_slug>/<run_id>/

关键文件：
1. 01_topic_and_constraints.md
2. 02_sota_evidence_table.md
3. 03_open_source_landscape.md
4. 04_innovation_hypotheses.md
5. 05_feasibility_matrix.md
6. 06_experiment_plan.md
7. 07_implementation_log.md
8. 08_debug_log.md
9. 09_experiment_results.md
10. 10_iteration_decisions.md
11. 11_theoretical_analysis.md
12. 12_paper_draft.md
13. 13_truthfulness_report.md
14. 14_review_report.md
15. 15_revision_plan.md
16. state.json
17. `paper/<venue>/`（投稿 `.tex` 包，含 `main.tex`、`references.bib`、编译脚本、`submission_checklist.md`）

### 4.2 研究模式输出
目录：research_runs/<topic_slug>/research_autopilot/

关键文件：
1. 01_scope_and_strategy.md
2. 02_paper_shortlist.md
3. 03_evidence_table.md
4. 04_review_draft.md
5. 05_next_steps.md

### 4.3 迭代模式输出
目录：与原运行目录相同（原地更新）。

迭代模式不创建新目录，而是在已有 `<run_dir>/` 下原地更新和追加文件：
- 已有产物按需刷新（如 `09_experiment_results.md` 追加新实验结果）
- 论文草稿自动创建新版本号（如 `12_paper_draft_v18.md`）
- `state.json` 更新 `iteration_history` 数组，记录每次迭代的时间、模式和变更摘要
- `blocker_log.jsonl` 追加迭代事件日志

### 4.4 LaTeX 排版输出
目录：`<run_dir>/paper/<venue>/`

关键文件：
1. `main.tex` — 主文档
2. `references.bib` — 参考文献库
3. `build.sh` / `build.ps1` — 编译脚本
4. `figures/` — 图片目录（从运行目录复制）
5. `appendix.tex` — 附录（如有）

## 5. 推荐执行流程

```
输入 Topic
    │
    ▼
[PAPER_SCOUT]  检索论文，写 02_sota_evidence_table.md
[CODE_SCOUT]   分析基线，写 03_open_source_landscape.md
    │（两者可并行，pipeline 顺序执行）
    ▼
[INNOVATION_DESIGNER]  写 04 + 05（假设与可行性矩阵）
    │
    ▼
 ┌──────────────────────────────────────────────────┐
 │         迭代循环（最多 patience 轮）              │
 │  [EXPERIMENT_ENGINEER] 先做 scaffold（补齐最小可运行工程）│
 │  [EXPERIMENT_ENGINEER] 再执行实验，写 07/08/09/10 │
 │       ↓ 指标提升 >= min_delta?                   │
 │       是 → 退出循环    否 → 回到 INNOVATION      │
 └──────────────────────────────────────────────────┘
    │
    ▼
 ┌──────────────────────────────────────────────────┐
 │     【NEW】结果预期检验门控                       │
 │  对比最佳指标 vs success_metric                   │
 │       ↓ 是否满足预期?                             │
 │       是 → 进入理论分析                           │
 │       否 → 记录差距，回到 INNOVATION + EXPERIMENT │
 │            （最多 expectation_patience 轮，默认2） │
 └──────────────────────────────────────────────────┘
    │
    ▼
 ┌──────────────────────────────────────────────────┐
 │     理论分析阶段                               │
 │  产出 11_theoretical_analysis.md                  │
 │  （复杂度、收敛性、误差界、泛化分析等）      │
 └──────────────────────────────────────────────────┘
    │
    ▼
[WRITING_AGENT]   写 12_paper_draft.md
    │
    ▼
 ┌──────────────────────────────────────────────────┐
 │     【NEW】论文真实性检验门控                     │
 │  交叉验证论文宣称 vs 代码实现和实验结果           │
 │       ↓ 所有宣称真实?                             │
 │       是 → 进入评审                               │
 │       否 → 产出 13_truthfulness_report.md         │
 │            → 回到 WRITING_AGENT 修正草稿          │
 │            （最多 truthfulness_patience 轮，默认2）│
 └──────────────────────────────────────────────────┘
    │
    ▼
[REVIEWER_AGENT]  写 14_review_report.md
    │
    ▼ 修改反馈循环（最多 revision_patience 轮）
 ┌────────────────────────────────────────────────────────────┐
 │  R1: [INNOVATION_DESIGNER] 根据评审反馈调整研究假设       │
 │  R2: [EXPERIMENT_ENGINEER] Scaffold 调整工程              │
 │  R3: [EXPERIMENT_ENGINEER] 重新运行实验，写 09_新结果     │
 │  R4: [WRITING_AGENT] 根据新结果重写论文                   │
 │  R5: [REVIEWER_AGENT] 重新审稿                            │
 │       ↓ 重大问题数量 < threshold?                        │
 │       是 → 退出循环    否 → 返回 R1（继续修改）           │
 └────────────────────────────────────────────────────────────┘
    │
    ▼
 [TEX_WRITER]  生成 `paper/<venue>/main.tex` 与投稿检查清单
   │
   ▼
  归档 state.json，全流程结束
```

操作建议：
1. 先用 `-DryRun` 确认任务文件结构无误。
2. 再正式运行，按 pipeline 提示逐阶段调用对应 Agent。
3. 每轮实验后检查 `09_experiment_results.md` 中的 `## Best Metric` 行。
4. 若指标多轮无进展，检查 `10_iteration_decisions.md` 中的 Pivot 建议。
5. **【NEW】结果预期检验**：实验迭代完成后，pipeline 会自动对比最佳指标与 `success_metric`。若不满足预期，将回到创新+实验循环（最多 `expectation_patience` 轮）。检查 `10_iteration_decisions.md` 中的 `## Result Expectation Mismatch` 段落了解差距分析。
6. 论文草稿完成后，**【NEW】真实性检验**会自动交叉验证论文中的所有数据宣称和方法描述是否与代码实现、实验结果一致。若发现不一致，会产出 `13_truthfulness_report.md` 并要求 WRITING_AGENT 修正（最多 `truthfulness_patience` 轮）。
7. 论文真实性通过后进入评审。用 `14_review_report.md` 中的批评意见驱动修改反馈循环。
8. 修改反馈循环会自动在「重大问题数」足够少时停止，或达到 `revision_patience` 轮次上限。
9. 修订收敛后，检查 `paper/<venue>/submission_checklist.md`，确认 `.tex` 投稿包已经生成且记录了编译状态、页数处理与待补资源。

## 5.5 结果预期检验门控（NEW）

### 功能说明

结果预期检验门控在**实验迭代循环之后、论文写作之前**自动执行。它对比实验产出的最佳指标与任务文件中定义的 `success_metric`，确保实验结果达到预期再进入写作环节。

**工作流程**：
1. 从 `09_experiment_results.md` 中提取最佳指标值。
2. 解析 `success_metric`（如 `AUROC >= 0.90`）中的目标阈值。
3. 若满足预期：直接进入 WRITING_AGENT。
4. 若不满足预期：
   - 在 `10_iteration_decisions.md` 中追加 `## Result Expectation Mismatch`，记录：预期目标、实际结果、差距分析、改进方向。
   - 向 `blocker_log.jsonl` 写入 `result-expectation-mismatch` 事件。
   - 返回 INNOVATION_DESIGNER 调整假设 → EXPERIMENT_ENGINEER 重新执行实验。
   - 重新检查预期门控。最多执行 `expectation_patience` 轮（默认 2）。
   - 若仍不满足，在 `10_iteration_decisions.md` 中标注 `[EXPECTATION UNMET]`，带着最佳可用结果进入写作。

### 任务文件配置

```json
{
  "success_metric": "AUROC >= 0.90",
  "expectation_patience": 2
}
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `success_metric` | string | 无 | 定义实验成功标准的表达式 |
| `expectation_patience` | integer | 2 | 结果预期检验最大重试轮数 |

## 5.6 论文真实性检验门控（NEW）

### 功能说明

论文真实性检验门控在 **WRITING_AGENT 完成论文草稿之后、REVIEWER_AGENT 评审之前**自动执行。它交叉验证论文中的宣称与实际代码实现、实验结果是否一致，避免论文「说的」和「做的」不符。

**检验维度**：
1. **数据一致性**：论文中每个定量宣称（数字/百分比/排名）是否与 `09_experiment_results.md` 中的结果表吻合。
2. **方法一致性**：论文方法部分描述的组件/技术是否在 `07_implementation_log.md` 和实验代码中有对应实现。
3. **贡献一致性**：摘要和引言中的贡献声明是否有实验证据支撑。

**工作流程**：
1. 逐项检查 `12_paper_draft.md` 中的宣称。
2. 若全部通过：在 `state.json` 中标记 `phase_status.truthfulness = passed`，进入评审。
3. 若发现不一致：
   - 产出 `13_truthfulness_report.md`，逐条列出：宣称原文、实际证据、判定结果（match / mismatch / unverifiable）。
   - 向 `blocker_log.jsonl` 写入 `truthfulness-verification-failed` 事件。
   - 返回 WRITING_AGENT 修正草稿。
   - 再次执行真实性检验。最多执行 `truthfulness_patience` 轮（默认 2）。
   - 若仍未完全通过，将真实性报告作为评审的强制输入，附带传递给 REVIEWER_AGENT。

### 任务文件配置

```json
{
  "truthfulness_patience": 2
}
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `truthfulness_patience` | integer | 2 | 真实性检验最大重试轮数 |

## 5.7 修改反馈循环

### 功能说明

修改反馈循环是 v2 新增的**全闭环**机制。解决论文初稿评审后"只有建议但无法自动迭代"的问题。

**工作流程**：
1. **R1 创新视角微调**：INNOVATION_DESIGNER 读取审稿意见，重新审视假设与设计，进行有针对性的微调。
2. **R2 代码与实验调整**：EXPERIMENT_ENGINEER 根据新假设调整代码、超参、数据处理策略。
3. **R3 重新运行实验**：EXPERIMENT_ENGINEER 在新设置下重新执行实验，产生改进的结果。
4. **R4 论文重写**：WRITING_AGENT 以新的实验数据为基础重新组织论文内容，强调改进点。
5. **R5 再次评审**：REVIEWER_AGENT 对新论文进行独立评审。
6. **收敛判断**：
   - 若新评审中重大问题数 < 阈值，**自动停止循环**，达成收敛。
   - 若仍有多个重大问题，**自动返回 R1**，继续迭代。
   - 达到 `revision_patience` 轮次上限，**强制停止**，使用最佳版本。

### 任务文件配置

在任务文件（如 `research_runs/<topic_slug>/task.json`）中添加修改循环参数：

```json
{
  "topic": "...",
  "enable_revision_loop": true,
  "revision_patience": 3,
  "revision_convergence_threshold": 0.1,
  ...
}
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enable_revision_loop` | boolean | `true` | 启用修改反馈循环。设为 `false` 时退化为单轮评审。 |
| `revision_patience` | integer | 3 | 最大修改轮次数。防止无限循环。 |
| `revision_convergence_threshold` | number | 0.1 | 收敛判断的建议数阈值。评审建议数 < 当前轮数 × 阈值 时视为收敛。 |

### 示例与产物

运行后，在 `state.json` 中新增：
```json
{
  "revision_round": 2,
  "best_metric": 0.845,
  "phase_status": {
    "writing": "done",
    "review": "done",
    "experiment": "done",
    ...
  }
}
```

每轮修改的输出文件按需更新（例如第二轮修改会覆盖 `12_paper_draft.md` 和 `14_review_report.md`）。
所有重要日志记录到 `blocker_log.jsonl`，包括收敛信息与早停原因。

`-Resume` 与修改循环的行为说明（新版）：
1. 在修改循环中会强制执行 innovation/scaffold/experiment/writing/review，不再因已有文件直接跳过。
2. 在 `-AutoConfirm` 模式下，若阶段文件已存在，会自动追加 refresh 标记，确保循环有可审计的文件级更新痕迹。
3. `state.json` 会记录 `revision_score_trajectory`，`blocker_log.jsonl` 会追加每轮 `revision-iteration` 事件（含 round/score/delta）。

### 禁用修改循环（回退模式）

如果希望保留原来的单轮评审流程，设置任务文件中：
```json
{
  "enable_revision_loop": false,
  ...
}
```

此时 pipeline 会执行传统的 writing → review → revision（一次性修改方案）流程。

## 6. 参数与决策建议


建议在任务文件中明确：

| 字段 | 推荐值 | 说明 |
|---|---|---|
| `success_metric` | 如 `"AUROC >= 0.90"` | 明确目标，写入 01 文件 |
| `min_delta` | 0.01 ~ 0.02 | 低于此值不算有效提升（实验迭代循环） |
| `patience` | 2 ~ 3 | 容忍连续无进展轮数（实验迭代循环） |
| `enable_revision_loop` | `true` 或 `false` | 启用修改反馈循环（默认 true） |
| `revision_patience` | 2 ~ 4 | 最大修改迭代轮数（默认 3） |
| `revision_convergence_threshold` | 0.05 ~ 0.15 | 收敛判断的建议数阈值（默认 0.1）|
| `expectation_patience` | 1 ~ 3 | **【NEW】** 结果预期检验最大重试轮数（默认 2）|
| `truthfulness_patience` | 1 ~ 3 | **【NEW】** 论文真实性检验最大重试轮数（默认 2）|
| `compute_budget_gpu_hours` | 按实际 | 防止超算力预算 |

决策规则：
- `实验阶段`：当前指标 − 历史最佳 ≥ min_delta → 继续该方向，进入结果预期检验。连续无提升轮数 ≥ patience → 触发早停。
- **【NEW】结果预期检验阶段**：最佳指标 vs `success_metric`。满足 → 进入写作。不满足 → 返回创新+实验。`expectation_patience` 轮后仍不满足 → 标注 `[EXPECTATION UNMET]` 后继续写作。
- **【NEW】真实性检验阶段**：论文宣称 vs 代码+结果。全部通过 → 进入评审。有不一致 → 返回 WRITING_AGENT 修正。`truthfulness_patience` 轮后仍不通过 → 附带真实性报告进入评审。
- **修改阶段**：
  - 硬门控：`overall_score >= revision_score_threshold` 或 `revision_round >= revision_patience_max_rounds`。
  - 软诊断：`revision_patience` + `revision_convergence_threshold` 用于分数停滞预警与日志记录，不单独触发提前停止。

## 6.5 Never-Stop 机制

Agent 内置了“永不停顿”保障，确保任何单点故障不会终止整个流程。

| 场景 | 自动处理方式 |
|---|---|
| API 限速 / 网络错误 | 指数退避重试（默认 3 次，间隔 30s/60s/120s） |
| 实验命令退出码非 0 | 记录到 `08_debug_log.md`，继续执行下一条命令 |
| Agent 未写输出文件 | 自动写入 stub 文件（含 `## Downstream: Safe to proceed` 标记） |
| 输入文件缺失 | 自动写入 stub 输入，保证下游 Agent 不因找不到文件而崩溃 |
| 指标无法解析 | 写入哨兵值 `## Best Metric: 0.0000`，跳过收敛判断 |
| 运行中断后续跑 | 使用 ITERATIVE_RND 迭代模式，读取 `state.json` 跳过已完成阶段 |
| **修改循环收敛失败** | 自动记录到 blocker_log，强制退出循环，使用迄今最佳版本 |
| **【NEW】结果预期检验不通过** | 记录差距到 `10_iteration_decisions.md`，回到创新+实验循环；耐心耗尽后标注 `[EXPECTATION UNMET]` 继续写作 |
| **【NEW】论文真实性检验不通过** | 产出 `13_truthfulness_report.md`，回到 WRITING_AGENT 修正；耐心耗尽后附带报告进入评审 |

所有失败事件均记录到运行目录下的 `blocker_log.jsonl`，每行一条 JSON，便于事后诊断。

## 7. 质量与可信性要求

1. 禁止虚构论文元数据、链接或实验结果。
2. 不确定字段必须显式标注 unknown。
3. 区分事实、推断和猜测。
4. 每个主要结论至少附一条可追溯证据。
5. 每个主要章节至少写一条局限性。

## 8. 常见问题与故障诊断

**Q: 实验命令执行失败了多次？**  
A: 检查 `08_debug_log.md` 和 `blocker_log.jsonl`。优先确认环境是否正确激活（conda/venv），再按最小实验单元依次排查。

**Q: 实验一直不收敛？**  
A: 检查 `10_iteration_decisions.md` 的 Pivot 建议。patience 耗尽后 pipeline 会自动进入写作阶段；你也可以主动修改任务文件中的假设后重跑。

**【NEW】Q: 修改反馈循环怎么总是收不敛？**  
A: 检查 `14_review_report.md` 中评审意见的质量。若评审意见过于宽泛或相互矛盾，可：
   1. 手动提高 `revision_convergence_threshold` 值（如从 0.1 改为 0.20），降低收敛门槛。
   2. 降低 `revision_patience`，提前强制退出。
   3. 检查 INNOVATION_DESIGNER 和 EXPERIMENT_ENGINEER 是否真正理解了评审意见并做出实质调整。

**【NEW】Q: 修改反馈循环中是否会重新实验和重写论文？**  
A: 是的。每一轮修改循环都包括：
   - INNOVATION_DESIGNER 根据评审意见调整假设
   - EXPERIMENT_ENGINEER 实现代码调整并重新运行实验
   - WRITING_AGENT 根据新的实验结果完整重写论文
   - REVIEWER_AGENT 对新论文独立评审

这形成了一个完整的反馈闭环，直到评审意见足够少或轮数达到上限。


**Q: 文献很多但难以形成创新点？**  
A: 先查 `05_feasibility_matrix.md`，过滤高成本低收益方向，再聚焦到可证伪、可验证的最小假设。

**Q: 论文初稿质量不稳定？**  
A: 优先补齐 `02_sota_evidence_table.md` 和 `09_experiment_results.md` 两类证据，再让 WRITING_AGENT 重写方法和实验章节。

**【NEW】Q: 实验结果没达到预期怎么办？**  
A: 结果预期检验门控会自动检测。若不达预期，pipeline 会自动回到 INNOVATION_DESIGNER 调整假设并重跑实验（最多 `expectation_patience` 轮）。你也可以：
   1. 在任务文件中调低 `success_metric` 的目标阈值。
   2. 增大 `expectation_patience` 以允许更多轮尝试。
   3. 检查 `10_iteration_decisions.md` 中的 `## Result Expectation Mismatch` 了解差距分析。

**【NEW】Q: 论文宣称与实验结果不一致怎么办？**  
A: 真实性检验门控会在评审前自动检测。发现不一致时会产出 `13_truthfulness_report.md` 并要求 WRITING_AGENT 修正。若持续不一致：
   1. 检查 `13_truthfulness_report.md` 中的具体不一致列表。
   2. 确认 `09_experiment_results.md` 中的数据是否正确。
   3. 确认 `07_implementation_log.md` 中记录的实现是否与论文方法描述一致。
   4. 手动修正后重跑 writing 阶段。
A: 优先补齐 `02_sota_evidence_table.md` 和 `09_experiment_results.md` 两类证据，再让 WRITING_AGENT 重写方法和实验章节。

**Q: 上次运行中断，如何续跑？**  
A: 使用 ITERATIVE_RND 迭代模式，指定已有运行目录，agent 会读取 `state.json` 跳过已完成的阶段。

**Q: 如何查看所有失败原因？**  
A: 打开运行目录下的 `blocker_log.jsonl`，每行是一条 JSON，包含时间戳、阶段名和失败原因。

**Q: 项目已有产物，不想从头跑全流程，怎么办？**  
A: 使用 `ITERATIVE_RND`（迭代模式）。在 Chat 中输入 `/iterative-rnd-oneclick`，指定已有运行目录和迭代模式（如 `experiment` 只补跑实验，`paper` 只更新论文）。迭代模式会自动扫描已有产物，只做增量更新。

**Q: ITERATIVE_RND 和 RND_AUTOPILOT 有什么区别？**  
A: `RND_AUTOPILOT` 从零开始构建项目（全流程），`ITERATIVE_RND` 在已有项目基础上做增量迭代（补实验、改论文、重审稿）。如果你的运行目录已有大量完成的产物，用 ITERATIVE_RND 可以避免重复工作。

**Q: 论文草稿写完了，怎么转成 .tex？**  
A: 使用 `TEX_WRITER`。在 Chat 中输入 `/tex-writer-oneclick`，指定 .md 草稿路径和目标会议（如 NeurIPS）。TEX_WRITER 会自动完成结构解析、表格转换、公式转换、引用校验等，输出到 `paper/<venue>/` 目录。

**Q: TEX_WRITER 支持哪些会议模板？**  
A: 内置 AAAI、NeurIPS、ICML、ICLR、ACL 五个模板。不指定会议时使用通用双栏格式。如需其他会议，可在 prompt 中提供模板文件路径。

**Q: 如何降低论文 AI 检测率？**  
A: 使用 `HUMANIZER`。在 Chat 中输入 `/humanizer`，指定论文草稿路径。HUMANIZER 会消除 AI 典型句式、打破均匀结构、增加句式变化，同时保留所有数据和公式不变。输出为 `*_humanized.md`。

**Q: HUMANIZER 会修改实验数据或公式吗？**  
A: 不会。HUMANIZER 严格保留所有数字、公式、表格数据和引用。只改写叙述性文字的句式结构和词汇选择。

## 9. 最小可用模板

可直接复制到聊天框：

/rnd-autopilot-oneclick
Topic: 你的研究主题
Method description: （可选）你的方法大致描述，例如"基于 Transformer 的多模态因果发现模型，用对比学习对齐不同模态特征后做因果图推断"
Year range: 2022-2026
Language: 中文
Preferred sources: arXiv, Semantic Scholar, Google Scholar
Target venue/task: 目标会议或任务
Compute budget: 例如 80 GPU-hours
Deadline: 例如 2026-06-30
Baseline repositories: 可选 GitHub 链接列表
Strict execution: true

迭代模式最小模板：

/iterative-rnd-oneclick
Run directory: research_runs/<topic_slug>/<run_id>
Iteration mode: full

LaTeX 排版最小模板：

/tex-writer-oneclick
Paper draft: research_runs/<topic_slug>/<run_id>/12_paper_draft.md
Target venue: NeurIPS
Run directory: research_runs/<topic_slug>/<run_id>

AI 率优化最小模板：

/humanizer
Paper draft: research_runs/<topic_slug>/<run_id>/paper_draft_v17.md

## 10. 相关文件

### Agent 定义

| 文件 | 职责 |
|---|---|
| .github/agents/RND_AUTOPILOT.agent.md | 总控编排 |
| .github/agents/PAPER_SCOUT.agent.md | 论文检索与 SOTA |
| .github/agents/CODE_SCOUT.agent.md | 开源代码分析 |
| .github/agents/INNOVATION_DESIGNER.agent.md | 创新点与可行性 |
| .github/agents/EXPERIMENT_ENGINEER.agent.md | 实验实现与迭代 |
| .github/agents/WRITING_AGENT.agent.md | 论文撰写 |
| .github/agents/REVIEWER_AGENT.agent.md | 评审与修订 |
| .github/agents/ITERATIVE_RND.agent.md | 已有项目增量迭代编排 |
| .github/agents/TEX_WRITER.agent.md | .md → .tex 论文排版 |
| .github/agents/HUMANIZER.agent.md | 降低论文 AI 检测率 |
| .github/agents/RESEARCH_AUTOPILOT.agent.md | 兼容入口（仅文献） |
| .github/agents/TOPIC_INIT.agent.md | 兼容入口（仅检索） |

### Prompt 与指令

| 文件 | 用途 |
|---|---|
| .github/prompts/rnd-autopilot-oneclick.prompt.md | 全流程一键 Chat 入口 |
| .github/prompts/research-autopilot-oneclick.prompt.md | 研究模式 Chat 入口 |
| .github/prompts/iterative-rnd.prompt.md | 迭代模式 Chat 入口 |
| .github/prompts/tex-writer.prompt.md | LaTeX 排版 Chat 入口 |
| .github/prompts/humanizer.prompt.md | AI 率优化 Chat 入口 |
| .github/instructions/research-quality.instructions.md | 全局质量约束 |

## 11. 任务文件编写指南

创建任务 JSON 文件，按以下说明填写：

```jsonc
{
  // 必填
  "topic": "完整的研究主题描述",
  "topic_slug": "研究主题的小写连字符形式",   // 只能含 a-z 0-9 -
  "success_metric": "具体指标与目标，如 AUROC >= 0.90",

  // 推荐填写
  "method_description": "大致描述你想要的方法或模型，例如：基于 Transformer 的多模态特征对齐与因果发现联合框架",
  "year_range": "2022-2026",
  "language": "Chinese",
  "target_venue": "NeurIPS 2026",
  "compute_budget_gpu_hours": 80,
  "min_delta": 0.015,
  "patience": 2,
  "expectation_patience": 2,
  "truthfulness_patience": 2,

  // 可选：实验命令（不填则从 06_experiment_plan.md 自动解析）
  "commands": {
    "setup": [
      "python -m pip install -r requirements.txt"
    ],
    "experiment": [
      "python train.py --seed 42"
    ],
    // 输出单个数字的评估命令，pipeline 用此自动解析指标
    "evalMetric": "python eval.py --print-auroc"
  }
}
```

环境约定：默认复用你当前已激活的 Python/conda 环境，不自动创建新环境。允许在 `setup` 中安装缺失包（如 `python -m pip install ...`）。仅当你明确要求时，才在命令里加入 `conda create`/`python -m venv`。

`topic_slug` 转换规则：全部小写，空格和 `/\:` 替换为 `-`，只保留 `a-z 0-9 -`，合并连续 `-`。

### 11.2 迭代配置（用于 ITERATIVE_RND）

在已有任务文件中添加 `iteration` 字段，配置迭代行为：

```jsonc
{
  "topic": "...",
  "iteration": {
    "mode": "full",                    // audit | experiment | paper | review | revision | full
    "run_dir": "research_runs/tabular-foundation-multimodal-causal/20260331_run01",
    "experiment_gaps": [],              // 可选：手动指定要补跑的实验
    "paper_sections": [],               // 可选：只更新指定论文章节
    "skip_phases": []                   // 可选：跳过指定阶段
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `iteration.mode` | string | 迭代模式，参见 §3.4 的模式表 |
| `iteration.run_dir` | string | 已有运行目录路径 |
| `iteration.experiment_gaps` | string[] | 手动指定实验缺口，留空则自动检测 |
| `iteration.paper_sections` | string[] | 只更新指定章节，留空则更新全部 |
| `iteration.skip_phases` | string[] | 跳过的阶段列表（如 `["paper_scout", "code_scout"]`） |

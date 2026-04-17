# 自动科研多 Agent 工作流

基于 VS Code Copilot 的多 Agent 编排科研全流程系统，覆盖从**选题 → 文献 → 创新 → 实验 → 论文 → 评审 → 修订 → 投稿排版**的完整闭环。

## 核心特性

- **全流程自动化**：一键启动，自动完成文献检索、SOTA 分析、创新点设计、实验运行、论文撰写、同行评审、修订迭代和 LaTeX 投稿包生成
- **多 Agent 协同**：9 个专业化子 Agent + 2 个总控编排 Agent，各司其职
- **严格质量门控**：6 层执行门控（产物 → 运行 → 结果 → 严谨性 → 真实性 → 审稿），确保科研可信度
- **可迭代可追溯**：版本化产物 + 状态追踪 + 阻塞日志，随时可中断续跑
- **投稿就绪**：自动将论文草稿转换为 AAAI / NeurIPS / ICML / ICLR / ACL 等会议格式的 `.tex` 投稿包
- **AI 率优化**：内置 HUMANIZER 模块，在保留科学内容的前提下降低 AI 检测率

## 快速开始

### 从零开始全流程

在 Copilot Chat 输入：

```
/rnd-autopilot-oneclick
Topic: 你的研究主题
Method description: （可选）你的方法大致描述
Target venue/task: （可选）目标会议，如 NeurIPS
```

流程会自动执行文献检索、代码分析、实验运行、论文撰写、评审修订，最终生成投稿用 `.tex` 包。

### 迭代已有项目

如果已有运行目录和部分产物：

```
/iterative-rnd-oneclick
Run directory: research_runs/你的项目/运行目录
Iteration mode: full
```

支持 `audit`（审计）、`experiment`（补实验）、`paper`（更新论文）、`review`（重新评审）、`tex`（生成投稿包）、`full`（全量迭代）等模式。

### 单独调用 LaTeX 投稿包生成

```
/tex-writer-oneclick
Paper draft: research_runs/你的项目/12_paper_draft.md
Target venue: AAAI
Run directory: research_runs/你的项目/运行目录
```

### 仅做文献检索（不跑实验）

```
/research-autopilot-oneclick
Topic: 你的研究主题
```

## 角色分工

### 总控编排

| Agent | 职责 | 适用场景 |
|-------|------|----------|
| `RND_AUTOPILOT` | 全流程从零到一编排 | 新项目启动 |
| `ITERATIVE_RND` | 已有项目增量迭代 | 补实验、更新论文、重新审稿 |

### 专业化子 Agent

| Agent | 职责 | 触发词 |
|-------|------|--------|
| `PAPER_SCOUT` | 论文检索、证据表、SOTA 总结 | 搜索论文, SOTA summary |
| `CODE_SCOUT` | 开源仓库分析、复现评估 | 分析开源代码, baseline repo |
| `INNOVATION_DESIGNER` | 创新假设与可行性矩阵 | 构造创新点, novelty design |
| `EXPERIMENT_ENGINEER` | 实验实现、调试、运行、迭代 | 设计实验, 运行实验 |
| `THEORETICAL_ANALYST` | 从原理到设计的理论分析 | 理论分析, 从原理到设计, theoretical analysis |
| `WRITING_AGENT` | 论文草稿撰写 | 撰写论文, paper draft |
| `REVIEWER_AGENT` | 模拟同行评审与修订计划 | 论文评审, 审稿意见 |
| `TEX_WRITER` | Markdown → LaTeX 投稿包转换 | 生成LaTeX, md转latex |
| `HUMANIZER` | 降低论文 AI 检测率 | 降低AI率, humanize paper |

## 流程架构

```
选题约束 → 文献检索 → 代码分析 → 创新设计 → 实验循环
                                                ↓
                                        结果预期检验
                                                ↓
                                  理论分析（从原理到设计）
                                  [THEORETICAL_ANALYST]
                                  产出 11_theoretical_analysis.md
                                                ↓
                                          论文撰写
                                                ↓
                                      真实性检验 → 同行评审
                                                ↓
                                      修订循环（多轮迭代）
                                                ↓
                                      LaTeX 投稿包生成
```

## 执行门控

流程内置 7 层质量门控，任何一层不通过都会触发修正循环：

| 门控 | 检查内容 | 失败处理 |
|------|----------|----------|
| **产物门控** | 实验脚本、依赖、配置、可运行命令存在 | 自动补齐最小可运行脚本 |
| **运行门控** | 至少一次 smoke 实验成功 | 重试 + 记录到调试日志 |
| **结果门控** | 可解析的指标行 + 完整结果表 | 重试 + 记录到结果文件 |
| **严谨性门控** | ≥2 数据集、≥3 基线、mean ± std、消融实验 | 阻止进入写作，要求补实验 |
| **理论分析门控** | `11_theoretical_analysis.md` 包含原理到设计映射、复杂度分析、理论-实验桥接 | 委派 THEORETICAL_ANALYST 补齐 |
| **真实性门控** | 论文宣称 vs 代码实现和实验结果一致 | 产出真实性报告，要求修正草稿 |
| **审稿门控** | 评审报告包含 `## Overall Score: <分数>/100` | 进入修订循环 |

## 输出产物

### 全流程模式

所有产物保存在 `research_runs/<主题>/<运行ID>/` 目录下：

| 文件 | 内容 |
|------|------|
| `01_topic_and_constraints.md` | 选题定义与约束 |
| `02_sota_evidence_table.md` | 文献证据表 |
| `03_open_source_landscape.md` | 开源代码分析 |
| `04_innovation_hypotheses.md` | 创新假设 |
| `05_feasibility_matrix.md` | 可行性矩阵 |
| `06_experiment_plan.md` | 实验设计 |
| `07_implementation_log.md` | 实现日志 |
| `08_debug_log.md` | 调试日志 |
| `09_experiment_results.md` | 实验结果表 |
| `10_iteration_decisions.md` | 迭代决策 |
| `11_theoretical_analysis.md` | 理论分析 |
| `12_paper_draft.md` | 论文草稿 |
| `13_truthfulness_report.md` | 真实性检验报告 |
| `14_review_report.md` | 同行评审报告 |
| `15_revision_plan.md` | 修订计划 |
| `paper/<会议>/` | LaTeX 投稿包（`main.tex`, `references.bib`, 编译脚本等） |
| `state.json` | 流程状态与指标 |
| `blocker_log.jsonl` | 阻塞事件日志 |

### LaTeX 投稿包

投稿包包含以下文件，位于 `paper/<会议>/` 目录：

- `main.tex` — 完整 LaTeX 主文档
- `references.bib` — 所有参考文献的 BibTeX 条目
- `build.ps1` / `build.sh` — 一键编译脚本
- `Makefile` — 标准 Make 构建
- `submission_checklist.md` — 投稿就绪检查清单（记录编译状态、页数处理、待补资源等）

## 环境配置

### Python 环境

- **复用现有环境**：默认使用已激活的 Python/conda 环境，不会自动创建新环境
- **允许安装缺失包**：当前环境中缺失的包会自动安装
- **Windows OMP 冲突**：设置 `$env:KMP_DUPLICATE_LIB_OK='TRUE'` 解决 `libiomp5md.dll` 冲突

### GPU 支持

- 推荐使用有 CUDA 支持的 conda 环境（如 `talent311`）
- 实验脚本支持 `--device cuda` 参数切换 GPU

## 常见问题

### 实验一直失败怎么办？

检查 `08_debug_log.md` 和 `blocker_log.jsonl` 了解失败原因。通常是环境配置或数据下载问题。流程会自动重试（指数退避），超过最大重试次数后会记录阻塞并继续下一阶段。

### 论文草稿质量不够？

优先补齐 `02_sota_evidence_table.md`（文献证据）和 `09_experiment_results.md`（实验结果），然后让 `WRITING_AGENT` 重新撰写。真实性检验会自动发现宣称与结果不一致的地方。

### 审稿分数一直上不去？

检查 `14_review_report.md` 中的具体批评意见。可以：
1. 提高 `revision_convergence_threshold` 降低收敛门槛
2. 降低 `revision_patience` 提前强制退出
3. 检查创新设计和实验是否真正理解了评审意见

### 如何中断后续跑？

使用 `/iterative-rnd-oneclick` 并指定 `Run directory`，流程会读取 `state.json` 跳过已完成阶段，从中断处继续。

### LaTeX 编译失败？

检查 `paper/<会议>/submission_checklist.md` 中的编译状态。通常是引用缺失或特殊字符未转义。`TEX_WRITER` 会记录所有未解决问题和待办事项。

## 高级配置

### 任务文件参数

在 `research_runs/<主题>/task.json` 中可以配置：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `success_metric` | 无 | 实验成功标准（如 `"AUROC >= 0.90"`） |
| `min_delta` | 0.01 | 指标提升最小阈值 |
| `patience` | 2-3 | 连续无进展容忍轮数 |
| `enable_revision_loop` | true | 启用修订循环 |
| `revision_patience` | 3 | 最大修订轮数 |
| `expectation_patience` | 2 | 结果预期检验最大重试轮数 |
| `truthfulness_patience` | 2 | 真实性检验最大重试轮数 |
| `strict_exec` | true | 严格执行模式（缺失产物直接报错） |

### 科学严谨性要求

| 维度 | 最低要求 | 推荐标准 |
|------|----------|----------|
| 数据集 | ≥2（至少 1 个公开基准） | 3+ 多样化数据集 |
| 基线方法 | ≥3（至少 1 个近期 SOTA） | 5+ 含朴素与集成方法 |
| 随机种子 | ≥3 | 5 |
| 指标报告 | 所有任务主要指标 | 主要 + 次要 + 效率指标 |
| 消融实验 | ≥1 个组件移除 | 完整消融表 |
| 统计报告 | mean ± std + 显著性检验 |

## 文件结构

```
.github/
  agents/          # Agent 定义文件
  prompts/         # 一键启动 Prompt
  skills/          # 科研流程 Skill 定义
  instructions/    # 研究质量规范
RND_USAGE_GUIDE.md # 详细使用指南
research_runs/     # 所有运行产物按主题组织
```

## 更多文档

- [详细使用指南](RND_USAGE_GUIDE.md) — 参数说明、故障诊断、 Never-Stop 机制等
- [科研流程 Skill](.github/skills/scientific-research-pipeline/SKILL.md) — 完整的 Pipeline 架构与门控定义
- [执行门控参考](.github/skills/scientific-research-pipeline/references/execution-gates.md) — 门控检查清单
- [Agent 委派参考](.github/skills/scientific-research-pipeline/references/agent-delegation.md) — 各 Agent 输入输出规范

## 注意事项

- **禁止虚构**：所有引用、数据、结果必须有可追溯来源
- **区分事实与推测**：不确定的内容必须明确标注
- **版本控制**：所有草稿和评审报告自动版本化，不会覆盖历史文件
- **Never-Stop 机制**：任何单点故障不会终止整个流程，会自动写入占位并继续

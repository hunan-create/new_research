---
name: scientific-research-pipeline
description: "**WORKFLOW SKILL** — End-to-end scientific research lifecycle: topic → literature → innovation → experiment → paper → review → revision. Use when: 科研全流程, 从选题到投稿, 自动科研, research pipeline, run experiments, write paper, 文献检索, 创新点设计, 实验迭代, 论文撰写, 审稿修改, 补跑实验, 迭代更新, 降AI率, LaTeX排版. Covers: literature retrieval, SOTA analysis, innovation hypothesis, experiment execution, paper drafting, peer review simulation, revision loop, LaTeX conversion, and AI-detection reduction."
argument-hint: "Input: research topic (required), optional method description, target venue, compute budget, year range, language."
---

# Scientific Research Pipeline

Multi-agent orchestrated research workflow from topic input to submission-ready paper.

## When to Use

- Start a new research project from a topic
- Resume or iterate on an existing research project
- Fill experiment gaps, update paper, re-review
- Convert a finished draft to LaTeX
- Reduce AI detection score of a paper

## Quick Start

### New Project (Full Lifecycle)

Type in chat:
```
/rnd-autopilot-oneclick
Topic: <your topic>
Method description: <optional method sketch>
```

Or invoke `RND_AUTOPILOT` agent directly with topic and constraints.

### Iterate on Existing Project

Invoke `ITERATIVE_RND` agent with:
- Run directory path
- Mode: `audit` | `experiment` | `paper` | `review` | `revision` | `full`
- Specific instructions

### Single-Phase Operations

| Task | Agent | Trigger |
|------|-------|---------|
| Literature search & evidence table | `PAPER_SCOUT` | 搜索论文, SOTA summary |
| Open-source code analysis | `CODE_SCOUT` | 分析开源代码, baseline repo |
| Innovation hypothesis design | `INNOVATION_DESIGNER` | 构造创新点, novelty design |
| Experiment implementation & runs | `EXPERIMENT_ENGINEER` | 设计实验, 运行实验 |
| Paper drafting | `WRITING_AGENT` | 撰写论文, paper draft |
| Peer review simulation | `REVIEWER_AGENT` | 论文评审, 审稿意见 |
| LaTeX conversion | `TEX_WRITER` | 生成LaTeX, md转latex |
| AI detection reduction | `HUMANIZER` | 降低AI率, humanize paper |
| Topic paper retrieval | `TOPIC_INIT` | 检索论文, 拉取文献 |

## Pipeline Architecture

```
┌─────────────┐
│ TOPIC_INIT  │──→ Paper retrieval & screening
└──────┬──────┘
       ▼
┌─────────────┐
│ PAPER_SCOUT │──→ Evidence table + SOTA summary
└──────┬──────┘
       ▼
┌─────────────┐
│ CODE_SCOUT  │──→ Open-source landscape + reproducibility
└──────┬──────┘
       ▼
┌──────────────────┐
│INNOVATION_DESIGNER│──→ Hypotheses + feasibility matrix
└──────┬───────────┘
       ▼
┌─────────────────────┐
│ EXPERIMENT_ENGINEER │──→ Implementation → debug → run → iterate
└──────┬──────────────┘
       ▼
┌──────────────────────────────────────────┐
│   RESULT EXPECTATION GATE (NEW)          │
│   Compare best metric vs success_metric  │
│   Unmet? → loop back to INNOVATION +     │
│            EXPERIMENT (max patience rds)  │
│   Met? → proceed to writing              │
└──────┬───────────────────────────────────┘
       ▼
┌───────────────┐
│ WRITING_AGENT │──→ Paper draft (all sections)
└──────┬────────┘
       ▼
┌──────────────────────────────────────────┐
│   TRUTHFULNESS VERIFICATION (NEW)        │
│   Cross-check claims vs code & results   │
│   Mismatch? → rewrite draft (max rounds) │
│   Pass? → proceed to review              │
└──────┬───────────────────────────────────┘
       ▼
┌────────────────┐
│ REVIEWER_AGENT │──→ Review report + revision plan
└──────┬─────────┘
       ▼
  ┌─────────────────────────────────────────┐
  │         REVISION LOOP (closed)          │
  │  review → adjust → re-run → rewrite →  │
  │  re-review → check convergence          │
  └─────────────────────────────────────────┘
       ▼
┌────────────┐     ┌────────────┐
│ TEX_WRITER │     │ HUMANIZER  │
│ (LaTeX)    │     │ (降AI率)   │
└────────────┘     └────────────┘
```

Orchestrators:
- **RND_AUTOPILOT**: Full lifecycle from scratch
- **ITERATIVE_RND**: Incremental iteration on existing projects

## Run Directory Structure

All artifacts are saved under `research_runs/<topic_slug>/<run_id>/`:

| File | Content |
|------|---------|
| `01_topic_and_constraints.md` | Topic definition, constraints, proposed method |
| `02_sota_evidence_table.md` | Literature evidence table |
| `03_open_source_landscape.md` | Code repository analysis |
| `04_innovation_hypotheses.md` | Novelty claims and hypotheses |
| `05_feasibility_matrix.md` | Risk and feasibility assessment |
| `06_experiment_plan.md` | Experiment design matrix |
| `07_implementation_log.md` | Code changes and file log |
| `08_debug_log.md` | Errors, root causes, fixes |
| `09_experiment_results.md` | Result tables (mean ± std) |
| `10_iteration_decisions.md` | Keep / pivot / stop rationale |
| `11_paper_draft.md` | Manuscript draft |
| `12_review_report.md` | Simulated peer review |
| `13_revision_plan.md` | Prioritized revision checklist |
| `14_truthfulness_report.md` | Paper truthfulness verification report |
| `state.json` | Pipeline state and metrics |
| `blocker_log.jsonl` | Blocker events and revision log |
| `experiments/` | All experiment scripts |

## Scientific Rigor Requirements

These are non-negotiable standards enforced at experiment phase gates:

| Dimension | Minimum | Preferred |
|-----------|---------|-----------|
| Datasets | ≥2 (at least 1 public benchmark) | 3+ diverse |
| Baselines | ≥3 (at least 1 recent SOTA) | 5+ including naive & ensemble |
| Seeds | ≥3 | 5 |
| Metrics | All task-primary | Primary + secondary + efficiency |
| Ablation | ≥1 component removal | Full ablation table |
| Reporting | mean ± std | mean ± std + significance |

**Hard rules**:
- A single synthetic toy dataset alone is NEVER sufficient
- All result cells must show mean ± std, not single-run numbers
- Baselines must come from the evidence table
- Evaluation must cover multiple angles (accuracy, robustness, efficiency, generalization)

## Execution Gates

The pipeline enforces sequential gates before proceeding:

1. **Artifact Gate** — experiment scripts, configs, and runnable commands exist
2. **Run Gate** — at least one smoke experiment executed successfully
3. **Result Gate** — parseable metric line and complete result table written
4. **Rigor Gate** — ≥2 datasets, ≥3 baselines, mean ± std, ablation present
5. **Result Expectation Gate** — best metric compared against success_metric; unmet triggers innovation+experiment loop
5. **Writing Gate** — results sections reference actual data; gaps marked with `[RESULTS INCOMPLETE]`
6. **Truthfulness Gate** — paper claims cross-checked against code and results; mismatches trigger rewrite before review
7. **Review Gate** — review report contains `## Overall Score: <number>/100`
8. **Revision Gate** — `state.json` has `revision_round`, `blocker_log.jsonl` has stop reason

## Revision Loop

The revision loop runs automatically after the first review:

```
review → identify top issues → fix (experiment/writing/positioning)
  → update paper draft (new version) → re-review → check convergence
```

**Stop conditions** (any one triggers stop):
1. Score ≥ `revision_score_threshold` (default: 75/100)
2. Reached `revision_patience_max_rounds` (default: 5)
3. Strict blocker with actionable remediation

## Iteration Modes (ITERATIVE_RND)

| Mode | Description |
|------|-------------|
| `audit` | Scan artifacts, produce gap analysis |
| `experiment` | Fill specific experiment gaps |
| `paper` | Update draft with new results |
| `review` | Run fresh review on updated draft |
| `revision` | Full cycle: review → fix → rewrite → re-review |
| `full` | All above in sequence |

## Environment Policy

- **Reuse** the existing activated Python/conda environment (default: `icet`)
- **Never** auto-create new environments (`conda create`, `python -m venv`)
- **Allowed**: install missing packages in current environment
- **Windows**: set `KMP_DUPLICATE_LIB_OK=TRUE` to avoid OMP conflicts

## Common Recipes

### Recipe 1: Full Pipeline from Topic
```
@RND_AUTOPILOT Topic: <topic>, strict_exec=true, enable_revision_loop=true
```

### Recipe 2: Audit Current Project State
```
@ITERATIVE_RND run_dir=research_runs/<slug>/<run_id>, mode=audit
```

### Recipe 3: Fill Experiment Gaps
```
@ITERATIVE_RND run_dir=<path>, mode=experiment
Instructions: add baseline X on dataset Y with seeds 11 22 33
```

### Recipe 4: Update Paper with New Results
```
@ITERATIVE_RND run_dir=<path>, mode=paper
Instructions: incorporate new ablation results into Table 3
```

### Recipe 5: Full Iteration Cycle
```
@ITERATIVE_RND run_dir=<path>, mode=full
```

### Recipe 6: Convert to LaTeX
```
@TEX_WRITER draft=<path>/paper_draft_v19.md, venue=AAAI
```

### Recipe 7: Reduce AI Detection
```
@HUMANIZER draft=<path>/paper_draft_v19.md, target_rate=15%
```

### Recipe 8: Literature Only
```
@PAPER_SCOUT topic=<topic>, year_range=2022-2026
```

## Key Principles

1. **Evidence first** — no claim without traceable source
2. **No fabrication** — never invent citations, data, or results
3. **Reproducibility** — log all commands, seeds, configs
4. **Never stop silently** — always produce output and log blockers
5. **Never overwrite** — use versioned files for drafts and reviews
6. **Incremental** — never redo completed work; build on existing artifacts
7. **Quality over speed** — rigor gates cannot be bypassed

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Agent returns empty output | Check `blocker_log.jsonl`; re-run with `strict_exec=true` |
| Experiment OOM | Reduce batch size or switch to CPU; log in `07_implementation_log.md` |
| Cannot download dataset | Substitute with sklearn/openml benchmark; document substitution |
| Review score not improving | Run `audit` mode to identify structural issues |
| Missing baseline | Check `02_sota_evidence_table.md`; expand with `PAPER_SCOUT` |
| `state.json` corrupted | Manually inspect and fix; check versioned backups |
| OMP Error #15 on Windows | Set `$env:KMP_DUPLICATE_LIB_OK='TRUE'` before running |

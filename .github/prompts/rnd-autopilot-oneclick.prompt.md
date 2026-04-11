---
description: "One-click full R&D pipeline run. Use when: you provide a topic and want automatic literature, code analysis, innovation design, experiments, paper drafting, review, revision plan, and a submission-ready `.tex` package."
---
Run RND_AUTOPILOT in one-command mode.

Input:
- Topic: {{topic}}

Optional overrides:
- Method description: {{method_description}}
- Year range: {{year_range}}
- Language: {{language}}
- Preferred sources: {{sources}}
- Target venue/task: {{target_venue}}
- Compute budget: {{budget}}
- Deadline: {{deadline}}
- Baseline repositories: {{repos}}
- Strict execution: {{strict_exec}}
- Enable revision loop: {{enable_revision_loop}}
- Revision patience: {{revision_patience}}
- Revision convergence threshold: {{revision_convergence_threshold}}
- Revision score threshold: {{revision_score_threshold}}
- Revision max rounds: {{revision_patience_max_rounds}}
- Expectation patience: {{expectation_patience}}
- Truthfulness patience: {{truthfulness_patience}}

Execution rules:
1. If optional overrides are empty, use RND_AUTOPILOT defaults.
1.1 If `method_description` is provided, treat it as the user's proposed method sketch. Pass it verbatim to INNOVATION_DESIGNER (to anchor hypothesis generation around the described method instead of designing from scratch) and to EXPERIMENT_ENGINEER (to guide implementation). Write it into `01_topic_and_constraints.md` under a `## Proposed Method` section.
2. Execute full lifecycle phases: retrieval -> code intelligence -> innovation -> experiment -> writing -> review -> revision -> tex packaging.
3. Auto-save outputs under `research_runs/<topic_slug>/<run_id>/` using required filenames in the agent spec.
3.1 Path policy: all delegated-agent deliverables must remain under `research_runs/`; do not write final artifacts to any other top-level output folder.
4. No fabricated citations or unverifiable claims.
5. If experiments fail, produce debug log and pivot options instead of stopping silently.
6. In experiment phase, you MUST produce executable artifacts when missing (scripts/configs/minimal data pipeline), then run setup/experiment/eval commands end-to-end.
6.1 Environment policy: reuse the existing activated Python environment by default. Do not create a new conda/venv environment unless the user explicitly requests it. Installing missing packages is allowed.
7. Do not stop at planning: run at least one smoke experiment and write a parseable metric line in `09_experiment_results.md` as `## Best Metric: <number>`; only use `0.0000` sentinel if all retries fail.
8. Prefer unattended execution: avoid human confirmation checkpoints unless safety/privacy constraints require explicit approval.
9. Default to strict execution (`strict_exec=true`): if required executable code/data/commands are missing, surface blocker and stop instead of silently completing with stubs.
10. Enforce this order in experiment phase: create missing runnable artifacts -> run setup/smoke/eval commands -> write parseable metric -> then continue.
11. In final response, explicitly list `created_or_modified_code_files` and `executed_commands` before reporting metrics.
12. **Closed-loop revision is mandatory in one-click mode**:
    - Default `enable_revision_loop=true` unless user explicitly disables it.
    - Execute the revision loop directly via agent delegation: review -> adjust design -> re-implement/re-run -> rewrite -> re-review.
    - Do not mark revision as done without loop evidence in artifacts.
13. **Revision evidence requirements** (must be machine-checkable):
    - `state.json` must contain `revision_round` (integer >= 1 when loop enabled).
    - `blocker_log.jsonl` must contain at least one `revision-iteration` event describing either convergence or patience stop.
    - `14_review_report.md` must contain parseable scorecard line `## Overall Score: <number>/100`.
14. **Revision completion gate**:
    - Allowed stop conditions are only:
      1) score >= `revision_score_threshold`, or
      2) reached `revision_patience_max_rounds`, or
      3) explicit strict blocker with actionable remediation.
    - If none of the above is met, continue revision loop and do not finalize run.
15. **Scientific rigor is mandatory** — "minimum viable" is NOT acceptable:
    - **Datasets**: evaluate on ≥2 datasets; at least one must be a publicly available benchmark (not a custom synthetic toy). If you cannot download a dataset, explain why and substitute a recognized standard synthetic benchmark (e.g., `sklearn.datasets.make_classification` with documented parameters, or an `openml` dataset).
    - **Baselines**: include ≥3 competitive baselines from the evidence table; at least one must be a method published within the last 3 years. Include a naive baseline (random/majority/linear) AND at least one strong ML/DL method.
    - **Statistics**: run ≥3 seeds; report mean ± std for every result cell. Single-run numbers are not acceptable.
    - **Ablation**: include at least one ablation study removing a key proposed component.
    - **Multi-metric**: report all task-relevant primary metrics (e.g., AUROC + AUPRC + F1 for classification; not just accuracy).
    - **If the rigor gate in RND_AUTOPILOT fails** (not enough baselines, single dataset, no ablation), do NOT proceed to WRITING_AGENT — request EXPERIMENT_ENGINEER to fill the gaps first.
16. When paper draft is written, ensure the experiments section follows: setup -> main results table (mean +- std) -> ablation table -> analysis subsection (efficiency/robustness/generalization as applicable).
17. **Result expectation gate** (after experiment rigor gate, before writing):
    - Compare the best metric from `09_experiment_results.md` against the `success_metric` from the task file.
    - If unmet: log gap to `10_iteration_decisions.md`, log `result-expectation-mismatch` to `blocker_log.jsonl`, and loop back through INNOVATION_DESIGNER → EXPERIMENT_ENGINEER (up to `expectation_patience` rounds, default 2).
    - If still unmet after patience: proceed to writing with explicit `[EXPECTATION UNMET]` marker.
18. **Truthfulness verification** (after writing, before review):
    - Cross-check paper claims (numbers, method descriptions, contribution statements) against `09_experiment_results.md`, `07_implementation_log.md`, and experiment code.
    - If mismatches found: produce `13_truthfulness_report.md`, route back to WRITING_AGENT to fix the draft (up to `truthfulness_patience` rounds, default 2).
    - Only proceed to REVIEWER_AGENT after truthfulness passes or max rounds exhausted (attaching report).
19. After revision converges, invoke TEX_WRITER using `target_venue` if provided; otherwise use `generic` fallback. The run is not complete until `paper/<venue>/main.tex`, `references.bib`, and `submission_checklist.md` exist.
20. Treat anonymous submission as the default for LaTeX packaging unless the user explicitly asks for camera-ready output.

Final chat response must include:
- selected defaults or overrides
- key output file paths
- LaTeX package path and build/compliance summary
- best current method and metrics (or blocker summary)
- top 3 risks and next validation actions
- revision loop evidence summary (`revision_round`, stop condition, score trajectory)
- result expectation gate outcome (met / unmet after N rounds / skipped)
- truthfulness verification outcome (passed / corrected in N rounds / attached report)

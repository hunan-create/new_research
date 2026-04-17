# Execution Gates & Quality Checklist

## Gate Sequence (Must Pass in Order)

### Gate 1: Artifact Gate
- [ ] Experiment scripts exist in `experiments/`
- [ ] Dependency file exists (requirements.txt or environment.yml)
- [ ] Config/schema documented
- [ ] At least one runnable command defined
- [ ] Scripts cover: data loading, each baseline, proposed method, ablation, metric aggregation

### Gate 2: Run Gate
- [ ] Setup command executed successfully
- [ ] At least one smoke experiment completed
- [ ] Full matrix run: all seeds × all datasets × all methods

### Gate 3: Result Gate
- [ ] `09_experiment_results.md` contains `## Best Metric: <number>`
- [ ] Complete result table: rows=methods, columns=datasets, cells=mean±std
- [ ] `state.json` updated with phase status and best metric

### Gate 4: Rigor Gate
- [ ] ≥2 distinct datasets evaluated (at least 1 public benchmark)
- [ ] ≥3 distinct baselines in result table
- [ ] All result cells show mean ± std (not single seed)
- [ ] At least one ablation row exists
- [ ] If any fails → `rigor_incomplete`, do NOT proceed to writing

### Gate 5: Theoretical Analysis Gate
- [ ] `11_theoretical_analysis.md` exists and is non-empty
- [ ] Part I present: formal problem definition + theoretical foundations + principle-to-design mapping table
- [ ] Part II present: computational complexity analysis with baseline comparison table
- [ ] Part III present: theory-experiment bridge table cross-referencing `09_experiment_results.md`
- [ ] Conditional sections either included or skipped with justification
- [ ] `state.json` updated with `phase_status.theoretical_analysis`

### Gate 6: Writing Gate
- [ ] All experiment results reflected in paper draft
- [ ] Every quantitative claim references a specific table cell
- [ ] Experiments section follows required structure
- [ ] `[RESULTS INCOMPLETE]` placeholders for any gaps

### Gate 7: Review Gate
- [ ] `14_review_report.md` contains `## Overall Score: <number>/100`
- [ ] Both strict and moderate reviewer perspectives included
- [ ] Logical consistency audit performed

### Gate 8: Revision Gate
- [ ] `state.json` contains `revision_round` ≥ 1
- [ ] `blocker_log.jsonl` contains `revision-iteration` stop event
- [ ] `15_revision_plan.md` references latest review concerns
- [ ] Stop condition documented (score threshold / patience / blocker)

### Gate 9: LaTeX Submission Gate
- [ ] Latest approved draft has been converted by `TEX_WRITER`
- [ ] `paper/<venue>/main.tex` exists and is non-empty
- [ ] `paper/<venue>/references.bib` exists and covers all citations used in the draft
- [ ] `paper/<venue>/build.ps1` or `build.sh` exists for reproducible compilation
- [ ] `paper/<venue>/submission_checklist.md` records venue, source draft, build status, and unresolved issues
- [ ] `state.json` updated with `phase_status.latex`

## Rigor Enforcement Matrix

| Check | Fail Action |
|-------|-------------|
| Single dataset only | Block writing; request EXPERIMENT_ENGINEER to add dataset |
| <3 baselines | Block writing; expand from evidence table |
| No mean±std | Block writing; re-run with ≥3 seeds |
| No ablation | Block writing; design ablation experiment |
| <5 papers in evidence | Request PAPER_SCOUT second pass |
| Innovation lacks baseline targets | Bounce to INNOVATION_DESIGNER |

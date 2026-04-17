---
description: "Iterate on an existing research project. Use when: you have an existing run directory with artifacts and want to fill experiment gaps, update the paper, re-run review, regenerate a submission-ready `.tex` package, or do a full iteration cycle — without restarting from scratch."
---
Run ITERATIVE_RND to iterate on an existing project.

Input:
- Run directory: {{run_dir}}
- Iteration mode: {{mode}}  (audit | experiment | theory | paper | review | tex | revision | full)
- Specific instructions: {{instructions}}

Optional overrides:
- Target experiments to fill: {{experiment_gaps}}
- Paper sections to update: {{paper_sections}}
- Review focus areas: {{review_focus}}
- Target venue: {{target_venue}}

Execution rules:
1. If `run_dir` is empty, auto-detect the latest run under `research_runs/`.
2. If `mode` is empty, default to `audit` (scan and report gaps).
3. Always read `state.json` and existing artifacts before taking any action.
4. Never redo work that already exists — build incrementally.
5. Never overwrite existing files — create versioned copies (e.g., `paper_draft_v13.md`).
6. Reuse existing Python/conda environment. Do not create new environments.
7. If `mode` is `tex`, or `mode` is `full`, generate or refresh the LaTeX submission package under `paper/<venue>/` using the explicit target venue or `generic` fallback.
8. After all actions, produce a structured iteration summary.

Quick usage examples:

### Audit the current project state
```
@ITERATIVE_RND
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Mode: audit
```

### Fill experiment gaps
```
@ITERATIVE_RND
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Mode: experiment
Instructions: 补跑 CausalICL cross-graph 实验 (D1-D9)
```

### Update theoretical analysis after new experiments
```
@ITERATIVE_RND
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Mode: theory
Instructions: 新实验结果已产出，更新理论-实验桥接部分
```

### Update paper with new results
```
@ITERATIVE_RND
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Mode: paper
Instructions: 把 summary_v15 的结果更新到论文 Tables 1-3c 中
```

### Generate submission-ready LaTeX
```
@ITERATIVE_RND
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Mode: tex
Target venue: AAAI
```

### Full iteration cycle
```
@ITERATIVE_RND
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Mode: full
```

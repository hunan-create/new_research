---
description: "Reduce AI-detection score in a paper draft while preserving all scientific content. Use when: you have a completed paper and want to lower its AI-detection probability."
---
Run HUMANIZER to rewrite a paper draft for lower AI-detection scores.

Input:
- Paper draft: {{draft}}  (path to .md or .tex file)
- Run directory: {{run_dir}}  (optional — auto-detects if empty)
- Target AI rate: {{target_rate}}  (default: <15%)
- Focus sections: {{sections}}  (default: all; or specify: abstract, intro, related_work, conclusion)

Execution rules:
1. If `draft` is empty, find the highest-version `paper_draft_v*.md` in the run directory.
2. Read the entire draft and assess per-section AI-detection risk.
3. Rewrite high-risk sections first (intro, related work, conclusion), then medium-risk.
4. Preserve all experimental numbers, equations, tables, and citations exactly.
5. Output the rewritten draft as `<filename>_humanized.md` (or `.tex`) in the same directory.
6. Produce a `humanization_report.md` summarizing changes and estimated risk reduction.

Quick usage examples:

### Humanize the latest paper draft
```
@HUMANIZER
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
```

### Humanize a specific file with target rate
```
@HUMANIZER
Paper draft: research_runs/tabular-foundation-multimodal-causal/20260331_run01/paper_draft_v17.md
Target AI rate: <10%
```

### Humanize only specific sections
```
@HUMANIZER
Paper draft: research_runs/tabular-foundation-multimodal-causal/20260331_run01/paper_draft_v17.md
Focus sections: abstract, intro, conclusion
```

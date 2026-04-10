---
description: "Convert the latest markdown paper draft into a publication-ready LaTeX manuscript. Use when: you have a completed .md paper draft and need a .tex version for submission to an academic venue."
---
Run TEX_WRITER to convert a markdown paper draft to LaTeX.

Input:
- Run directory: {{run_dir}}
- Target venue: {{venue}}  (AAAI | NeurIPS | ICML | ICLR | ACL | generic)
- Paper draft: {{draft}}  (auto-detects latest if empty)

Optional overrides:
- Anonymous: {{anonymous}}  (default: true for submission)
- Include supplementary: {{supplementary}}  (default: auto — split if exceeds page limit)
- Style file path: {{style_file}}  (custom venue .sty if available)

Execution rules:
1. If `run_dir` is empty, auto-detect the latest run under `research_runs/`.
2. If `draft` is empty, find the highest-version `paper_draft_v*.md` in the run directory.
3. Read the entire draft, convert to LaTeX with venue-specific formatting.
4. Generate `references.bib` from all cited works.
5. Output all files to `<run_dir>/paper/<venue>/`.
6. Run compilation check if pdflatex is available.
7. Report any issues (missing figures, undefined references, page count).

Quick usage examples:

### Generate AAAI submission
```
@TEX_WRITER
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Venue: AAAI
```

### Generate NeurIPS submission from specific draft
```
@TEX_WRITER
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Venue: NeurIPS
Draft: paper_draft_v16.md
```

### Generate generic LaTeX (no venue restriction)
```
@TEX_WRITER
Run directory: research_runs/tabular-foundation-multimodal-causal/20260331_run01
Venue: generic
```

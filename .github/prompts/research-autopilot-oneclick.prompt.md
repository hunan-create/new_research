---
description: "One-click research-only run with fixed output files. Use when: you provide a topic and want literature retrieval + evidence + review outputs. For coding/experiments/paper revision, use rnd-autopilot-oneclick."
---
Run RESEARCH_AUTOPILOT in one-command mode.

Input:
- Topic: {{topic}}

Optional overrides:
- Year range: {{year_range}}
- Language: {{language}}
- Preferred sources: {{sources}}

Execution rules:
1. If optional overrides are empty, use one-command defaults from RESEARCH_AUTOPILOT.
2. Complete the full pipeline: scope, retrieval, screening, evidence extraction, synthesis, next-step plan.
3. Auto-save results with fixed filenames under `research_runs/<topic_slug>/research_autopilot/`.
4. Do not fabricate references. Mark unknowns explicitly.

Final chat response must include:
- selected defaults or overrides
- output file paths
- top risks and what to verify next

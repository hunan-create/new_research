# Agent Delegation Reference

Detailed instructions for delegating work to each specialized agent.

## PAPER_SCOUT — Literature Retrieval

**Input**: topic, year range, sources, inclusion/exclusion criteria, language  
**Output**: `02_sota_evidence_table.md`

Procedure:
1. Decompose topic into 3-6 keyword clusters
2. Search ArXiv, Semantic Scholar, Google Scholar
3. Retrieve and verify metadata (no fabrication)
4. Build evidence table: method | setting | key result | limitation | link
5. Identify SOTA and unresolved gaps
6. Ensure ≥15 papers retrieved; if <5, run second pass with broadened queries

## CODE_SCOUT — Open-Source Analysis

**Input**: topic, repository list (GitHub links), framework, compute constraints  
**Output**: `03_open_source_landscape.md`

Procedure:
1. Map repository structure and dependencies
2. Assess reproducibility (README, requirements, tests)
3. Identify extension points for proposed method
4. Estimate reproduction cost (time, compute)

## INNOVATION_DESIGNER — Hypothesis Design

**Input**: topic, SOTA evidence, baseline methods, constraints, success metric  
**Output**: `04_innovation_hypotheses.md`, `05_feasibility_matrix.md`

Procedure:
1. Analyze gaps from evidence table
2. Generate 3-5 innovation hypotheses
3. Score each on novelty, feasibility, and expected impact
4. Produce feasibility matrix with risk assessment
5. If `method_description` provided, refine around that method

## EXPERIMENT_ENGINEER — Experiment Execution

**Input**: hypotheses, baseline code, datasets, metrics, compute budget  
**Output**: `06_experiment_plan.md`, `07_implementation_log.md`, `08_debug_log.md`, `09_experiment_results.md`

Procedure:
1. **Plan**: list ≥3 baselines and ≥2 datasets; define metrics and seed list
2. **Implement**: create scripts for data, baselines, proposed method, ablation
3. **Execute**: smoke test (1 seed, 1 dataset) → full matrix (all seeds × datasets × methods)
4. **Verify**: parse primary metric (mean ± std); write `## Best Metric: <number>`
5. **Report**: update implementation and debug logs

Environment rules:
- Reuse existing conda env (default: `icet`)
- Set `KMP_DUPLICATE_LIB_OK=TRUE` on Windows
- Never create new environments unless explicitly asked

## THEORETICAL_ANALYST — Theoretical Analysis (Principles → Design)

**Input**: topic and constraints, SOTA evidence, innovation hypotheses, feasibility matrix, implementation log, experiment results  
**Output**: `11_theoretical_analysis.md`

Procedure:
1. Read `01_topic_and_constraints.md`, `02_sota_evidence_table.md`, `04_innovation_hypotheses.md`, `05_feasibility_matrix.md`, `07_implementation_log.md`, `09_experiment_results.md`
2. **Part I — Principles to Design**:
   - Write formal problem definition with mathematical notation
   - Identify theoretical foundations the method builds upon (cite sources)
   - Map each design choice to its motivating theoretical principle (structured table)
   - Formalize the proposed method as an algorithm or optimization problem
3. **Part II — Formal Analysis**:
   - Computational complexity analysis (required): time/space, comparison table with baselines
   - Convergence analysis (conditional): if method involves iterative optimization
   - Error bounds (conditional): if method involves approximation or sampling
   - Generalization analysis (conditional): if method involves statistical learning
   - Identifiability (conditional): if method makes structural claims
4. **Part III — Theory-Experiment Bridge**:
   - For each theoretical result, state what it predicts about experiments
   - Cross-reference specific results in `09_experiment_results.md`
   - Present validation status in a structured table
5. Mark `phase_status.theoretical_analysis` in `state.json`

Quality rules:
- Every theorem must state assumptions before the claim
- Distinguish rigorous proofs from proof sketches (label explicitly)
- No fabricated theorems; mark conjectures as `[Conjecture]`
- Cross-reference experiment results after each theoretical result

## WRITING_AGENT — Paper Drafting

**Input**: evidence table, experiment results, theoretical analysis, contribution claims, target venue  
**Output**: `12_paper_draft.md`

Required experiments section structure:
1. Experimental setup (datasets, baselines, metrics, seeds, hardware)
2. Main results table (rows=methods, columns=datasets, cells=mean±std)
3. Ablation study table
4. Analysis subsection (efficiency/robustness/generalization)
5. Failure cases discussion

Completeness gate — do NOT write results if:
- <3 baselines → insert `[GAP: insufficient baselines]`
- <2 datasets → insert `[GAP: single dataset]`
- No mean±std → insert `[GAP: missing multi-seed statistics]`
- No ablation → insert `[GAP: ablation missing]`

## REVIEWER_AGENT — Peer Review

**Input**: paper draft, venue criteria, reviewer style (strict/balanced)  
**Output**: `14_review_report.md`, `15_revision_plan.md`

Review dimensions:
- Novelty, significance, technical soundness, clarity, logical consistency, reproducibility

Mandatory audits:
- Baseline sufficiency (≥3 competitive)
- Dataset diversity (≥2 distinct)
- Statistical reporting (mean±std)
- Ablation completeness
- Claim-evidence alignment
- Cross-section consistency
- Notation consistency


## TEX_WRITER — LaTeX Conversion

**Input**: latest .md paper draft, target venue, run directory  
**Output**: `paper/<venue>/main.tex`, `references.bib`, build scripts, figures, and `submission_checklist.md`

Procedure:
1. Resolve the latest approved markdown draft to convert
2. Apply the venue template, or `generic` fallback when the venue/style is unavailable
3. Build the submission package under `paper/<venue>/`
4. Run compilation check when the LaTeX toolchain is available
5. Write `submission_checklist.md` with build/compliance status and remaining TODOs

## HUMANIZER — AI Detection Reduction

**Input**: paper draft path, target AI-detection rate (default <15%), focus sections  
**Output**: rewritten paper with preserved scientific content

## ITERATIVE_RND — Incremental Iteration

**Input**: run directory, iteration mode, specific instructions  

Startup protocol (every invocation):
1. Locate project directory
2. Read `state.json` and all artifacts
3. Build and present project snapshot
4. Execute requested mode

Key rules:
- Never redo existing work
- Never overwrite — create new versions
- Track in `iteration_log.md` and `state.json`

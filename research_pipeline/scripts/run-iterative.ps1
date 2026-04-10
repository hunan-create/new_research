#Requires -Version 5.1
<#
.SYNOPSIS
    Iterative RND Pipeline - runs targeted iterations on an existing research project.

.DESCRIPTION
    Unlike run-pipeline.ps1 which runs a full lifecycle from scratch, this script:
    - Connects to an existing run directory with prior artifacts
    - Performs gap analysis (audit mode)
    - Executes only the phases/experiments that need updating
    - Supports targeted experiment, paper, review, and revision modes
    - Never overwrites existing files — creates versioned copies

.PARAMETER TaskFile
    Path to a JSON task file. Must include an "iteration" section.

.PARAMETER Mode
    Override iteration mode: audit, experiment, paper, review, revision, full.
    Takes precedence over the mode in TagFile.

.PARAMETER RunDir
    Override the run directory path. If omitted, auto-resolves latest run for topic_slug.

.PARAMETER AutoConfirm
    Skip manual confirmation prompts for agent phases.

.PARAMETER StrictExec
    Fail-fast on missing inputs/outputs or failed commands.

.EXAMPLE
    # Audit current project state
    powershell -ExecutionPolicy Bypass -File run-iterative.ps1 -TaskFile ..\tasks\my-task.json -Mode audit

    # Fill experiment gaps
    powershell -ExecutionPolicy Bypass -File run-iterative.ps1 -TaskFile ..\tasks\my-task.json -Mode experiment -AutoConfirm

    # Full iteration cycle
    powershell -ExecutionPolicy Bypass -File run-iterative.ps1 -TaskFile ..\tasks\my-task.json -Mode full
#>
param(
    [Parameter(Mandatory)][string]$TaskFile,
    [ValidateSet('audit','experiment','paper','review','revision','full')]
    [string]$Mode,
    [string]$RunDir,
    [switch]$AutoConfirm,
    [switch]$StrictExec,
    [int]$MaxRetries    = 3,
    [int]$RetryDelaySec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---- Bootstrap ---------------------------------------------------------------
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $ScriptDir 'lib\pipeline-helpers.ps1')

# ---- Load task file -----------------------------------------------------------
if (-not (Test-Path $TaskFile)) {
    Write-Host "[ERROR] Task file not found: $TaskFile" -ForegroundColor Red
    exit 1
}

try {
    $task = Read-JsonFile -Path $TaskFile -ThrowOnError
} catch {
    Write-Host "[ERROR] Failed to parse task file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---- Resolve iteration config -------------------------------------------------
$iterConfig = $task.iteration
$iterMode = if ($Mode) { $Mode }
             elseif ($iterConfig -and $iterConfig.mode) { $iterConfig.mode }
             else { 'audit' }

# ---- Resolve run directory ----------------------------------------------------
$rootDir = Split-Path (Split-Path $ScriptDir -Parent) -Parent
$runsBase = Join-Path $rootDir "research_runs\$($task.topic_slug)"

$runDir = if ($RunDir) { $RunDir }
          elseif ($iterConfig -and $iterConfig.run_dir) { $iterConfig.run_dir }
          else { $null }

if (-not $runDir -and (Test-Path $runsBase)) {
    $runDir = Get-ChildItem $runsBase -Directory |
              Sort-Object Name -Descending |
              Select-Object -First 1 -ExpandProperty FullName
}

if (-not $runDir -or -not (Test-Path $runDir)) {
    Write-Host "[ERROR] No run directory found for topic '$($task.topic_slug)'. Run the full pipeline first." -ForegroundColor Red
    exit 1
}

# ---- Load state ---------------------------------------------------------------
$statePath = Join-Path $runDir 'state.json'
$state = Read-PipelineState -RunDir $runDir
if (-not $state) {
    Write-Host "[ERROR] No valid state.json found in $runDir" -ForegroundColor Red
    exit 1
}

# ---- Banner --------------------------------------------------------------------
Write-Host "`n===== ITERATIVE RND PIPELINE =====" -ForegroundColor Magenta
Write-Host "Topic    : $($task.topic)"       -ForegroundColor White
Write-Host "Run dir  : $runDir"              -ForegroundColor White
Write-Host "Mode     : $iterMode"            -ForegroundColor Cyan
Write-Host "Metric   : $($state.best_metric)" -ForegroundColor White
Write-Host "Rev round: $($state.revision_round)" -ForegroundColor White
if ($StrictExec) { Write-Host "[MODE]   STRICT-EXEC" -ForegroundColor Yellow }
if ($AutoConfirm) { Write-Host "[MODE]   AUTO-CONFIRM" -ForegroundColor Yellow }

# ---- Audit Mode ---------------------------------------------------------------
function Invoke-AuditMode {
    param([string]$RunDir, [pscustomobject]$State, [pscustomobject]$Task)

    Write-Host "`n===== AUDIT MODE =====" -ForegroundColor Cyan

    $auditLines = [System.Collections.Generic.List[string]]::new()
    $auditLines.Add("# Iteration Audit Report`n")
    $auditLines.Add("**Generated**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n")
    $auditLines.Add("**Run directory**: $RunDir`n`n")

    # ---- Phase status summary ----
    $auditLines.Add("## 1. Phase Status`n`n")
    $auditLines.Add("| Phase | Status |`n|---|---|`n")
    if ($State.phase_status) {
        $State.phase_status.PSObject.Properties | ForEach-Object {
            $auditLines.Add("| $($_.Name) | $($_.Value) |`n")
        }
    }
    $auditLines.Add("`n")

    # ---- Artifact inventory ----
    $auditLines.Add("## 2. Artifact Inventory`n`n")

    # Core numbered files
    $coreFiles = @(
        '01_topic_and_constraints.md', '02_sota_evidence_table.md',
        '03_open_source_landscape.md', '04_innovation_hypotheses.md',
        '05_feasibility_matrix.md', '06_experiment_plan.md',
        '07_implementation_log.md', '08_debug_log.md',
        '09_experiment_results.md', '10_iteration_decisions.md',
        '11_paper_draft.md', '12_review_report.md', '13_revision_plan.md'
    )

    $auditLines.Add("### Core Files`n`n| File | Exists | Size |`n|---|---|---|`n")
    foreach ($f in $coreFiles) {
        $fp = Join-Path $RunDir $f
        if (Test-Path $fp) {
            $size = (Get-Item $fp).Length
            $auditLines.Add("| $f | ✅ | $size bytes |`n")
        } else {
            $auditLines.Add("| $f | ❌ | — |`n")
        }
    }
    $auditLines.Add("`n")

    # Paper draft versions
    $paperDrafts = Get-ChildItem $RunDir -Filter 'paper_draft_v*.md' -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending
    if ($paperDrafts.Count -gt 0) {
        $auditLines.Add("### Paper Draft Versions`n`n")
        foreach ($pd in $paperDrafts) {
            $auditLines.Add("- $($pd.Name) ($($pd.Length) bytes, modified $($pd.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))`n")
        }
        $auditLines.Add("`n")
    }

    # Review reports
    $reviews = Get-ChildItem $RunDir -Filter '*review_report*.md' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending
    if ($reviews.Count -gt 0) {
        $auditLines.Add("### Review Reports`n`n")
        foreach ($rv in $reviews) {
            $auditLines.Add("- $($rv.Name) ($($rv.Length) bytes)`n")
        }
        $auditLines.Add("`n")
    }

    # Result files
    $resultsDir = Join-Path $RunDir 'results'
    if (Test-Path $resultsDir) {
        $resultFiles = Get-ChildItem $resultsDir -Filter '*.json' -ErrorAction SilentlyContinue |
                       Sort-Object Name
        if ($resultFiles.Count -gt 0) {
            $auditLines.Add("### Result Files`n`n")
            foreach ($rf in $resultFiles) {
                $auditLines.Add("- results/$($rf.Name) ($($rf.Length) bytes)`n")
            }
            $auditLines.Add("`n")
        }
    }

    # Experiment scripts
    $experimentsDir = Join-Path $RunDir 'experiments'
    if (Test-Path $experimentsDir) {
        $scripts = Get-ChildItem $experimentsDir -Filter '*.py' -ErrorAction SilentlyContinue |
                   Sort-Object Name
        if ($scripts.Count -gt 0) {
            $auditLines.Add("### Experiment Scripts`n`n")
            foreach ($sc in $scripts) {
                $auditLines.Add("- experiments/$($sc.Name)`n")
            }
            $auditLines.Add("`n")
        }
    }

    # ---- Metrics summary ----
    $auditLines.Add("## 3. Metrics Summary`n`n")
    $auditLines.Add("- **Best metric**: $($State.best_metric)`n")
    $auditLines.Add("- **Iteration rounds**: $($State.iter_round)`n")
    $auditLines.Add("- **Revision rounds**: $($State.revision_round)`n")
    if ($State.revision_score_trajectory) {
        $auditLines.Add("- **Score trajectory**: $($State.revision_score_trajectory -join ' → ')`n")
    }
    $auditLines.Add("`n")

    # ---- Existing audit files ----
    $existingAudit = Join-Path $RunDir 'experiment_audit.md'
    if (Test-Path $existingAudit) {
        $auditLines.Add("## 4. Existing Experiment Audit`n`n")
        $auditLines.Add("An `experiment_audit.md` file already exists in this run directory.`n")
        $auditLines.Add("Refer to it for detailed method × dataset coverage matrices.`n`n")
    }

    # ---- Blocker log summary ----
    $blockerLog = Join-Path $RunDir 'blocker_log.jsonl'
    if (Test-Path $blockerLog) {
        $blockers = Get-Content $blockerLog -Encoding UTF8
        $auditLines.Add("## 5. Blocker Log Summary`n`n")
        $auditLines.Add("Total entries: $($blockers.Count)`n`n")

        # Show last 5 entries
        $recent = $blockers | Select-Object -Last 5
        $auditLines.Add("### Last 5 Entries`n`n")
        foreach ($b in $recent) {
            $auditLines.Add("- ``$b```n")
        }
        $auditLines.Add("`n")
    }

    # ---- Suggested next actions ----
    $auditLines.Add("## 6. Suggested Next Actions`n`n")
    $auditLines.Add("Based on the current state, consider:`n`n")
    $auditLines.Add("1. Run ``@ITERATIVE_RND`` with ``mode: experiment`` to fill any experiment gaps`n")
    $auditLines.Add("2. Run ``@ITERATIVE_RND`` with ``mode: paper`` to update the paper with latest results`n")
    $auditLines.Add("3. Run ``@ITERATIVE_RND`` with ``mode: review`` to get a fresh review`n")
    $auditLines.Add("4. Run ``@ITERATIVE_RND`` with ``mode: full`` for a complete iteration cycle`n`n")

    # ---- Write audit file ----
    $auditPath = Join-Path $RunDir 'iteration_audit.md'
    ($auditLines -join '') | Set-Content $auditPath -Encoding UTF8
    Write-Host "  [OK] Audit written to: iteration_audit.md" -ForegroundColor Green
    return $auditPath
}

# ---- Experiment Mode ----------------------------------------------------------
function Invoke-IterativeExperimentMode {
    param([string]$RunDir, [pscustomobject]$State, [pscustomobject]$Task)

    Write-Host "`n===== EXPERIMENT MODE =====" -ForegroundColor Cyan

    # Check for experiment gaps spec
    $gaps = @()
    if ($Task.iteration -and $Task.iteration.experiment_gaps) {
        $gaps = @($Task.iteration.experiment_gaps)
    }

    if ($gaps.Count -eq 0) {
        Write-Host "  [INFO] No specific experiment gaps specified in task file." -ForegroundColor Yellow
        Write-Host "  [ACTION] Open Copilot Chat and run: @ITERATIVE_RND" -ForegroundColor White
        Write-Host "  [INPUT]  Describe the experiments to fill, e.g.:" -ForegroundColor White
        Write-Host "           '补跑 CausalICL cross-graph D1-D9'" -ForegroundColor Gray
    } else {
        Write-Host "  Experiment gaps to fill:" -ForegroundColor White
        foreach ($g in $gaps) {
            Write-Host "    - $g" -ForegroundColor White
        }
    }

    if (-not $AutoConfirm) {
        Write-Host "`n  Press [Enter] when experiments are complete, or type 'skip': " -NoNewline
        $answer = Read-Host
        if ($answer.Trim().ToLower() -eq 'skip') { return 'skipped' }
    } else {
        Write-Host "  [AUTO] Delegating to EXPERIMENT_ENGINEER via Copilot Chat." -ForegroundColor Gray
    }

    Write-Host "  [OK] Experiment mode complete." -ForegroundColor Green
    return 'done'
}

# ---- Paper Mode ---------------------------------------------------------------
function Invoke-IterativePaperMode {
    param([string]$RunDir, [pscustomobject]$State, [pscustomobject]$Task)

    Write-Host "`n===== PAPER MODE =====" -ForegroundColor Cyan

    # Find latest paper draft version
    $drafts = Get-ChildItem $RunDir -Filter 'paper_draft_v*.md' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending
    $latestDraft = if ($drafts.Count -gt 0) { $drafts[0].Name } else { '11_paper_draft.md' }
    Write-Host "  Latest draft: $latestDraft" -ForegroundColor White

    # Determine next version
    if ($latestDraft -match 'v(\d+)') {
        $nextVersion = [int]$Matches[1] + 1
        $nextDraft = "paper_draft_v$nextVersion.md"
    } else {
        $nextDraft = "paper_draft_v1.md"
    }

    Write-Host "  Next version: $nextDraft" -ForegroundColor White
    Write-Host "`n  [ACTION] Open Copilot Chat and run: @WRITING_AGENT" -ForegroundColor White
    Write-Host "  [INPUT]  Update $latestDraft with new results. Save as $nextDraft" -ForegroundColor White

    if ($Task.iteration -and $Task.iteration.paper_sections) {
        Write-Host "  [FOCUS]  Sections to update:" -ForegroundColor White
        foreach ($s in $Task.iteration.paper_sections) {
            Write-Host "           - $s" -ForegroundColor White
        }
    }

    if (-not $AutoConfirm) {
        Write-Host "`n  Press [Enter] when paper is updated, or type 'skip': " -NoNewline
        $answer = Read-Host
        if ($answer.Trim().ToLower() -eq 'skip') { return 'skipped' }
    }

    Write-Host "  [OK] Paper mode complete." -ForegroundColor Green
    return 'done'
}

# ---- Review Mode --------------------------------------------------------------
function Invoke-IterativeReviewMode {
    param([string]$RunDir, [pscustomobject]$State, [pscustomobject]$Task)

    Write-Host "`n===== REVIEW MODE =====" -ForegroundColor Cyan

    # Find latest review number
    $reviews = Get-ChildItem $RunDir -Filter '*review_report*.md' -ErrorAction SilentlyContinue
    $nextReviewNum = $reviews.Count + 1
    $reviewFile = "review_report_iter$nextReviewNum.md"
    $planFile   = "revision_plan_iter$nextReviewNum.md"

    Write-Host "  Next review: $reviewFile" -ForegroundColor White
    Write-Host "`n  [ACTION] Open Copilot Chat and run: @REVIEWER_AGENT" -ForegroundColor White
    Write-Host "  [INPUT]  Review latest paper draft. Save as $reviewFile" -ForegroundColor White

    if (-not $AutoConfirm) {
        Write-Host "`n  Press [Enter] when review is done, or type 'skip': " -NoNewline
        $answer = Read-Host
        if ($answer.Trim().ToLower() -eq 'skip') { return 'skipped' }
    }

    # Try to parse new review score
    $reviewPath = Join-Path $RunDir $reviewFile
    if (Test-Path $reviewPath) {
        $content = Get-Content $reviewPath -Raw
        if ($content -match '(?i)##\s*Overall\s*Score[:\s]*(\d+\.?\d*)\s*/\s*100') {
            $newScore = [double]$Matches[1]
            Write-Host "  New review score: $newScore / 100" -ForegroundColor Green

            # Update trajectory
            if (-not $State.revision_score_trajectory) {
                $State | Add-Member -NotePropertyName 'revision_score_trajectory' -NotePropertyValue @() -Force
            }
            $State.revision_score_trajectory += $newScore
            Write-PipelineState $RunDir $State
        }
    }

    Write-Host "  [OK] Review mode complete." -ForegroundColor Green
    return 'done'
}

# ---- Main dispatch ------------------------------------------------------------
Write-Host ""

# Update state with iteration info
$State | Add-Member -NotePropertyName 'iteration_mode' -NotePropertyValue $iterMode -Force
$State | Add-Member -NotePropertyName 'last_action_timestamp' -NotePropertyValue (Get-Date -Format 'o') -Force
Write-PipelineState $runDir $state

switch ($iterMode) {
    'audit' {
        Invoke-AuditMode -RunDir $runDir -State $state -Task $task
    }
    'experiment' {
        Invoke-AuditMode -RunDir $runDir -State $state -Task $task
        Invoke-IterativeExperimentMode -RunDir $runDir -State $state -Task $task
    }
    'paper' {
        Invoke-IterativePaperMode -RunDir $runDir -State $state -Task $task
    }
    'review' {
        Invoke-IterativeReviewMode -RunDir $runDir -State $state -Task $task
    }
    'revision' {
        Invoke-AuditMode -RunDir $runDir -State $state -Task $task
        Invoke-IterativeExperimentMode -RunDir $runDir -State $state -Task $task
        Invoke-IterativePaperMode -RunDir $runDir -State $state -Task $task
        Invoke-IterativeReviewMode -RunDir $runDir -State $state -Task $task
    }
    'full' {
        $skipPhases = @()
        if ($task.iteration -and $task.iteration.skip_phases) {
            $skipPhases = @($task.iteration.skip_phases)
        }

        Invoke-AuditMode -RunDir $runDir -State $state -Task $task

        if ('experiment' -notin $skipPhases) {
            Invoke-IterativeExperimentMode -RunDir $runDir -State $state -Task $task
        }
        if ('paper' -notin $skipPhases) {
            Invoke-IterativePaperMode -RunDir $runDir -State $state -Task $task
        }
        if ('review' -notin $skipPhases) {
            Invoke-IterativeReviewMode -RunDir $runDir -State $state -Task $task
        }
    }
}

# ---- Summary -------------------------------------------------------------------
$blockerLog = Join-Path $runDir 'blocker_log.jsonl'
$blockerCount = if (Test-Path $blockerLog) { @(Get-Content $blockerLog).Count } else { 0 }

Write-Host "`n===== ITERATIVE PIPELINE COMPLETE =====" -ForegroundColor Magenta
Write-Host "Run dir     : $runDir"               -ForegroundColor White
Write-Host "Mode        : $iterMode"             -ForegroundColor White
Write-Host "Best metric : $($state.best_metric)" -ForegroundColor White
Write-Host "Rev round   : $($state.revision_round)" -ForegroundColor White
if ($state.revision_score_trajectory) {
    Write-Host "Score path  : $($state.revision_score_trajectory -join ' -> ')" -ForegroundColor White
}
Write-Host "Blockers    : $blockerCount (see blocker_log.jsonl)" `
           -ForegroundColor $(if ($blockerCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""

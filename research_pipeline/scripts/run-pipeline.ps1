#Requires -Version 5.1
<#
.SYNOPSIS
    RND Pipeline Orchestrator - runs all research phases without stopping.

.DESCRIPTION
    Sequences agent and experiment phases from topic intake to paper revision.
    Implements never-stop guarantees via:
      - Retry with exponential back-off for each shell command
      - Fallback stub output when max retries are exhausted
      - Blocker log (blocker_log.jsonl) for post-run diagnosis
      - State checkpoint after every phase (enables -Resume)
    - Iteration loop (experiment -> innovation) with patience-based early stop

.PARAMETER TaskFile
    Path to a JSON task file (see research_pipeline/tasks/task.schema.json).

.PARAMETER Resume
    Skip phases whose output file already exists and is non-empty.
    Resolves the most recent run directory for the task's topic_slug.

.PARAMETER DryRun
    Print experiment commands but do not execute them.

.PARAMETER AutoConfirm
    Skip manual confirmation prompts for non-experiment phases.
    Useful for unattended pipeline runs.

.PARAMETER StrictExec
    Enforce fail-fast execution. Missing inputs/outputs or missing commands
    will stop the pipeline instead of writing fallback stubs.

.PARAMETER MaxRetries
    Maximum per-command retry attempts (default: 3).

.PARAMETER RetryDelaySec
    Base delay in seconds before first retry; doubles each attempt (default: 30).

.EXAMPLE
    # New run
    powershell -ExecutionPolicy Bypass -File run-pipeline.ps1 -TaskFile ..\tasks\my-task.json

    # Resume after a partial run
    powershell -ExecutionPolicy Bypass -File run-pipeline.ps1 -TaskFile ..\tasks\my-task.json -Resume

    # Validate without executing
    powershell -ExecutionPolicy Bypass -File run-pipeline.ps1 -TaskFile ..\tasks\my-task.json -DryRun
#>
param(
    [Parameter(Mandatory)][string]$TaskFile,
    [switch]$Resume,
    [switch]$DryRun,
    [switch]$AutoConfirm,
    [switch]$StrictExec,
    [int]$MaxRetries   = 3,
    [int]$RetryDelaySec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # never halt on non-terminating errors

# ---- Bootstrap -----------------------------------------------------------------
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $ScriptDir 'lib\pipeline-helpers.ps1')

# ---- Phase catalogue ------------------------------------------------------------
# HasCommands = $true when pipeline runs shell commands from the task or plan file.
# Group labels are informational; parallel execution is future work
$PHASES = @(
    [ordered]@{
        Name        = 'retrieval'
        Agent       = 'PAPER_SCOUT'
        OutputFile  = '02_sota_evidence_table.md'
        InputFiles  = @('01_topic_and_constraints.md')
        HasCommands = $false
        Group       = 'A'
    }
    [ordered]@{
        Name        = 'code_intel'
        Agent       = 'CODE_SCOUT'
        OutputFile  = '03_open_source_landscape.md'
        InputFiles  = @('01_topic_and_constraints.md')
        HasCommands = $false
        Group       = 'A'
    }
    [ordered]@{
        Name        = 'innovation'
        Agent       = 'INNOVATION_DESIGNER'
        OutputFile  = '05_feasibility_matrix.md'
        InputFiles  = @('02_sota_evidence_table.md', '03_open_source_landscape.md')
        HasCommands = $false
        Group       = 'B'
    }
    [ordered]@{
        Name        = 'scaffold'
        Agent       = 'EXPERIMENT_ENGINEER'
        OutputFile  = '07_implementation_log.md'
        InputFiles  = @('04_innovation_hypotheses.md', '05_feasibility_matrix.md', '06_experiment_plan.md')
        HasCommands = $false
        Group       = 'C'
    }
    [ordered]@{
        Name        = 'experiment'
        Agent       = 'EXPERIMENT_ENGINEER'
        OutputFile  = '09_experiment_results.md'
        InputFiles  = @('04_innovation_hypotheses.md', '05_feasibility_matrix.md', '06_experiment_plan.md')
        HasCommands = $true
        Group       = 'C'
    }
    [ordered]@{
        Name        = 'writing'
        Agent       = 'WRITING_AGENT'
        OutputFile  = '11_paper_draft.md'
        InputFiles  = @('02_sota_evidence_table.md', '09_experiment_results.md', '10_iteration_decisions.md')
        HasCommands = $false
        Group       = 'D'
    }
    [ordered]@{
        Name        = 'truthfulness'
        Agent       = 'WRITING_AGENT'
        OutputFile  = '14_truthfulness_report.md'
        InputFiles  = @('11_paper_draft.md', '09_experiment_results.md', '07_implementation_log.md')
        HasCommands = $false
        Group       = 'D2'
    }
    [ordered]@{
        Name        = 'review'
        Agent       = 'REVIEWER_AGENT'
        OutputFile  = '12_review_report.md'
        InputFiles  = @('11_paper_draft.md')
        HasCommands = $false
        Group       = 'E'
    }
    [ordered]@{
        Name        = 'revision'
        Agent       = 'REVIEWER_AGENT'
        OutputFile  = '13_revision_plan.md'
        InputFiles  = @('12_review_report.md')
        HasCommands = $false
        Group       = 'F'
    }
)

# ---- Helper: print a phase banner ----------------------------------------------
function Write-PhaseBanner([string]$PhaseName, [string]$AgentName, [string]$Group) {
    $line = '=' * 60
    Write-Host "`n$line" -ForegroundColor DarkGray
    Write-Host " PHASE  : $($PhaseName.ToUpper())   [Group $Group]" -ForegroundColor Cyan
    Write-Host " Agent  : $AgentName" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkGray
}

# ---- Command normalization: bind task commands to current run directory ---------
function Resolve-RunScopedCommand {
    param(
        [string]$Command,
        [string]$RunDir,
        [pscustomobject]$Task
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $Command
    }

    $resolved = [string]$Command
    $runAbs = (Resolve-Path $RunDir).Path

    $root = $script:rootDir
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Split-Path (Split-Path (Split-Path $RunDir -Parent) -Parent) -Parent
    }

    $runRel = $runAbs
    if ($runAbs.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $runRel = $runAbs.Substring($root.Length).TrimStart([char]92, [char]47)
    }
    $runRel = $runRel -replace '\\', '/'

    # Preferred templates for task authors.
    $resolved = $resolved.Replace('{{RUN_DIR}}', $runAbs)
    $resolved = $resolved.Replace('{{RUN_DIR_REL}}', $runRel)
    $resolved = $resolved.Replace('{{TOPIC_SLUG}}', [string]$Task.topic_slug)

    return $resolved
}

# ---- Agent phase: prompt user, verify output, optional stub --------------------
function Invoke-AgentPhase {
    param(
        [hashtable]$Phase,
        [string]$RunDir,
        [pscustomobject]$State,
        [switch]$ForceRun
    )
    Write-PhaseBanner $Phase.Name $Phase.Agent $Phase.Group

    $outPath = Join-Path $RunDir $Phase.OutputFile
    $beforeWriteTime = if (Test-Path $outPath) { (Get-Item $outPath).LastWriteTimeUtc } else { $null }

    # Guard: ensure all inputs exist (write stubs for missing ones)
    foreach ($inp in $Phase.InputFiles) {
        Assert-InputFile -RunDir $RunDir -Filename $inp -ConsumerPhase $Phase.Name -StrictExec:$StrictExec
    }

    # Skip if already done in Resume mode
    if (-not $ForceRun -and $Resume -and (Test-Path $outPath)) {
        $size = (Get-Item $outPath).Length
        if ($size -gt 100) {
            Write-Host "  [SKIP]  Output exists ($size bytes): $($Phase.OutputFile)" -ForegroundColor Gray
            return 'skipped'
        }
    }

    # Print invocation card
    Write-Host "" -ForegroundColor White
    Write-Host "  [ACTION] Open Copilot Chat and run: @$($Phase.Agent)" -ForegroundColor White
    Write-Host "  [INPUTS]" -ForegroundColor White
    foreach ($inp in $Phase.InputFiles) {
        Write-Host "    - $inp" -ForegroundColor White
    }
    Write-Host "  [EXPECTED OUTPUT] $($Phase.OutputFile)" -ForegroundColor White

    if ($ForceRun) {
        Write-Host "  [FORCE] Revision loop requested a fresh output update for this phase." -ForegroundColor DarkYellow
    }

    if ($AutoConfirm) {
        if ($ForceRun -and (Test-Path $outPath)) {
            if ($StrictExec) {
                Add-BlockerLog -RunDir $RunDir -Phase $Phase.Name `
                               -Reason 'StrictExec: forced rerun cannot use auto-refresh; real rewrite required'
                throw "StrictExec failed in phase '$($Phase.Name)': forced rerun requires real content update, not auto-refresh"
            }
            $refreshNote = "`n`n## Auto Refresh`n- Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n- Reason: Forced refresh during revision iteration.`n"
            Add-Content -Path $outPath -Value $refreshNote -Encoding UTF8
            Write-Host "  [AUTO] Existing output auto-refreshed for revision loop." -ForegroundColor Gray
            return 'done_auto_refresh'
        }
        Write-Host "  [AUTO] AutoConfirm enabled; skipping manual confirmation." -ForegroundColor Gray
        $answer = ''
    }
    else {
        Write-Host "  Press [Enter] when $($Phase.OutputFile) is written, or type 'skip' to use a stub: " `
                   -ForegroundColor White -NoNewline
        $answer = Read-Host
    }

    if ($answer.Trim().ToLower() -eq 'skip') {
        if ($StrictExec) {
            Add-BlockerLog -RunDir $RunDir -Phase $Phase.Name -Reason 'StrictExec: user skip is not allowed'
            throw "StrictExec blocked manual skip in phase '$($Phase.Name)'"
        }
        Write-StubOutput -RunDir $RunDir -Filename $Phase.OutputFile `
                         -Phase $Phase.Name -Reason 'User explicitly skipped this phase'
        Add-BlockerLog   -RunDir $RunDir -Phase $Phase.Name -Reason 'User skipped'
        return 'skipped_stub'
    }

    # Verify file was actually written
    if (-not (Test-Path $outPath) -or (Get-Item $outPath).Length -lt 10) {
        if ($StrictExec) {
            Add-BlockerLog -RunDir $RunDir -Phase $Phase.Name -Reason 'StrictExec: expected output missing'
            throw "StrictExec failed in phase '$($Phase.Name)': missing output '$($Phase.OutputFile)'"
        }
        Write-Host "  [WARN]  Output not found or empty - writing fallback stub." -ForegroundColor Yellow
        Write-StubOutput -RunDir $RunDir -Filename $Phase.OutputFile `
                         -Phase $Phase.Name -Reason 'Agent did not write the expected output file'
        Add-BlockerLog   -RunDir $RunDir -Phase $Phase.Name `
                         -Reason 'Output file absent after agent invocation'
        return 'done_fallback'
    }

    if ($ForceRun -and -not $AutoConfirm -and $null -ne $beforeWriteTime) {
        $afterWriteTime = (Get-Item $outPath).LastWriteTimeUtc
        if ($afterWriteTime -le $beforeWriteTime) {
            if ($StrictExec) {
                Add-BlockerLog -RunDir $RunDir -Phase $Phase.Name `
                               -Reason 'StrictExec: forced phase did not update output timestamp'
                throw "StrictExec failed in phase '$($Phase.Name)': forced rerun did not update output '$($Phase.OutputFile)'"
            }
            Write-Host "  [WARN] Forced rerun requested but output timestamp was unchanged." -ForegroundColor Yellow
        }
    }

    Write-Host "  [OK]  Phase '$($Phase.Name)' complete." -ForegroundColor Green
    return 'done'
}

# Scaffold phase: ensure minimal runnable engineering artifacts exist before experiment
function Invoke-ScaffoldPhase {
    param(
        [hashtable]$Phase,
        [string]$RunDir,
        [pscustomobject]$Task,
        [string]$RootDir,
        [switch]$ForceRun
    )

    Write-PhaseBanner 'scaffold' 'EXPERIMENT_ENGINEER' $Phase.Group

    foreach ($inp in $Phase.InputFiles) {
        Assert-InputFile -RunDir $RunDir -Filename $inp -ConsumerPhase 'scaffold' -StrictExec:$StrictExec
    }

    $logPath = Join-Path $RunDir '07_implementation_log.md'
    if (-not $ForceRun -and $Resume -and (Test-Path $logPath) -and (Get-Item $logPath).Length -gt 100) {
        Write-Host "  [SKIP]  Scaffold log already exists." -ForegroundColor Gray
        return 'skipped'
    }

    $created = [System.Collections.Generic.List[string]]::new()

    $experimentsDir = Join-Path $RunDir 'experiments'
    if (-not (Test-Path $experimentsDir)) {
        New-Item -ItemType Directory -Path $experimentsDir -Force | Out-Null
        $created.Add((Resolve-Path $experimentsDir).Path)
    }

    $resultsDir = Join-Path $RunDir 'results'
    if (-not (Test-Path $resultsDir)) {
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
        $created.Add((Resolve-Path $resultsDir).Path)
    }

    $requirementsPath = Join-Path $RunDir 'requirements.txt'
    if (-not (Test-Path $requirementsPath)) {
        @"
numpy>=1.24
scikit-learn>=1.3
pyyaml>=6.0
"@ | Set-Content $requirementsPath -Encoding UTF8
        $created.Add($requirementsPath)
    }

    $schemaPath = Join-Path $RunDir 'schema_v1.yaml'
    if (-not (Test-Path $schemaPath)) {
        @"
modalities:
  - name: feature_numeric
    type: numeric
  - name: feature_categorical
    type: categorical
target:
  name: label
"@ | Set-Content $schemaPath -Encoding UTF8
        $created.Add($schemaPath)
    }

    $defaultScripts = @(
        (Join-Path $experimentsDir 'run_baseline.py'),
        (Join-Path $experimentsDir 'run_cmra.py'),
        (Join-Path $experimentsDir 'print_best_auroc.py')
    )

    # Add script paths discovered from task commands (if any).
    $commandTexts = [System.Collections.Generic.List[string]]::new()
    if ($Task.commands -and $Task.commands.experiment) {
        foreach ($cmd in @($Task.commands.experiment)) { $commandTexts.Add([string]$cmd) }
    }
    if ($Task.commands -and $Task.commands.evalMetric) {
        $commandTexts.Add([string]$Task.commands.evalMetric)
    }

    $discoveredScripts = [System.Collections.Generic.List[string]]::new()
    foreach ($cmdText in $commandTexts) {
        $matches = [regex]::Matches($cmdText, '(?:"([^"]+?\.py)"|''([^'']+?\.py)''|([^\s"''`]+?\.py))')
        foreach ($m in $matches) {
            $scriptCandidate = ''
            if ($m.Groups[1].Success) {
                $scriptCandidate = $m.Groups[1].Value
            }
            elseif ($m.Groups[2].Success) {
                $scriptCandidate = $m.Groups[2].Value
            }
            elseif ($m.Groups[3].Success) {
                $scriptCandidate = $m.Groups[3].Value
            }
            if (-not $scriptCandidate) { continue }

            $scriptPath = if ([System.IO.Path]::IsPathRooted($scriptCandidate)) {
                $scriptCandidate
            }
            else {
                Join-Path $RootDir $scriptCandidate
            }
            if (-not ($discoveredScripts -contains $scriptPath)) {
                $discoveredScripts.Add($scriptPath)
            }
        }
    }

    foreach ($path in $discoveredScripts) {
        if (-not ($defaultScripts -contains $path)) {
            $defaultScripts += $path
        }
    }

    $runScriptContent = @"
import argparse
import json
import os


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--out', type=str, required=False)
    parser.add_argument('--modality_schema', type=str, default='')
    args, _ = parser.parse_known_args()

    # Minimal deterministic metric for smoke run.
    payload = {
        'auroc': 0.62,
        'seed': args.seed,
        'schema': args.modality_schema,
        'status': 'scaffold_smoke'
    }
    if args.out:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, 'w', encoding='utf-8') as f:
            json.dump(payload, f, indent=2)

    print(payload['auroc'])


if __name__ == '__main__':
    main()
"@

    $evalScriptContent = @"
import argparse
import json


def read_metric(path: str) -> float:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    return float(data.get('auroc', 0.0))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--inputs', nargs='+', required=True)
    args = parser.parse_args()

    best = 0.0
    for p in args.inputs:
        try:
            best = max(best, read_metric(p))
        except Exception:
            continue

    print(f"{best:.4f}")


if __name__ == '__main__':
    main()
"@

    foreach ($scriptPath in $defaultScripts) {
        if (Test-Path $scriptPath) { continue }

        $parentDir = Split-Path $scriptPath -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        if ([System.IO.Path]::GetFileName($scriptPath) -eq 'print_best_auroc.py') {
            $evalScriptContent | Set-Content $scriptPath -Encoding UTF8
        }
        else {
            $runScriptContent | Set-Content $scriptPath -Encoding UTF8
        }
        $created.Add($scriptPath)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# 07 Implementation Log`n')
    $lines.Add("**Scaffold time**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `n")
    $lines.Add('## Created or updated files`n')
    if ($created.Count -eq 0) {
        $lines.Add('- No files were created. Existing engineering scaffold is already present.`n')
    }
    else {
        foreach ($item in $created) {
            $lines.Add("- $item`n")
        }
    }
    $lines.Add('`n## Notes`n')
    $lines.Add('- Scaffold phase only creates missing artifacts and never overwrites existing code.`n')
    $lines.Add('- Generated scripts are smoke-run defaults and should be replaced by full implementations.`n')
    ($lines -join '') | Set-Content $logPath -Encoding UTF8

    $debugPath = Join-Path $RunDir '08_debug_log.md'
    if (-not (Test-Path $debugPath)) {
        @"
# 08 Debug Log

No errors recorded yet in scaffold phase.
"@ | Set-Content $debugPath -Encoding UTF8
    }

    Write-Host "  [OK] Scaffold phase complete. Created $($created.Count) file(s)." -ForegroundColor Green
    return 'done'
}

# ---- Experiment phase: execute commands with retry -----------------------------
function Invoke-ExperimentPhase {
    param(
        [hashtable]$Phase,
        [string]$RunDir,
        [pscustomobject]$Task,
        [switch]$ForceRun
    )
    Write-PhaseBanner 'experiment' 'EXPERIMENT_ENGINEER' $Phase.Group

    $outPath = Join-Path $RunDir '09_experiment_results.md'

    foreach ($inp in $Phase.InputFiles) {
        Assert-InputFile -RunDir $RunDir -Filename $inp -ConsumerPhase 'experiment' -StrictExec:$StrictExec
    }

    if (-not $ForceRun -and $Resume -and (Test-Path $outPath) -and (Get-Item $outPath).Length -gt 100) {
        Write-Host "  [SKIP]  Results already exist." -ForegroundColor Gray
        return 'skipped'
    }

    # Optional setup commands
    $setupCmds = @()
    if ($Task.commands -and $Task.commands.setup) {
        $setupCmds = @($Task.commands.setup)
    }
    $setupCmds = @($setupCmds | ForEach-Object { Resolve-RunScopedCommand -Command ([string]$_) -RunDir $RunDir -Task $Task })

    # Collect experiment commands: task file first, then parse experiment plan
    $cmds = @()
    if ($Task.commands -and $Task.commands.experiment) {
        $cmds = @($Task.commands.experiment)
    }
    if ($cmds.Count -eq 0) {
        Write-Host "  [INFO]  No commands in task file - parsing 06_experiment_plan.md..." `
                   -ForegroundColor Gray
        $cmds = Get-ExperimentCommands -RunDir $RunDir
    }
    $cmds = @($cmds | ForEach-Object { Resolve-RunScopedCommand -Command ([string]$_) -RunDir $RunDir -Task $Task })

    if ($cmds.Count -eq 0) {
        if ($StrictExec) {
            Add-BlockerLog -RunDir $RunDir -Phase 'experiment' -Reason 'StrictExec: no executable commands found'
            throw 'StrictExec failed: no experiment commands in task file or 06_experiment_plan.md'
        }
        Write-Host "  [WARN]  No executable commands found - writing stub." -ForegroundColor Yellow
        Write-StubOutput -RunDir $RunDir -Filename '09_experiment_results.md' `
                         -Phase 'experiment' -Reason 'No commands in task file or experiment plan'
        Add-BlockerLog   -RunDir $RunDir -Phase 'experiment' -Reason 'No commands available'
        return 'done_fallback'
    }

    Write-Host "  Found $($setupCmds.Count) setup command(s) and $($cmds.Count) experiment command(s)." -ForegroundColor White

    # Build results markdown incrementally
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# 09 Experiment Results`n")
    $lines.Add("**Run started**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `n")
    $lines.Add("**Mode**: $(if ($DryRun) {'DRY-RUN'} else {'LIVE'})  `n`n")
    if ($setupCmds.Count -gt 0) {
        $lines.Add("## Setup log`n")
    }
    $lines.Add("## Command log`n")

    $allPassed = $true

    foreach ($rawSetup in $setupCmds) {
        $setupCmd = $rawSetup.Trim()
        if (-not $setupCmd -or $setupCmd.StartsWith('#')) { continue }

        Write-Host "  [setup] > $setupCmd" -ForegroundColor White

        if ($DryRun) {
            $lines.Add("- **[DRY-RUN]** ``$setupCmd```n")
            continue
        }

        $setupOutput = ''
        $setupSuccess = Invoke-WithRetry -Label $setupCmd -MaxAttempts $MaxRetries `
                                         -BaseDelaySec $RetryDelaySec -Action {
            $script:setupOutput = & cmd.exe /c $setupCmd 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw "Exit code $LASTEXITCODE"
            }
        }

        if ($setupSuccess) {
            $lines.Add("- **[OK]** ``$setupCmd```n")
            Write-Host "    -> setup OK" -ForegroundColor Green
        }
        else {
            $lines.Add("- **[FAILED]** ``$setupCmd`` (exhausted $MaxRetries retries)`n")
            Add-BlockerLog -RunDir $RunDir -Phase 'experiment' `
                           -Reason "Setup command failed after $MaxRetries retries: $setupCmd"
            $allPassed = $false
        }
    }

    foreach ($rawCmd in $cmds) {
        $cmd = $rawCmd.Trim()
        if (-not $cmd -or $cmd.StartsWith('#')) { continue }

        Write-Host "  > $cmd" -ForegroundColor White

        if ($DryRun) {
            $lines.Add("- **[DRY-RUN]** ``$cmd```n")
            continue
        }

        $cmdOutput = ''
        $success = Invoke-WithRetry -Label $cmd -MaxAttempts $MaxRetries `
                                    -BaseDelaySec $RetryDelaySec -Action {
            $script:cmdOutput = & cmd.exe /c $cmd 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw "Exit code $LASTEXITCODE"
            }
        }

        if ($success) {
            $lines.Add("- **[OK]** ``$cmd```n")
            Write-Host "    -> OK" -ForegroundColor Green
        }
        else {
            $lines.Add("- **[FAILED]** ``$cmd`` (exhausted $MaxRetries retries)`n")
            Add-BlockerLog -RunDir $RunDir -Phase 'experiment' `
                           -Reason "Command failed after $MaxRetries retries: $cmd"
            $allPassed = $false
        }
    }

    $lines.Add("`n## Status`n")
    $statusLine = if ($allPassed) { 'All commands completed.' } else { 'Some commands failed - see blocker_log.jsonl.' }
    $lines.Add($statusLine)
    $metricValue = $null
    if ($Task.commands -and $Task.commands.evalMetric) {
        $evalCmd = Resolve-RunScopedCommand -Command ([string]$Task.commands.evalMetric) -RunDir $RunDir -Task $Task
        if ($evalCmd.Trim() -ne '') {
            Write-Host "  [eval] > $evalCmd" -ForegroundColor White
            if ($DryRun) {
                $lines.Add("`n## Eval metric`n- **[DRY-RUN]** ``$evalCmd```n")
            }
            else {
                $evalOutput = ''
                $script:evalOutput = ''
                $evalSuccess = Invoke-WithRetry -Label $evalCmd -MaxAttempts $MaxRetries `
                                                -BaseDelaySec $RetryDelaySec -Action {
                    $script:evalOutput = & cmd.exe /c $evalCmd 2>&1 | Out-String
                    if ($LASTEXITCODE -ne 0) {
                        throw "Exit code $LASTEXITCODE"
                    }
                }

                if ($evalSuccess) {
                    $evalOutput = [string]$script:evalOutput
                    if ($evalOutput -match '([0-9]+\.?[0-9]*)') {
                        $metricValue = [double]$Matches[1]
                        $lines.Add("`n## Eval metric`n- **[OK]** ``$evalCmd`` => $metricValue`n")
                        Write-Host "    -> metric = $metricValue" -ForegroundColor Green
                    }
                    else {
                        $lines.Add("`n## Eval metric`n- **[WARN]** Eval output has no parseable number.`n")
                        Add-BlockerLog -RunDir $RunDir -Phase 'experiment' `
                                       -Reason 'evalMetric completed but no numeric value was parsed'
                        $allPassed = $false
                    }
                }
                else {
                    $lines.Add("`n## Eval metric`n- **[FAILED]** ``$evalCmd`` (exhausted $MaxRetries retries)`n")
                    Add-BlockerLog -RunDir $RunDir -Phase 'experiment' `
                                   -Reason "evalMetric failed after $MaxRetries retries: $evalCmd"
                    $allPassed = $false
                }
            }
        }
    }

    if ($StrictExec -and $null -eq $metricValue -and -not $DryRun) {
        Add-BlockerLog -RunDir $RunDir -Phase 'experiment' -Reason 'StrictExec: metric missing after eval'
        throw 'StrictExec failed: evalMetric did not produce a parseable numeric metric'
    }

    if ($null -ne $metricValue) {
        $lines.Add("`n## Best Metric: $metricValue`n")
    }
    else {
        $lines.Add("`n## Best Metric: 0.0000`n")
    }

    $lines.Add("`n## Downstream: Safe to proceed`n")

    ($lines -join '') | Set-Content $outPath -Encoding UTF8

    if ($StrictExec -and -not $allPassed -and -not $DryRun) {
        Add-BlockerLog -RunDir $RunDir -Phase 'experiment' -Reason 'StrictExec: command failures detected'
        throw 'StrictExec failed: setup/experiment/eval commands had failures'
    }

    if ($allPassed) {
        return 'done'
    }
    else {
        return 'done_with_errors'
    }
}

# ---- Iteration loop: innovation -> experiment ----------------------------------
function Invoke-IterationLoop {
    param(
        [string]$RunDir,
        [pscustomobject]$Task,
        [pscustomobject]$State
    )

    $patience    = if ($Task.patience) { [int]$Task.patience } else { 2 }
    $minDelta    = if ($Task.min_delta) { [double]$Task.min_delta } else { 0.01 }
    $noImprove   = 0
    $bestMetric  = if ($State.best_metric) { [double]$State.best_metric } else { $null }
    $iterRound   = if ($State.iter_round)  { [int]$State.iter_round }     else { 0 }

    $innovPhase = $PHASES | Where-Object { $_.Name -eq 'innovation' }
    $scafPhase  = $PHASES | Where-Object { $_.Name -eq 'scaffold' }
    $expPhase   = $PHASES | Where-Object { $_.Name -eq 'experiment' }

    while ($true) {
        $iterRound++
        $State | Add-Member -NotePropertyName 'iter_round' -NotePropertyValue $iterRound -Force
        Write-Host "`n=== Iteration Round $iterRound (patience=$patience, min_delta=$minDelta) ===" -ForegroundColor Magenta

        # -- Innovation sub-phase --
        $innovStatus = Invoke-AgentPhase -Phase $innovPhase -RunDir $RunDir -State $State
        Set-PhaseStatus $State 'innovation' $innovStatus
        Write-PipelineState $RunDir $State

        # -- Scaffold sub-phase --
        $scafStatus = Invoke-ScaffoldPhase -Phase $scafPhase -RunDir $RunDir -Task $Task -RootDir $rootDir
        Set-PhaseStatus $State 'scaffold' $scafStatus
        Write-PipelineState $RunDir $State

        # -- Experiment sub-phase --
        $expStatus = Invoke-ExperimentPhase -Phase $expPhase -RunDir $RunDir -Task $Task
        Set-PhaseStatus $State 'experiment' $expStatus
        Write-PipelineState $RunDir $State

        # -- Metric check --
        $currentMetric = Get-BestMetricFromFile -ResultFile (Join-Path $RunDir '09_experiment_results.md')

        if ($null -ne $currentMetric) {
            Write-Host "  Metric this round : $currentMetric" -ForegroundColor White
            Write-Host "  Historical best   : $(if ($null -ne $bestMetric) { $bestMetric } else { 'n/a' })" `
                       -ForegroundColor White

            if ($null -eq $bestMetric -or ($currentMetric - $bestMetric) -ge $minDelta) {
                Write-Host "  [IMPROVED] Accepting this direction." -ForegroundColor Green
                $bestMetric = $currentMetric
                $State | Add-Member -NotePropertyName 'best_metric' -NotePropertyValue $bestMetric -Force
                $noImprove  = 0
                break   # move on to writing
            }
            else {
                $noImprove++
                Write-Host "  [NO GAIN] no-improve count: $noImprove / $patience" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  [NO METRIC] Cannot parse metric; counting as no-gain." -ForegroundColor Yellow
            $noImprove++
        }

        if ($noImprove -ge $patience) {
            Write-Host "  [EARLY STOP] patience exhausted - proceeding with best available results." `
                       -ForegroundColor Red
            Add-BlockerLog -RunDir $RunDir -Phase 'experiment' `
                           -Reason "Early stop after $noImprove rounds without min_delta improvement"
            break
        }

        # Reset experiment output so next round re-runs
        $expOut = Join-Path $RunDir '09_experiment_results.md'
        if (Test-Path $expOut) { Remove-Item $expOut -Force }

        Write-Host "  Resetting experiment output for next round..." -ForegroundColor DarkGray
        Write-PipelineState $RunDir $State
    }

    Write-PipelineState $RunDir $State
}

# ---- Result Expectation Gate: check if metric meets success_metric ----------------
function Invoke-ResultExpectationGate {
    param(
        [string]$RunDir,
        [pscustomobject]$Task,
        [pscustomobject]$State
    )

    $expectationPatience = if ($Task.expectation_patience) { [int]$Task.expectation_patience } else { 2 }
    $successMetric = if ($Task.success_metric) { [string]$Task.success_metric } else { '' }

    if ([string]::IsNullOrWhiteSpace($successMetric)) {
        Write-Host "`n[INFO]  No success_metric defined - skipping result expectation gate." -ForegroundColor Gray
        return
    }

    # Parse success_metric: e.g. "AUROC >= 0.90" -> threshold 0.90
    $threshold = $null
    $comparator = '>='
    if ($successMetric -match '(>=?|<=?)\s*([0-9]+\.?[0-9]*)') {
        $comparator = $Matches[1]
        $threshold = [double]$Matches[2]
    }

    if ($null -eq $threshold) {
        Write-Host "  [WARN] Cannot parse numeric threshold from success_metric: $successMetric" -ForegroundColor Yellow
        Add-BlockerLog -RunDir $RunDir -Phase 'result-expectation' `
                       -Reason "Cannot parse threshold from success_metric: $successMetric"
        return
    }

    $innovPhase = $PHASES | Where-Object { $_.Name -eq 'innovation' }
    $scafPhase  = $PHASES | Where-Object { $_.Name -eq 'scaffold' }
    $expPhase   = $PHASES | Where-Object { $_.Name -eq 'experiment' }

    for ($round = 1; $round -le $expectationPatience; $round++) {
        Write-Host "`n============================================================" -ForegroundColor Magenta
        Write-Host " RESULT EXPECTATION GATE - Check $round / $expectationPatience" -ForegroundColor Magenta
        Write-Host "============================================================" -ForegroundColor Magenta

        $currentMetric = Get-BestMetricFromFile -ResultFile (Join-Path $RunDir '09_experiment_results.md')

        Write-Host "  Current best metric : $(if ($null -ne $currentMetric) { $currentMetric } else { 'n/a' })" -ForegroundColor White
        Write-Host "  Success target      : $successMetric (threshold=$threshold)" -ForegroundColor White

        $met = $false
        if ($null -ne $currentMetric) {
            switch ($comparator) {
                '>='  { $met = $currentMetric -ge $threshold }
                '>'   { $met = $currentMetric -gt $threshold }
                '<='  { $met = $currentMetric -le $threshold }
                '<'   { $met = $currentMetric -lt $threshold }
                default { $met = $currentMetric -ge $threshold }
            }
        }

        if ($met) {
            Write-Host "  [PASSED] Metric $currentMetric meets expectation ($successMetric)" -ForegroundColor Green
            Add-BlockerLog -RunDir $RunDir -Phase 'result-expectation' `
                           -Reason "Result expectation met: metric=$currentMetric, target=$successMetric"
            return
        }

        Write-Host "  [UNMET] Metric does not meet expectation." -ForegroundColor Yellow

        # Log the gap
        $decisionFile = Join-Path $RunDir '10_iteration_decisions.md'
        $gapNote = @"

## Result Expectation Mismatch (Round $round)

- **Expected**: $successMetric
- **Actual best metric**: $(if ($null -ne $currentMetric) { $currentMetric } else { 'N/A' })
- **Gap**: $(if ($null -ne $currentMetric) { [math]::Round($threshold - $currentMetric, 4) } else { 'N/A' })
- **Action**: $(if ($round -lt $expectationPatience) { 'Returning to innovation + experiment loop' } else { 'Proceeding with best available (patience exhausted)' })
"@
        if (Test-Path $decisionFile) {
            Add-Content -Path $decisionFile -Value $gapNote -Encoding UTF8
        } else {
            $gapNote | Set-Content $decisionFile -Encoding UTF8
        }

        Add-BlockerLog -RunDir $RunDir -Phase 'result-expectation' `
                       -Reason "Result expectation mismatch round ${round}: metric=$(if ($null -ne $currentMetric) { $currentMetric } else { 'null' }), target=$successMetric"

        if ($round -ge $expectationPatience) {
            Write-Host "  [PATIENCE EXHAUSTED] Proceeding with [EXPECTATION UNMET] marker." -ForegroundColor Red
            $unmetNote = "`n`n## [EXPECTATION UNMET]`nBest available metric ($currentMetric) does not meet $successMetric after $expectationPatience rounds. Proceeding to writing with best available results.`n"
            Add-Content -Path $decisionFile -Value $unmetNote -Encoding UTF8
            Add-BlockerLog -RunDir $RunDir -Phase 'result-expectation' `
                           -Reason "Expectation patience exhausted after $expectationPatience rounds"
            return
        }

        # Loop back: innovation -> scaffold -> experiment
        Write-Host "  Returning to innovation + experiment..." -ForegroundColor Cyan

        $innovStatus = Invoke-AgentPhase -Phase $innovPhase -RunDir $RunDir -State $State -ForceRun
        Set-PhaseStatus $State 'innovation' $innovStatus
        Write-PipelineState $RunDir $State

        $scafStatus = Invoke-ScaffoldPhase -Phase $scafPhase -RunDir $RunDir -Task $Task -RootDir $rootDir -ForceRun
        Set-PhaseStatus $State 'scaffold' $scafStatus
        Write-PipelineState $RunDir $State

        $expOut = Join-Path $RunDir '09_experiment_results.md'
        if (Test-Path $expOut) { Remove-Item $expOut -Force }
        $expStatus = Invoke-ExperimentPhase -Phase $expPhase -RunDir $RunDir -Task $Task -ForceRun
        Set-PhaseStatus $State 'experiment' $expStatus
        Write-PipelineState $RunDir $State
    }
}

# ---- Truthfulness Verification Gate: cross-check paper vs code & results ----------
function Invoke-TruthfulnessVerification {
    param(
        [string]$RunDir,
        [pscustomobject]$Task,
        [pscustomobject]$State
    )

    $truthPatience = if ($Task.truthfulness_patience) { [int]$Task.truthfulness_patience } else { 2 }
    $truthPhase = $PHASES | Where-Object { $_.Name -eq 'truthfulness' }
    $writingPhase = $PHASES | Where-Object { $_.Name -eq 'writing' }

    for ($round = 1; $round -le $truthPatience; $round++) {
        Write-Host "`n============================================================" -ForegroundColor Magenta
        Write-Host " TRUTHFULNESS VERIFICATION - Round $round / $truthPatience" -ForegroundColor Magenta
        Write-Host "============================================================" -ForegroundColor Magenta

        # Invoke truthfulness check (agent produces 14_truthfulness_report.md)
        $truthStatus = Invoke-AgentPhase -Phase $truthPhase -RunDir $RunDir -State $State -ForceRun
        Set-PhaseStatus $State 'truthfulness' $truthStatus
        Write-PipelineState $RunDir $State

        # Check report for mismatches
        $reportPath = Join-Path $RunDir '14_truthfulness_report.md'
        $hasMismatch = $false

        if (Test-Path $reportPath) {
            $reportContent = Get-Content $reportPath -Raw
            if ($reportContent -match '(?i)mismatch|unverifiable') {
                $hasMismatch = $true
            }
        }

        if (-not $hasMismatch) {
            Write-Host "  [PASSED] Truthfulness verification passed." -ForegroundColor Green
            $State | Add-Member -NotePropertyName 'truthfulness_status' -NotePropertyValue 'passed' -Force
            Add-BlockerLog -RunDir $RunDir -Phase 'truthfulness-verification' `
                           -Reason "Truthfulness verification passed in round $round"
            Write-PipelineState $RunDir $State
            return
        }

        Write-Host "  [MISMATCH FOUND] Paper claims do not fully match implementation/results." -ForegroundColor Yellow
        Add-BlockerLog -RunDir $RunDir -Phase 'truthfulness-verification' `
                       -Reason "Truthfulness mismatch detected in round $round"

        if ($round -ge $truthPatience) {
            Write-Host "  [PATIENCE EXHAUSTED] Proceeding to review with truthfulness report attached." -ForegroundColor Red
            $State | Add-Member -NotePropertyName 'truthfulness_status' -NotePropertyValue 'failed_with_report' -Force
            Add-BlockerLog -RunDir $RunDir -Phase 'truthfulness-verification' `
                           -Reason "Truthfulness patience exhausted after $truthPatience rounds; proceeding with report attached"
            Write-PipelineState $RunDir $State
            return
        }

        # Route back to WRITING_AGENT to fix the draft
        Write-Host "  Routing back to WRITING_AGENT to correct the draft..." -ForegroundColor Cyan
        $writingStatus = Invoke-AgentPhase -Phase $writingPhase -RunDir $RunDir -State $State -ForceRun
        Set-PhaseStatus $State 'writing' $writingStatus
        Write-PipelineState $RunDir $State
    }
}

# ---- Revision loop: review feedback -> adjust -> experiment -> rewrite -> review ----
function Invoke-RevisionIterationLoop {
    param(
        [string]$RunDir,
        [pscustomobject]$Task,
        [pscustomobject]$State
    )

    $scoreThreshold       = if ($Task.revision_score_threshold) { [double]$Task.revision_score_threshold } else { 90 }
    $maxRounds            = if ($Task.revision_patience_max_rounds) { [int]$Task.revision_patience_max_rounds } else { 5 }
    $stagnationPatience   = if ($Task.revision_patience) { [int]$Task.revision_patience } else { 3 }
    $convergenceThreshold = if ($Task.revision_convergence_threshold) { [double]$Task.revision_convergence_threshold } else { 0.1 }
    $revisionRoundProp    = $State.PSObject.Properties['revision_round']
    $revisionRound        = if ($null -ne $revisionRoundProp -and $null -ne $revisionRoundProp.Value) { [int]$revisionRoundProp.Value } else { 0 }
    $stagnationCounter    = 0

    $trajectoryProp = $State.PSObject.Properties['revision_score_trajectory']
    if ($null -eq $trajectoryProp -or $null -eq $trajectoryProp.Value) {
        $State | Add-Member -NotePropertyName 'revision_score_trajectory' -NotePropertyValue @() -Force
    }
    
    $innovPhase   = $PHASES | Where-Object { $_.Name -eq 'innovation' }
    $scafPhase    = $PHASES | Where-Object { $_.Name -eq 'scaffold' }
    $expPhase     = $PHASES | Where-Object { $_.Name -eq 'experiment' }
    $writingPhase = $PHASES | Where-Object { $_.Name -eq 'writing' }
    $reviewPhase  = $PHASES | Where-Object { $_.Name -eq 'review' }

    while ($revisionRound -lt $maxRounds) {
        $revisionRound++
        $State | Add-Member -NotePropertyName 'revision_round' -NotePropertyValue $revisionRound -Force
        
        Write-Host "`n============================================================" -ForegroundColor Magenta
        Write-Host " REVISION ITERATION LOOP - Round $revisionRound / $maxRounds" -ForegroundColor Magenta
        Write-Host " (Review feedback -> Adjust -> Experiment -> Rewrite -> Review)" -ForegroundColor Magenta
        Write-Host "============================================================" -ForegroundColor Magenta

        # -- Step 1: Innovation (interpret review feedback & plan adjustments) --
        Write-Host "`n[Step 1] Innovation: Interpret review feedback and revise hypotheses" -ForegroundColor Cyan
        $innovStatus = Invoke-AgentPhase -Phase $innovPhase -RunDir $RunDir -State $State -ForceRun
        Set-PhaseStatus $State 'innovation' $innovStatus
        Write-PipelineState $RunDir $State

        # -- Step 2: Scaffold (implement code adjustments based on new plan) --
        Write-Host "`n[Step 2] Scaffold: Adjust engineering artifacts" -ForegroundColor Cyan
        $scafStatus = Invoke-ScaffoldPhase -Phase $scafPhase -RunDir $RunDir -Task $Task -RootDir $rootDir -ForceRun
        Set-PhaseStatus $State 'scaffold' $scafStatus
        Write-PipelineState $RunDir $State

        # -- Step 3: Experiment (re-run with adjusted code/hypotheses) --
        Write-Host "`n[Step 3] Experiment: Re-run experiments with adjustments" -ForegroundColor Cyan
        $expOut = Join-Path $RunDir '09_experiment_results.md'
        if (Test-Path $expOut) { Remove-Item $expOut -Force }
        $expStatus = Invoke-ExperimentPhase -Phase $expPhase -RunDir $RunDir -Task $Task -ForceRun
        Set-PhaseStatus $State 'experiment' $expStatus
        Write-PipelineState $RunDir $State

        # -- Step 4: Writing (rewrite paper with new results) --
        Write-Host "`n[Step 4] Writing: Rewrite paper with adjusted results" -ForegroundColor Cyan
        $writingStatus = Invoke-AgentPhase -Phase $writingPhase -RunDir $RunDir -State $State -ForceRun
        Set-PhaseStatus $State 'writing' $writingStatus
        Write-PipelineState $RunDir $State

        # -- Step 5: Review (conduct peer review again) --
        Write-Host "`n[Step 5] Review: Conduct peer review on revised paper" -ForegroundColor Cyan
        $reviewStatus = Invoke-AgentPhase -Phase $reviewPhase -RunDir $RunDir -State $State -ForceRun
        Set-PhaseStatus $State 'review' $reviewStatus
        Write-PipelineState $RunDir $State

        # -- Convergence check: paper quality score --
        Write-Host "`n[Check] Evaluating convergence via paper quality score..." -ForegroundColor Yellow

        $reviewFile = Join-Path $RunDir '12_review_report.md'
        $overallScore = $null

        if (Test-Path $reviewFile) {
            $reviewContent = Get-Content $reviewFile -Raw
            $requiredDims = @('Novelty', 'Rigor', 'Clarity', 'Completeness', 'Advancement', 'Objectivity', 'Theoretical', 'Logical')
            $presentDimCount = 0
            foreach ($dim in $requiredDims) {
                if ($reviewContent -match ("(?i)$dim")) {
                    $presentDimCount++
                }
            }

            if ($presentDimCount -lt 8) {
                $msg = "Scorecard is incomplete: found $presentDimCount/8 required dimensions"
                Write-Host "  [WARN] $msg" -ForegroundColor Yellow
                Add-BlockerLog -RunDir $RunDir -Phase 'revision-iteration' -Reason $msg
                if ($StrictExec) {
                    throw "StrictExec failed: $msg"
                }
            }

            if ($reviewContent -match '(?i)##\s*Overall\s*Score[:\s]*(\d+\.?\d*)\s*/\s*100') {
                $overallScore = [double]$Matches[1]
            }
            elseif ($reviewContent -match '(?i)Overall Score[:\s]*(\d+\.?\d*)\s*/\s*100') {
                $overallScore = [double]$Matches[1]
            }
        }

        if ($null -eq $overallScore) {
            Write-Host "  [WARN] Unable to parse overall score from review report" -ForegroundColor Yellow
            Write-Host "  Please ensure REVIEWER_AGENT outputs ## Overall Score: <number>/100" -ForegroundColor Yellow
            $overallScore = 0
        }

        $State.revision_score_trajectory += $overallScore
        Write-Host "  Paper Overall Score: $overallScore / 100" -ForegroundColor White
        Write-Host "  Target Threshold  : $scoreThreshold / 100" -ForegroundColor White

        $prevScore = $null
        if ($State.revision_score_trajectory.Count -ge 2) {
            $prevScore = [double]$State.revision_score_trajectory[$State.revision_score_trajectory.Count - 2]
        }
        $delta = if ($null -ne $prevScore) { [math]::Round($overallScore - $prevScore, 4) } else { $null }

        if ($null -ne $delta -and $delta -lt $convergenceThreshold) {
            $stagnationCounter++
        }
        else {
            $stagnationCounter = 0
        }

        Add-BlockerLog -RunDir $RunDir -Phase 'revision-iteration' `
                       -Reason "Revision round $revisionRound evaluated" `
                       -Meta @{ round = $revisionRound; score = $overallScore; previousScore = $prevScore; delta = $delta; stagnationCounter = $stagnationCounter; stagnationPatience = $stagnationPatience; convergenceThreshold = $convergenceThreshold }

        if ($overallScore -ge $scoreThreshold) {
            Write-Host "  [CONVERGED] Score $overallScore >= Threshold $scoreThreshold" -ForegroundColor Green
            Add-BlockerLog -RunDir $RunDir -Phase 'revision-iteration' `
                           -Reason "Converged after $revisionRound revision rounds (score=$overallScore, threshold=$scoreThreshold)"
            break
        }

        $gap = [math]::Round($scoreThreshold - $overallScore, 2)
        Write-Host "  [CONTINUE] Gap = $gap points. Proceeding to next round..." -ForegroundColor Yellow
        if ($stagnationCounter -ge $stagnationPatience) {
            Write-Host "  [NOTICE] Score stagnation detected ($stagnationCounter rounds; threshold=$convergenceThreshold)." -ForegroundColor DarkYellow
            Add-BlockerLog -RunDir $RunDir -Phase 'revision-iteration' `
                           -Reason "Stagnation warning: $stagnationCounter rounds without meaningful score gain" `
                           -Meta @{ round = $revisionRound; score = $overallScore; stagnationCounter = $stagnationCounter; stagnationPatience = $stagnationPatience; convergenceThreshold = $convergenceThreshold }
        }
    }

    if ($revisionRound -ge $maxRounds) {
        Write-Host "`n[NOTICE] Revision max rounds reached ($revisionRound / $maxRounds)" -ForegroundColor Yellow
        Add-BlockerLog -RunDir $RunDir -Phase 'revision-iteration' `
                       -Reason "Revision max rounds exhausted after $revisionRound rounds"
    }

    Write-PipelineState $RunDir $State
}
if (-not (Test-Path $TaskFile)) {
    Write-Host "[ERROR] Task file not found: $TaskFile" -ForegroundColor Red
    exit 1
}

try {
    $task = Read-JsonFile -Path $TaskFile -ThrowOnError
}
catch {
    Write-Host "[ERROR] Failed to parse task file: $TaskFile" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($null -eq $task) {
    Write-Host "[ERROR] Task file parsed to null: $TaskFile" -ForegroundColor Red
    exit 1
}

Write-Host "`n===== RND PIPELINE ORCHESTRATOR =====" -ForegroundColor Magenta
Write-Host "Topic  : $($task.topic)"      -ForegroundColor White
Write-Host "Slug   : $($task.topic_slug)" -ForegroundColor White
Write-Host "Venue  : $($task.target_venue)" -ForegroundColor White
Write-Host "Budget : $($task.compute_budget_gpu_hours) GPU-hours" -ForegroundColor White
if ($DryRun)  { Write-Host "[MODE]   DRY-RUN"  -ForegroundColor Yellow }
if ($Resume)  { Write-Host "[MODE]   RESUME"   -ForegroundColor Yellow }
if ($AutoConfirm) { Write-Host "[MODE]   AUTO-CONFIRM" -ForegroundColor Yellow }
if ($StrictExec) { Write-Host "[MODE]   STRICT-EXEC" -ForegroundColor Yellow }

# ---- Resolve (or create) run directory -----------------------------------------
$rootDir = Split-Path (Split-Path $ScriptDir -Parent) -Parent
$runsBase = Join-Path $rootDir "research_runs\$($task.topic_slug)"

$runDir = $null
if ($Resume -and (Test-Path $runsBase)) {
    $runDir = Get-ChildItem $runsBase -Directory |
              Sort-Object Name -Descending |
              Select-Object -First 1 -ExpandProperty FullName
    if ($runDir) {
        Write-Host "Resume : $runDir" -ForegroundColor Yellow
    }
}

if (-not $runDir) {
    $runId  = (Get-Date -Format 'yyyyMMdd') + '_run' + (Get-Random -Minimum 1 -Maximum 100).ToString('00')
    $runDir = Join-Path $runsBase $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    Write-Host "New run: $runDir" -ForegroundColor Green
}

# ---- Initialize state -----------------------------------------------------------
$statePath = Join-Path $runDir 'state.json'
$state = Read-PipelineState -RunDir $runDir

if ($null -eq $state -and (Test-Path $statePath)) {
    $corruptBackup = Join-Path $runDir ("state.corrupt.{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Copy-Item $statePath $corruptBackup -Force
    Write-Host "  [WARN] Existing state.json could not be parsed. Backed up to: $corruptBackup" -ForegroundColor Yellow
    if ($StrictExec) {
        Add-BlockerLog -RunDir $runDir -Phase 'bootstrap' -Reason 'StrictExec: state.json is unreadable'
        throw "StrictExec failed: unreadable state.json. Inspect backup: $corruptBackup"
    }
    Add-BlockerLog -RunDir $runDir -Phase 'bootstrap' -Reason 'state.json unreadable; reinitialized state from defaults'
}

if (-not $state) {
    $state = [pscustomobject]@{
        run_id          = Split-Path $runDir -Leaf
        topic_slug      = $task.topic_slug
        topic           = $task.topic
        started_at      = (Get-Date -Format 'o')
        phase_status    = [pscustomobject]@{}
        best_metric     = $null
        iter_round      = 0
        revision_round  = 0
        revision_score_trajectory = @()
        blockers        = @()
    }
}

# ---- Write constraints file (01) -----------------------------------------------
$constraintFile = Join-Path $runDir '01_topic_and_constraints.md'
if (-not (Test-Path $constraintFile)) {
    $srcList = if ($task.sources) { ($task.sources -join ', ') } else { 'arXiv, Semantic Scholar' }
    $baselineList = if ($task.baseline_repositories) { ($task.baseline_repositories | ForEach-Object { "- $_" } | Out-String) } else { '- unknown' }
    $methodSection = if ($task.method_description) { "`n## Proposed Method`n`n$($task.method_description)`n" } else { '' }
    @"
# 01 Topic and Constraints

**Topic**: $($task.topic)
**Slug**: $($task.topic_slug)
**Year range**: $($task.year_range)
**Language**: $($task.language)
**Target venue**: $($task.target_venue)
**Compute budget (GPU-hours)**: $($task.compute_budget_gpu_hours)
**Deadline**: $($task.deadline)
**Sources**: $srcList
$methodSection
## Success metric

$($task.success_metric)

## Stopping criteria

- min_delta : $($task.min_delta)
- patience  : $($task.patience)

## Baseline repositories

$baselineList
"@ | Set-Content $constraintFile -Encoding UTF8
    Write-Host "  [INIT] Created 01_topic_and_constraints.md" -ForegroundColor Green
}
Write-PipelineState $runDir $state

# ???? Sequential phases: retrieval and code_intel ??????????????????????????????????????????????????????????????
foreach ($phaseName in @('retrieval', 'code_intel')) {
    $ph = $PHASES | Where-Object { $_.Name -eq $phaseName }
    $existing = Get-PhaseStatus $state $phaseName
    if ($Resume -and $existing -in @('done', 'skipped')) {
        Write-Host "`n[SKIP]  Phase '$phaseName' already: $existing" -ForegroundColor Gray
        continue
    }
    $status = Invoke-AgentPhase -Phase $ph -RunDir $runDir -State $state
    Set-PhaseStatus $state $phaseName $status
    Write-PipelineState $runDir $state
}

# ???? Iteration loop: innovation + experiment ????????????????????????????????????????????????????????????????????????
$innExisting = Get-PhaseStatus $state 'innovation'
$scfExisting = Get-PhaseStatus $state 'scaffold'
$expExisting = Get-PhaseStatus $state 'experiment'
if ($Resume -and $innExisting -in @('done','skipped') -and $scfExisting -in @('done','skipped') -and $expExisting -in @('done','skipped','done_with_errors')) {
    Write-Host "`n[SKIP]  Iteration loop already complete (innovation=$innExisting, scaffold=$scfExisting, experiment=$expExisting)" `
               -ForegroundColor Gray
}
else {
    Invoke-IterationLoop -RunDir $runDir -Task $task -State $state
}

# Result Expectation Gate: check if experiments meet success_metric
Write-Host "`n[INFO]  Running result expectation gate..." -ForegroundColor Magenta
Invoke-ResultExpectationGate -RunDir $runDir -Task $task -State $state

# Writing phase
$writingPh = $PHASES | Where-Object { $_.Name -eq 'writing' }
$writingExisting = Get-PhaseStatus $state 'writing'
if ($Resume -and $writingExisting -in @('done', 'skipped')) {
    Write-Host "`n[SKIP]  Phase 'writing' already: $writingExisting" -ForegroundColor Gray
}
else {
    $status = Invoke-AgentPhase -Phase $writingPh -RunDir $runDir -State $state
    Set-PhaseStatus $state 'writing' $status
    Write-PipelineState $runDir $state
}

# Truthfulness Verification Gate: cross-check paper vs code & results
Write-Host "`n[INFO]  Running truthfulness verification gate..." -ForegroundColor Magenta
Invoke-TruthfulnessVerification -RunDir $runDir -Task $task -State $state

# Review phase
$reviewPh = $PHASES | Where-Object { $_.Name -eq 'review' }
$reviewExisting = Get-PhaseStatus $state 'review'
if ($Resume -and $reviewExisting -in @('done', 'skipped')) {
    Write-Host "`n[SKIP]  Phase 'review' already: $reviewExisting" -ForegroundColor Gray
}
else {
    $status = Invoke-AgentPhase -Phase $reviewPh -RunDir $runDir -State $state
    Set-PhaseStatus $state 'review' $status
    Write-PipelineState $runDir $state
}

# ???? Revision Feedback Loop ????????????????????????????????????????????????????????????????????????????
$enableRevisionLoop = if ($task.enable_revision_loop -ne $false) { $true } else { $false }
if ($enableRevisionLoop) {
    Write-Host "`n[INFO]  Entering revision iteration loop (enable_revision_loop=$enableRevisionLoop)" -ForegroundColor Magenta
    Invoke-RevisionIterationLoop -RunDir $runDir -Task $task -State $state
}
else {
    Write-Host "`n[INFO]  Revision loop disabled. Running single final revision phase." -ForegroundColor DarkGray
    $revPhase = $PHASES | Where-Object { $_.Name -eq 'revision' }
    $existing = Get-PhaseStatus $state 'revision'
    if (-not ($Resume -and $existing -in @('done', 'skipped'))) {
        $status = Invoke-AgentPhase -Phase $revPhase -RunDir $runDir -State $state
        Set-PhaseStatus $state 'revision' $status
        Write-PipelineState $runDir $state
    }
}


# ???? Summary ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
Write-PipelineState $runDir $state

$blockerLog = Join-Path $runDir 'blocker_log.jsonl'
$blockerCount = if (Test-Path $blockerLog) { @(Get-Content $blockerLog).Count } else { 0 }

Write-Host "`n===== PIPELINE COMPLETE =====" -ForegroundColor Magenta
Write-Host "Run dir     : $runDir"               -ForegroundColor White
Write-Host "Best metric : $($state.best_metric)" -ForegroundColor White
Write-Host "Iterations  : $($state.iter_round)"  -ForegroundColor White
Write-Host "Blockers    : $blockerCount (see blocker_log.jsonl)" -ForegroundColor $(if ($blockerCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""


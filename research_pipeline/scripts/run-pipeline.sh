#!/usr/bin/env bash
#
# run-pipeline.sh — RND Pipeline Orchestrator (bash port)
#
# Sequences agent and experiment phases from topic intake to paper revision.
# Implements never-stop guarantees via retry, stubs, and blocker logging.
#
# Usage:
#   # New run
#   bash research_pipeline/scripts/run-pipeline.sh \
#       --task research_pipeline/tasks/my-task.json --auto-confirm --strict-exec
#
#   # Resume
#   bash research_pipeline/scripts/run-pipeline.sh \
#       --task research_pipeline/tasks/my-task.json --resume --auto-confirm
#
#   # Dry-run
#   bash research_pipeline/scripts/run-pipeline.sh \
#       --task research_pipeline/tasks/my-task.json --dry-run --auto-confirm

set -uo pipefail  # not -e: we handle errors ourselves

# ---- Argument parsing ----------------------------------------------------------
TASK_FILE=""
RESUME=false
DRY_RUN=false
AUTO_CONFIRM=false
STRICT_EXEC=false
MAX_RETRIES=3
RETRY_DELAY_SEC=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task|-t)          TASK_FILE="$2";          shift 2 ;;
        --resume|-r)        RESUME=true;             shift ;;
        --dry-run|-d)       DRY_RUN=true;            shift ;;
        --auto-confirm|-a)  AUTO_CONFIRM=true;       shift ;;
        --strict-exec|-s)   STRICT_EXEC=true;        shift ;;
        --max-retries)      MAX_RETRIES="$2";        shift 2 ;;
        --retry-delay)      RETRY_DELAY_SEC="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $0 --task <task.json> [--resume] [--dry-run] [--auto-confirm] [--strict-exec]"
            exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$TASK_FILE" ]]; then
    echo "[ERROR] --task is required" >&2
    exit 1
fi

if [[ ! -f "$TASK_FILE" ]]; then
    echo "[ERROR] Task file not found: $TASK_FILE" >&2
    exit 1
fi

# ---- Dependency check ----------------------------------------------------------
if ! command -v jq &>/dev/null; then
    echo "[ERROR] jq is required. Install with: sudo apt-get install jq" >&2
    exit 1
fi

# ---- Bootstrap -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pipeline-helpers.sh"

# ---- Load task file ------------------------------------------------------------
TASK_JSON=$(cat "$TASK_FILE")
if [[ -z "$TASK_JSON" ]]; then
    echo "[ERROR] Task file is empty: $TASK_FILE" >&2
    exit 1
fi

# Validate JSON
if ! echo "$TASK_JSON" | jq empty 2>/dev/null; then
    echo "[ERROR] Invalid JSON in task file: $TASK_FILE" >&2
    exit 1
fi

TOPIC=$(get_json_field "$TASK_JSON" "topic")
TOPIC_SLUG=$(get_json_field "$TASK_JSON" "topic_slug")
TARGET_VENUE=$(get_json_field "$TASK_JSON" "target_venue")
COMPUTE_BUDGET=$(get_json_field "$TASK_JSON" "compute_budget_gpu_hours")
SUCCESS_METRIC=$(get_json_field "$TASK_JSON" "success_metric")
METHOD_DESC=$(get_json_field "$TASK_JSON" "method_description")

# ---- Phase catalogue (as parallel arrays) --------------------------------------
PHASE_NAMES=(retrieval code_intel innovation scaffold experiment writing truthfulness review revision)
PHASE_AGENTS=(PAPER_SCOUT CODE_SCOUT INNOVATION_DESIGNER EXPERIMENT_ENGINEER EXPERIMENT_ENGINEER WRITING_AGENT WRITING_AGENT REVIEWER_AGENT REVIEWER_AGENT)
PHASE_OUTPUTS=(02_sota_evidence_table.md 03_open_source_landscape.md 05_feasibility_matrix.md 07_implementation_log.md 09_experiment_results.md 11_paper_draft.md 14_truthfulness_report.md 12_review_report.md 13_revision_plan.md)
PHASE_GROUPS=(A A B C C D D2 E F)
PHASE_HAS_COMMANDS=(false false false false true false false false false)

# Input files (space-separated per phase)
PHASE_INPUTS=(
    "01_topic_and_constraints.md"
    "01_topic_and_constraints.md"
    "02_sota_evidence_table.md 03_open_source_landscape.md"
    "04_innovation_hypotheses.md 05_feasibility_matrix.md 06_experiment_plan.md"
    "04_innovation_hypotheses.md 05_feasibility_matrix.md 06_experiment_plan.md"
    "02_sota_evidence_table.md 09_experiment_results.md 10_iteration_decisions.md"
    "11_paper_draft.md 09_experiment_results.md 07_implementation_log.md"
    "11_paper_draft.md"
    "12_review_report.md"
)

# ---- Helper: get phase index ---------------------------------------------------
get_phase_index() {
    local name="$1"
    for i in "${!PHASE_NAMES[@]}"; do
        if [[ "${PHASE_NAMES[$i]}" == "$name" ]]; then
            echo "$i"
            return
        fi
    done
    echo "-1"
}

# ---- Agent phase: prompt user, verify output ---------------------
invoke_agent_phase() {
    local phase_name="$1"
    local run_dir="$2"
    local force_run="${3:-false}"
    local idx
    idx=$(get_phase_index "$phase_name")

    local agent="${PHASE_AGENTS[$idx]}"
    local output_file="${PHASE_OUTPUTS[$idx]}"
    local group="${PHASE_GROUPS[$idx]}"
    local inputs="${PHASE_INPUTS[$idx]}"
    local out_path="$run_dir/$output_file"

    write_phase_banner "$phase_name" "$agent" "$group"

    local before_mtime=""
    if [[ -f "$out_path" ]]; then
        before_mtime=$(stat -c '%Y' "$out_path" 2>/dev/null || stat -f '%m' "$out_path" 2>/dev/null || echo "")
    fi

    # Guard: ensure all inputs exist
    for inp in $inputs; do
        assert_input_file "$run_dir" "$inp" "$phase_name" "$STRICT_EXEC" || {
            if [[ "$STRICT_EXEC" == "true" ]]; then exit 1; fi
        }
    done

    # Skip if already done in Resume mode
    if [[ "$force_run" != "true" && "$RESUME" == "true" && -f "$out_path" ]]; then
        local size
        size=$(stat -c '%s' "$out_path" 2>/dev/null || stat -f '%z' "$out_path" 2>/dev/null || echo "0")
        if (( size > 100 )); then
            _color_gray "  [SKIP]  Output exists ($size bytes): $output_file"
            echo "skipped"
            return 0
        fi
    fi

    echo ""
    _color_white "  [ACTION] Open Copilot Chat and run: @$agent"
    _color_white "  [INPUTS]"
    for inp in $inputs; do
        _color_white "    - $inp"
    done
    _color_white "  [EXPECTED OUTPUT] $output_file"

    if [[ "$force_run" == "true" ]]; then
        _color_yellow "  [FORCE] Revision loop requested a fresh output update for this phase."
    fi

    local answer=""
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        if [[ "$force_run" == "true" && -f "$out_path" ]]; then
            if [[ "$STRICT_EXEC" == "true" ]]; then
                add_blocker_log "$run_dir" "$phase_name" \
                    "StrictExec: forced rerun cannot use auto-refresh"
                echo "[ERROR] StrictExec: forced rerun requires real content update" >&2
                exit 1
            fi
            local now
            now=$(date '+%Y-%m-%d %H:%M:%S')
            printf "\n\n## Auto Refresh\n- Timestamp: %s\n- Reason: Forced refresh during revision iteration.\n" "$now" >> "$out_path"
            _color_gray "  [AUTO] Existing output auto-refreshed for revision loop."
            echo "done_auto_refresh"
            return 0
        fi
        _color_gray "  [AUTO] AutoConfirm enabled; skipping manual confirmation."
    else
        echo -n "  Press [Enter] when $output_file is written, or type 'skip': "
        read -r answer
    fi

    if [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]' | xargs)" == "skip" ]]; then
        if [[ "$STRICT_EXEC" == "true" ]]; then
            add_blocker_log "$run_dir" "$phase_name" "StrictExec: user skip is not allowed"
            echo "[ERROR] StrictExec blocked manual skip in phase '$phase_name'" >&2
            exit 1
        fi
        write_stub_output "$run_dir" "$output_file" "$phase_name" "User explicitly skipped this phase"
        add_blocker_log "$run_dir" "$phase_name" "User skipped"
        echo "skipped_stub"
        return 0
    fi

    # Verify file was actually written
    if [[ ! -f "$out_path" ]] || (( $(stat -c '%s' "$out_path" 2>/dev/null || stat -f '%z' "$out_path" 2>/dev/null || echo "0") < 10 )); then
        if [[ "$STRICT_EXEC" == "true" ]]; then
            add_blocker_log "$run_dir" "$phase_name" "StrictExec: expected output missing"
            echo "[ERROR] StrictExec: missing output '$output_file'" >&2
            exit 1
        fi
        _color_yellow "  [WARN]  Output not found or empty - writing fallback stub."
        write_stub_output "$run_dir" "$output_file" "$phase_name" \
            "Agent did not write the expected output file"
        add_blocker_log "$run_dir" "$phase_name" "Output file absent after agent invocation"
        echo "done_fallback"
        return 0
    fi

    _color_green "  [OK]  Phase '$phase_name' complete."
    echo "done"
    return 0
}

# ---- Scaffold phase: minimal runnable engineering artifacts --------------------
invoke_scaffold_phase() {
    local run_dir="$1"
    local force_run="${2:-false}"

    write_phase_banner "scaffold" "EXPERIMENT_ENGINEER" "C"

    local inputs="04_innovation_hypotheses.md 05_feasibility_matrix.md 06_experiment_plan.md"
    for inp in $inputs; do
        assert_input_file "$run_dir" "$inp" "scaffold" "$STRICT_EXEC" || {
            if [[ "$STRICT_EXEC" == "true" ]]; then exit 1; fi
        }
    done

    local log_path="$run_dir/07_implementation_log.md"
    if [[ "$force_run" != "true" && "$RESUME" == "true" && -f "$log_path" ]]; then
        local size
        size=$(stat -c '%s' "$log_path" 2>/dev/null || stat -f '%z' "$log_path" 2>/dev/null || echo "0")
        if (( size > 100 )); then
            _color_gray "  [SKIP]  Scaffold log already exists."
            echo "skipped"
            return 0
        fi
    fi

    local created=()

    local experiments_dir="$run_dir/experiments"
    if [[ ! -d "$experiments_dir" ]]; then
        mkdir -p "$experiments_dir"
        created+=("$experiments_dir")
    fi

    local results_dir="$run_dir/results"
    if [[ ! -d "$results_dir" ]]; then
        mkdir -p "$results_dir"
        created+=("$results_dir")
    fi

    local requirements_path="$run_dir/requirements.txt"
    if [[ ! -f "$requirements_path" ]]; then
        cat > "$requirements_path" <<'EOF'
numpy>=1.24
scikit-learn>=1.3
pyyaml>=6.0
EOF
        created+=("$requirements_path")
    fi

    local schema_path="$run_dir/schema_v1.yaml"
    if [[ ! -f "$schema_path" ]]; then
        cat > "$schema_path" <<'EOF'
modalities:
  - name: feature_numeric
    type: numeric
  - name: feature_categorical
    type: categorical
target:
  name: label
EOF
        created+=("$schema_path")
    fi

    # Create scaffold Python scripts if missing
    local default_scripts=(
        "$experiments_dir/run_baseline.py"
        "$experiments_dir/run_cmra.py"
        "$experiments_dir/print_best_auroc.py"
    )

    local run_script_content
    read -r -d '' run_script_content <<'PYEOF' || true
import argparse
import json
import os


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--out', type=str, required=False)
    parser.add_argument('--modality_schema', type=str, default='')
    args, _ = parser.parse_known_args()

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
PYEOF

    local eval_script_content
    read -r -d '' eval_script_content <<'PYEOF' || true
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
PYEOF

    for script_path in "${default_scripts[@]}"; do
        if [[ -f "$script_path" ]]; then continue; fi
        local parent_dir
        parent_dir=$(dirname "$script_path")
        mkdir -p "$parent_dir"
        local fname
        fname=$(basename "$script_path")
        if [[ "$fname" == "print_best_auroc.py" ]]; then
            echo "$eval_script_content" > "$script_path"
        else
            echo "$run_script_content" > "$script_path"
        fi
        created+=("$script_path")
    done

    # Write implementation log
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "# 07 Implementation Log"
        echo ""
        echo "**Scaffold time**: $now  "
        echo ""
        echo "## Created or updated files"
        echo ""
        if [[ ${#created[@]} -eq 0 ]]; then
            echo "- No files were created. Existing engineering scaffold is already present."
        else
            for item in "${created[@]}"; do
                echo "- $item"
            done
        fi
        echo ""
        echo "## Notes"
        echo ""
        echo "- Scaffold phase only creates missing artifacts and never overwrites existing code."
        echo "- Generated scripts are smoke-run defaults and should be replaced by full implementations."
    } > "$log_path"

    local debug_path="$run_dir/08_debug_log.md"
    if [[ ! -f "$debug_path" ]]; then
        cat > "$debug_path" <<'EOF'
# 08 Debug Log

No errors recorded yet in scaffold phase.
EOF
    fi

    _color_green "  [OK] Scaffold phase complete. Created ${#created[@]} file(s)."
    echo "done"
    return 0
}

# ---- Experiment phase: execute commands with retry -----------------------------
invoke_experiment_phase() {
    local run_dir="$1"
    local force_run="${2:-false}"
    local idx
    idx=$(get_phase_index "experiment")

    write_phase_banner "experiment" "EXPERIMENT_ENGINEER" "${PHASE_GROUPS[$idx]}"

    local out_path="$run_dir/09_experiment_results.md"
    local inputs="${PHASE_INPUTS[$idx]}"

    for inp in $inputs; do
        assert_input_file "$run_dir" "$inp" "experiment" "$STRICT_EXEC" || {
            if [[ "$STRICT_EXEC" == "true" ]]; then exit 1; fi
        }
    done

    if [[ "$force_run" != "true" && "$RESUME" == "true" && -f "$out_path" ]]; then
        local size
        size=$(stat -c '%s' "$out_path" 2>/dev/null || stat -f '%z' "$out_path" 2>/dev/null || echo "0")
        if (( size > 100 )); then
            _color_gray "  [SKIP]  Results already exist."
            echo "skipped"
            return 0
        fi
    fi

    # Collect setup commands
    local -a setup_cmds=()
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] && setup_cmds+=("$cmd")
    done < <(echo "$TASK_JSON" | jq -r '.commands.setup[]? // empty')

    # Resolve template variables
    local -a resolved_setup=()
    for cmd in "${setup_cmds[@]}"; do
        resolved_setup+=("$(resolve_run_scoped_command "$cmd" "$run_dir" "$TOPIC_SLUG" "$ROOT_DIR")")
    done

    # Collect experiment commands
    local -a cmds=()
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] && cmds+=("$cmd")
    done < <(echo "$TASK_JSON" | jq -r '.commands.experiment[]? // empty')

    if [[ ${#cmds[@]} -eq 0 ]]; then
        _color_gray "  [INFO]  No commands in task file - parsing 06_experiment_plan.md..."
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] && cmds+=("$cmd")
        done < <(get_experiment_commands "$run_dir")
    fi

    # Resolve template variables
    local -a resolved_cmds=()
    for cmd in "${cmds[@]}"; do
        resolved_cmds+=("$(resolve_run_scoped_command "$cmd" "$run_dir" "$TOPIC_SLUG" "$ROOT_DIR")")
    done

    if [[ ${#resolved_cmds[@]} -eq 0 ]]; then
        if [[ "$STRICT_EXEC" == "true" ]]; then
            add_blocker_log "$run_dir" "experiment" "StrictExec: no executable commands found"
            echo "[ERROR] StrictExec: no experiment commands" >&2
            exit 1
        fi
        _color_yellow "  [WARN]  No executable commands found - writing stub."
        write_stub_output "$run_dir" "09_experiment_results.md" "experiment" \
            "No commands in task file or experiment plan"
        add_blocker_log "$run_dir" "experiment" "No commands available"
        echo "done_fallback"
        return 0
    fi

    _color_white "  Found ${#resolved_setup[@]} setup command(s) and ${#resolved_cmds[@]} experiment command(s)."

    # Build results markdown
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local mode_label="LIVE"
    [[ "$DRY_RUN" == "true" ]] && mode_label="DRY-RUN"

    local lines=""
    lines+="# 09 Experiment Results\n\n"
    lines+="**Run started**: $now  \n"
    lines+="**Mode**: $mode_label  \n\n"
    if [[ ${#resolved_setup[@]} -gt 0 ]]; then
        lines+="## Setup log\n\n"
    fi
    lines+="## Command log\n\n"

    local all_passed=true

    # Run setup commands
    for setup_cmd in "${resolved_setup[@]}"; do
        local trimmed
        trimmed=$(echo "$setup_cmd" | xargs)
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

        _color_white "  [setup] > $trimmed"
        if [[ "$DRY_RUN" == "true" ]]; then
            lines+="- **[DRY-RUN]** \`$trimmed\`\n"
            continue
        fi

        if invoke_with_retry "$trimmed" "$MAX_RETRIES" "$RETRY_DELAY_SEC" \
            bash -c "$trimmed"; then
            lines+="- **[OK]** \`$trimmed\`\n"
            _color_green "    -> setup OK"
        else
            lines+="- **[FAILED]** \`$trimmed\` (exhausted $MAX_RETRIES retries)\n"
            add_blocker_log "$run_dir" "experiment" \
                "Setup command failed after $MAX_RETRIES retries: $trimmed"
            all_passed=false
        fi
    done

    # Run experiment commands
    for cmd in "${resolved_cmds[@]}"; do
        local trimmed
        trimmed=$(echo "$cmd" | xargs)
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

        _color_white "  > $trimmed"
        if [[ "$DRY_RUN" == "true" ]]; then
            lines+="- **[DRY-RUN]** \`$trimmed\`\n"
            continue
        fi

        if invoke_with_retry "$trimmed" "$MAX_RETRIES" "$RETRY_DELAY_SEC" \
            bash -c "$trimmed"; then
            lines+="- **[OK]** \`$trimmed\`\n"
            _color_green "    -> OK"
        else
            lines+="- **[FAILED]** \`$trimmed\` (exhausted $MAX_RETRIES retries)\n"
            add_blocker_log "$run_dir" "experiment" \
                "Command failed after $MAX_RETRIES retries: $trimmed"
            all_passed=false
        fi
    done

    lines+="\n## Status\n\n"
    if [[ "$all_passed" == "true" ]]; then
        lines+="All commands completed.\n"
    else
        lines+="Some commands failed - see blocker_log.jsonl.\n"
    fi

    # Eval metric
    local metric_value=""
    local eval_cmd
    eval_cmd=$(echo "$TASK_JSON" | jq -r '.commands.evalMetric // empty')
    if [[ -n "$eval_cmd" ]]; then
        eval_cmd=$(resolve_run_scoped_command "$eval_cmd" "$run_dir" "$TOPIC_SLUG" "$ROOT_DIR")
        local trimmed_eval
        trimmed_eval=$(echo "$eval_cmd" | xargs)
        if [[ -n "$trimmed_eval" ]]; then
            _color_white "  [eval] > $trimmed_eval"
            if [[ "$DRY_RUN" == "true" ]]; then
                lines+="\n## Eval metric\n- **[DRY-RUN]** \`$trimmed_eval\`\n"
            else
                local eval_output=""
                if eval_output=$(invoke_with_retry "$trimmed_eval" "$MAX_RETRIES" "$RETRY_DELAY_SEC" \
                    bash -c "$trimmed_eval" 2>&1); then
                    local parsed
                    parsed=$(echo "$eval_output" | grep -oP '[0-9]+\.?[0-9]*' | head -1)
                    if [[ -n "$parsed" ]]; then
                        metric_value="$parsed"
                        lines+="\n## Eval metric\n- **[OK]** \`$trimmed_eval\` => $metric_value\n"
                        _color_green "    -> metric = $metric_value"
                    else
                        lines+="\n## Eval metric\n- **[WARN]** Eval output has no parseable number.\n"
                        add_blocker_log "$run_dir" "experiment" \
                            "evalMetric completed but no numeric value was parsed"
                        all_passed=false
                    fi
                else
                    lines+="\n## Eval metric\n- **[FAILED]** \`$trimmed_eval\` (exhausted $MAX_RETRIES retries)\n"
                    add_blocker_log "$run_dir" "experiment" \
                        "evalMetric failed after $MAX_RETRIES retries: $trimmed_eval"
                    all_passed=false
                fi
            fi
        fi
    fi

    if [[ "$STRICT_EXEC" == "true" && -z "$metric_value" && "$DRY_RUN" != "true" ]]; then
        add_blocker_log "$run_dir" "experiment" "StrictExec: metric missing after eval"
        echo "[ERROR] StrictExec: evalMetric did not produce a parseable numeric metric" >&2
        exit 1
    fi

    if [[ -n "$metric_value" ]]; then
        lines+="\n## Best Metric: $metric_value\n"
    else
        lines+="\n## Best Metric: 0.0000\n"
    fi

    lines+="\n## Downstream: Safe to proceed\n"

    echo -e "$lines" > "$out_path"

    if [[ "$STRICT_EXEC" == "true" && "$all_passed" != "true" && "$DRY_RUN" != "true" ]]; then
        add_blocker_log "$run_dir" "experiment" "StrictExec: command failures detected"
        echo "[ERROR] StrictExec: setup/experiment/eval commands had failures" >&2
        exit 1
    fi

    if [[ "$all_passed" == "true" ]]; then
        echo "done"
    else
        echo "done_with_errors"
    fi
    return 0
}

# ---- Iteration loop: innovation -> experiment ----------------------------------
invoke_iteration_loop() {
    local run_dir="$1"
    local state_json="$2"

    local patience
    patience=$(echo "$TASK_JSON" | jq -r '.patience // 2')
    local min_delta
    min_delta=$(echo "$TASK_JSON" | jq -r '.min_delta // 0.01')
    local no_improve=0
    local best_metric
    best_metric=$(echo "$state_json" | jq -r '.best_metric // empty')
    local iter_round
    iter_round=$(echo "$state_json" | jq -r '.iter_round // 0')

    while true; do
        iter_round=$((iter_round + 1))
        state_json=$(echo "$state_json" | jq --argjson r "$iter_round" '.iter_round = $r')

        _color_magenta ""
        _color_magenta "=== Iteration Round $iter_round (patience=$patience, min_delta=$min_delta) ==="

        # Innovation
        local innov_status
        innov_status=$(invoke_agent_phase "innovation" "$run_dir" "false")
        state_json=$(set_phase_status "$state_json" "innovation" "$innov_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Scaffold
        local scaf_status
        scaf_status=$(invoke_scaffold_phase "$run_dir" "false")
        state_json=$(set_phase_status "$state_json" "scaffold" "$scaf_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Experiment
        local exp_status
        exp_status=$(invoke_experiment_phase "$run_dir" "false")
        state_json=$(set_phase_status "$state_json" "experiment" "$exp_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Metric check
        local current_metric
        current_metric=$(get_best_metric_from_file "$run_dir/09_experiment_results.md")

        if [[ -n "$current_metric" ]]; then
            _color_white "  Metric this round : $current_metric"
            _color_white "  Historical best   : ${best_metric:-n/a}"

            if [[ -z "$best_metric" ]] || (( $(echo "$current_metric - $best_metric >= $min_delta" | bc -l) )); then
                _color_green "  [IMPROVED] Accepting this direction."
                best_metric="$current_metric"
                state_json=$(echo "$state_json" | jq --argjson m "$best_metric" '.best_metric = $m')
                no_improve=0
                break
            else
                no_improve=$((no_improve + 1))
                _color_yellow "  [NO GAIN] no-improve count: $no_improve / $patience"
            fi
        else
            _color_yellow "  [NO METRIC] Cannot parse metric; counting as no-gain."
            no_improve=$((no_improve + 1))
        fi

        if (( no_improve >= patience )); then
            _color_red "  [EARLY STOP] patience exhausted - proceeding with best available results."
            add_blocker_log "$run_dir" "experiment" \
                "Early stop after $no_improve rounds without min_delta improvement"
            break
        fi

        # Reset experiment output for next round
        rm -f "$run_dir/09_experiment_results.md"
        _color_gray "  Resetting experiment output for next round..."
        write_pipeline_state "$run_dir" "$state_json"
    done

    write_pipeline_state "$run_dir" "$state_json"
    # Export updated state
    STATE_JSON="$state_json"
}

# ---- Result Expectation Gate ---------------------------------------------------
invoke_result_expectation_gate() {
    local run_dir="$1"
    local state_json="$2"

    local expectation_patience
    expectation_patience=$(echo "$TASK_JSON" | jq -r '.expectation_patience // 2')
    local success_metric
    success_metric=$(echo "$TASK_JSON" | jq -r '.success_metric // empty')

    if [[ -z "$success_metric" ]]; then
        _color_gray "[INFO]  No success_metric defined - skipping result expectation gate."
        STATE_JSON="$state_json"
        return
    fi

    # Parse threshold from success_metric (e.g. "AUROC >= 0.90")
    local threshold=""
    local comparator=">="
    if [[ "$success_metric" =~ ([\>\<]=?)\ *([0-9]+\.?[0-9]*) ]]; then
        comparator="${BASH_REMATCH[1]}"
        threshold="${BASH_REMATCH[2]}"
    fi

    if [[ -z "$threshold" ]]; then
        _color_yellow "  [WARN] Cannot parse numeric threshold from success_metric: $success_metric"
        add_blocker_log "$run_dir" "result-expectation" \
            "Cannot parse threshold from success_metric: $success_metric"
        STATE_JSON="$state_json"
        return
    fi

    local round
    for (( round=1; round<=expectation_patience; round++ )); do
        _color_magenta ""
        _color_magenta "============================================================"
        _color_magenta " RESULT EXPECTATION GATE - Check $round / $expectation_patience"
        _color_magenta "============================================================"

        local current_metric
        current_metric=$(get_best_metric_from_file "$run_dir/09_experiment_results.md")

        _color_white "  Current best metric : ${current_metric:-n/a}"
        _color_white "  Success target      : $success_metric (threshold=$threshold)"

        local met=false
        if [[ -n "$current_metric" ]]; then
            case "$comparator" in
                ">=") (( $(echo "$current_metric >= $threshold" | bc -l 2>/dev/null || echo "0") )) && met=true ;;
                ">")  (( $(echo "$current_metric > $threshold"  | bc -l 2>/dev/null || echo "0") )) && met=true ;;
                "<=") (( $(echo "$current_metric <= $threshold" | bc -l 2>/dev/null || echo "0") )) && met=true ;;
                "<")  (( $(echo "$current_metric < $threshold"  | bc -l 2>/dev/null || echo "0") )) && met=true ;;
                *)    (( $(echo "$current_metric >= $threshold" | bc -l 2>/dev/null || echo "0") )) && met=true ;;
            esac
        fi

        if [[ "$met" == "true" ]]; then
            _color_green "  [PASSED] Metric $current_metric meets expectation ($success_metric)"
            add_blocker_log "$run_dir" "result-expectation" \
                "Result expectation met: metric=$current_metric, target=$success_metric"
            STATE_JSON="$state_json"
            return
        fi

        _color_yellow "  [UNMET] Metric does not meet expectation."

        # Log the gap
        local decision_file="$run_dir/10_iteration_decisions.md"
        local gap=""
        if [[ -n "$current_metric" ]]; then
            gap=$(echo "$threshold - $current_metric" | bc -l 2>/dev/null || echo "N/A")
        fi
        local action_text="Returning to innovation + experiment loop"
        if (( round >= expectation_patience )); then
            action_text="Proceeding with best available (patience exhausted)"
        fi

        local gap_note
        gap_note=$(printf "\n## Result Expectation Mismatch (Round %d)\n\n- **Expected**: %s\n- **Actual best metric**: %s\n- **Gap**: %s\n- **Action**: %s\n" \
            "$round" "$success_metric" "${current_metric:-N/A}" "${gap:-N/A}" "$action_text")

        if [[ -f "$decision_file" ]]; then
            echo "$gap_note" >> "$decision_file"
        else
            echo "$gap_note" > "$decision_file"
        fi

        add_blocker_log "$run_dir" "result-expectation" \
            "Result expectation mismatch round $round: metric=${current_metric:-null}, target=$success_metric"

        if (( round >= expectation_patience )); then
            _color_red "  [PATIENCE EXHAUSTED] Proceeding with [EXPECTATION UNMET] marker."
            printf "\n\n## [EXPECTATION UNMET]\nBest available metric (%s) does not meet %s after %d rounds. Proceeding to writing with best available results.\n" \
                "${current_metric:-N/A}" "$success_metric" "$expectation_patience" >> "$decision_file"
            add_blocker_log "$run_dir" "result-expectation" \
                "Expectation patience exhausted after $expectation_patience rounds"
            STATE_JSON="$state_json"
            return
        fi

        # Loop back: innovation -> scaffold -> experiment
        _color_cyan "  Returning to innovation + experiment..."

        local innov_status
        innov_status=$(invoke_agent_phase "innovation" "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "innovation" "$innov_status")
        write_pipeline_state "$run_dir" "$state_json"

        local scaf_status
        scaf_status=$(invoke_scaffold_phase "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "scaffold" "$scaf_status")
        write_pipeline_state "$run_dir" "$state_json"

        rm -f "$run_dir/09_experiment_results.md"
        local exp_status
        exp_status=$(invoke_experiment_phase "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "experiment" "$exp_status")
        write_pipeline_state "$run_dir" "$state_json"
    done

    STATE_JSON="$state_json"
}

# ---- Truthfulness Verification Gate --------------------------------------------
invoke_truthfulness_verification() {
    local run_dir="$1"
    local state_json="$2"

    local truth_patience
    truth_patience=$(echo "$TASK_JSON" | jq -r '.truthfulness_patience // 2')

    local round
    for (( round=1; round<=truth_patience; round++ )); do
        _color_magenta ""
        _color_magenta "============================================================"
        _color_magenta " TRUTHFULNESS VERIFICATION - Round $round / $truth_patience"
        _color_magenta "============================================================"

        # Invoke truthfulness check (agent produces 14_truthfulness_report.md)
        local truth_status
        truth_status=$(invoke_agent_phase "truthfulness" "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "truthfulness" "$truth_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Check report for mismatches
        local report_path="$run_dir/14_truthfulness_report.md"
        local has_mismatch=false

        if [[ -f "$report_path" ]]; then
            if grep -qiE 'mismatch|unverifiable' "$report_path"; then
                has_mismatch=true
            fi
        fi

        if [[ "$has_mismatch" == "false" ]]; then
            _color_green "  [PASSED] Truthfulness verification passed."
            state_json=$(echo "$state_json" | jq '.truthfulness_status = "passed"')
            add_blocker_log "$run_dir" "truthfulness-verification" \
                "Truthfulness verification passed in round $round"
            write_pipeline_state "$run_dir" "$state_json"
            STATE_JSON="$state_json"
            return
        fi

        _color_yellow "  [MISMATCH FOUND] Paper claims do not fully match implementation/results."
        add_blocker_log "$run_dir" "truthfulness-verification" \
            "Truthfulness mismatch detected in round $round"

        if (( round >= truth_patience )); then
            _color_red "  [PATIENCE EXHAUSTED] Proceeding to review with truthfulness report attached."
            state_json=$(echo "$state_json" | jq '.truthfulness_status = "failed_with_report"')
            add_blocker_log "$run_dir" "truthfulness-verification" \
                "Truthfulness patience exhausted after $truth_patience rounds; proceeding with report attached"
            write_pipeline_state "$run_dir" "$state_json"
            STATE_JSON="$state_json"
            return
        fi

        # Route back to WRITING_AGENT to fix the draft
        _color_cyan "  Routing back to WRITING_AGENT to correct the draft..."
        local writing_status
        writing_status=$(invoke_agent_phase "writing" "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "writing" "$writing_status")
        write_pipeline_state "$run_dir" "$state_json"
    done

    STATE_JSON="$state_json"
}

# ---- Revision loop -------------------------------------------------------------
invoke_revision_iteration_loop() {
    local run_dir="$1"
    local state_json="$2"

    local score_threshold
    score_threshold=$(echo "$TASK_JSON" | jq -r '.revision_score_threshold // 90')
    local max_rounds
    max_rounds=$(echo "$TASK_JSON" | jq -r '.revision_patience_max_rounds // 5')
    local stagnation_patience
    stagnation_patience=$(echo "$TASK_JSON" | jq -r '.revision_patience // 3')
    local convergence_threshold
    convergence_threshold=$(echo "$TASK_JSON" | jq -r '.revision_convergence_threshold // 0.1')

    local revision_round
    revision_round=$(echo "$state_json" | jq -r '.revision_round // 0')
    local stagnation_counter=0

    # Initialize trajectory if needed
    state_json=$(echo "$state_json" | jq 'if .revision_score_trajectory == null then .revision_score_trajectory = [] else . end')

    while (( revision_round < max_rounds )); do
        revision_round=$((revision_round + 1))
        state_json=$(echo "$state_json" | jq --argjson r "$revision_round" '.revision_round = $r')

        _color_magenta ""
        _color_magenta "============================================================"
        _color_magenta " REVISION ITERATION LOOP - Round $revision_round / $max_rounds"
        _color_magenta " (Review feedback -> Adjust -> Experiment -> Rewrite -> Review)"
        _color_magenta "============================================================"

        # Step 1: Innovation
        _color_cyan "[Step 1] Innovation: Interpret review feedback and revise hypotheses"
        local innov_status
        innov_status=$(invoke_agent_phase "innovation" "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "innovation" "$innov_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Step 2: Scaffold
        _color_cyan "[Step 2] Scaffold: Adjust engineering artifacts"
        local scaf_status
        scaf_status=$(invoke_scaffold_phase "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "scaffold" "$scaf_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Step 3: Experiment
        _color_cyan "[Step 3] Experiment: Re-run experiments with adjustments"
        rm -f "$run_dir/09_experiment_results.md"
        local exp_status
        exp_status=$(invoke_experiment_phase "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "experiment" "$exp_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Step 4: Writing
        _color_cyan "[Step 4] Writing: Rewrite paper with adjusted results"
        local writing_status
        writing_status=$(invoke_agent_phase "writing" "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "writing" "$writing_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Step 5: Review
        _color_cyan "[Step 5] Review: Conduct peer review on revised paper"
        local review_status
        review_status=$(invoke_agent_phase "review" "$run_dir" "true")
        state_json=$(set_phase_status "$state_json" "review" "$review_status")
        write_pipeline_state "$run_dir" "$state_json"

        # Convergence check
        _color_yellow "[Check] Evaluating convergence via paper quality score..."
        local review_file="$run_dir/12_review_report.md"
        local overall_score=""

        if [[ -f "$review_file" ]]; then
            local review_content
            review_content=$(cat "$review_file")

            # Check required dimensions
            local required_dims=(Novelty Rigor Clarity Completeness Advancement Objectivity Theoretical Logical)
            local present_dim_count=0
            for dim in "${required_dims[@]}"; do
                if echo "$review_content" | grep -qi "$dim"; then
                    present_dim_count=$((present_dim_count + 1))
                fi
            done

            if (( present_dim_count < 8 )); then
                local msg="Scorecard is incomplete: found $present_dim_count/8 required dimensions"
                _color_yellow "  [WARN] $msg"
                add_blocker_log "$run_dir" "revision-iteration" "$msg"
                if [[ "$STRICT_EXEC" == "true" ]]; then
                    echo "[ERROR] StrictExec: $msg" >&2
                    exit 1
                fi
            fi

            overall_score=$(echo "$review_content" | grep -oiP '##\s*Overall\s*Score[:\s]*\K[0-9]+\.?[0-9]*(?=\s*/\s*100)' | head -1)
            if [[ -z "$overall_score" ]]; then
                overall_score=$(echo "$review_content" | grep -oiP 'Overall Score[:\s]*\K[0-9]+\.?[0-9]*(?=\s*/\s*100)' | head -1)
            fi
        fi

        if [[ -z "$overall_score" ]]; then
            _color_yellow "  [WARN] Unable to parse overall score from review report"
            _color_yellow "  Please ensure REVIEWER_AGENT outputs ## Overall Score: <number>/100"
            overall_score=0
        fi

        state_json=$(echo "$state_json" | jq --argjson s "$overall_score" '.revision_score_trajectory += [$s]')

        _color_white "  Paper Overall Score: $overall_score / 100"
        _color_white "  Target Threshold  : $score_threshold / 100"

        # Check previous score for delta
        local prev_score=""
        local traj_len
        traj_len=$(echo "$state_json" | jq '.revision_score_trajectory | length')
        if (( traj_len >= 2 )); then
            prev_score=$(echo "$state_json" | jq -r ".revision_score_trajectory[$((traj_len - 2))]")
        fi

        local delta=""
        if [[ -n "$prev_score" ]]; then
            delta=$(echo "$overall_score - $prev_score" | bc -l 2>/dev/null || echo "0")
        fi

        if [[ -n "$delta" ]] && (( $(echo "$delta < $convergence_threshold" | bc -l 2>/dev/null || echo "0") )); then
            stagnation_counter=$((stagnation_counter + 1))
        else
            stagnation_counter=0
        fi

        add_blocker_log "$run_dir" "revision-iteration" \
            "Revision round $revision_round evaluated" \
            "{\"round\":$revision_round,\"score\":$overall_score,\"stagnationCounter\":$stagnation_counter}"

        if (( $(echo "$overall_score >= $score_threshold" | bc -l 2>/dev/null || echo "0") )); then
            _color_green "  [CONVERGED] Score $overall_score >= Threshold $score_threshold"
            add_blocker_log "$run_dir" "revision-iteration" \
                "Converged after $revision_round revision rounds (score=$overall_score, threshold=$score_threshold)"
            break
        fi

        local gap
        gap=$(echo "$score_threshold - $overall_score" | bc -l 2>/dev/null || echo "0")
        _color_yellow "  [CONTINUE] Gap = $gap points. Proceeding to next round..."

        if (( stagnation_counter >= stagnation_patience )); then
            _color_yellow "  [NOTICE] Score stagnation detected ($stagnation_counter rounds)."
            add_blocker_log "$run_dir" "revision-iteration" \
                "Stagnation warning: $stagnation_counter rounds without meaningful score gain"
        fi
    done

    if (( revision_round >= max_rounds )); then
        _color_yellow "[NOTICE] Revision max rounds reached ($revision_round / $max_rounds)"
        add_blocker_log "$run_dir" "revision-iteration" \
            "Revision max rounds exhausted after $revision_round rounds"
    fi

    write_pipeline_state "$run_dir" "$state_json"
    STATE_JSON="$state_json"
}

# ==== MAIN ======================================================================

_color_magenta ""
_color_magenta "===== RND PIPELINE ORCHESTRATOR ====="
_color_white "Topic  : $TOPIC"
_color_white "Slug   : $TOPIC_SLUG"
_color_white "Venue  : $TARGET_VENUE"
_color_white "Budget : $COMPUTE_BUDGET GPU-hours"
[[ "$DRY_RUN" == "true" ]]      && _color_yellow "[MODE]   DRY-RUN"
[[ "$RESUME" == "true" ]]       && _color_yellow "[MODE]   RESUME"
[[ "$AUTO_CONFIRM" == "true" ]] && _color_yellow "[MODE]   AUTO-CONFIRM"
[[ "$STRICT_EXEC" == "true" ]]  && _color_yellow "[MODE]   STRICT-EXEC"

# ---- Resolve (or create) run directory -----------------------------------------
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNS_BASE="$ROOT_DIR/research_runs/$TOPIC_SLUG"

RUN_DIR=""
if [[ "$RESUME" == "true" && -d "$RUNS_BASE" ]]; then
    RUN_DIR=$(ls -1d "$RUNS_BASE"/*/ 2>/dev/null | sort -r | head -1)
    RUN_DIR="${RUN_DIR%/}"  # strip trailing slash
    if [[ -n "$RUN_DIR" ]]; then
        _color_yellow "Resume : $RUN_DIR"
    fi
fi

if [[ -z "$RUN_DIR" ]]; then
    RUN_ID="$(date '+%Y%m%d')_run$(printf '%02d' $((RANDOM % 99 + 1)))"
    RUN_DIR="$RUNS_BASE/$RUN_ID"
    mkdir -p "$RUN_DIR"
    _color_green "New run: $RUN_DIR"
fi

# ---- Initialize state -----------------------------------------------------------
STATE_JSON=$(read_pipeline_state "$RUN_DIR")

if [[ -z "$STATE_JSON" && -f "$RUN_DIR/state.json" ]]; then
    local_backup="$RUN_DIR/state.corrupt.$(date '+%Y%m%d_%H%M%S').json"
    cp "$RUN_DIR/state.json" "$local_backup"
    _color_yellow "  [WARN] Existing state.json could not be parsed. Backed up to: $local_backup"
    if [[ "$STRICT_EXEC" == "true" ]]; then
        add_blocker_log "$RUN_DIR" "bootstrap" "StrictExec: state.json is unreadable"
        echo "[ERROR] StrictExec: unreadable state.json" >&2
        exit 1
    fi
    add_blocker_log "$RUN_DIR" "bootstrap" "state.json unreadable; reinitialized state from defaults"
fi

if [[ -z "$STATE_JSON" ]] || ! echo "$STATE_JSON" | jq empty 2>/dev/null; then
    local run_id_leaf
    run_id_leaf=$(basename "$RUN_DIR")
    STATE_JSON=$(jq -nc \
        --arg rid "$run_id_leaf" \
        --arg slug "$TOPIC_SLUG" \
        --arg topic "$TOPIC" \
        --arg ts "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" \
        '{
            run_id: $rid,
            topic_slug: $slug,
            topic: $topic,
            started_at: $ts,
            phase_status: {},
            best_metric: null,
            iter_round: 0,
            revision_round: 0,
            revision_score_trajectory: [],
            blockers: []
        }')
fi

# ---- Write constraints file (01) -----------------------------------------------
CONSTRAINT_FILE="$RUN_DIR/01_topic_and_constraints.md"
if [[ ! -f "$CONSTRAINT_FILE" ]]; then
    YEAR_RANGE=$(get_json_field "$TASK_JSON" "year_range")
    LANGUAGE=$(get_json_field "$TASK_JSON" "language")
    DEADLINE=$(get_json_field "$TASK_JSON" "deadline")
    SOURCES=$(echo "$TASK_JSON" | jq -r '(.sources // ["arXiv","Semantic Scholar"]) | join(", ")')
    BASELINES=$(echo "$TASK_JSON" | jq -r '(.baseline_repositories // ["unknown"]) | map("- " + .) | join("\n")')

    METHOD_SECTION=""
    if [[ -n "$METHOD_DESC" ]]; then
        METHOD_SECTION=$(printf "\n## Proposed Method\n\n%s\n" "$METHOD_DESC")
    fi

    cat > "$CONSTRAINT_FILE" <<EOF
# 01 Topic and Constraints

**Topic**: $TOPIC
**Slug**: $TOPIC_SLUG
**Year range**: $YEAR_RANGE
**Language**: $LANGUAGE
**Target venue**: $TARGET_VENUE
**Compute budget (GPU-hours)**: $COMPUTE_BUDGET
**Deadline**: $DEADLINE
**Sources**: $SOURCES
$METHOD_SECTION
## Success metric

$SUCCESS_METRIC

## Stopping criteria

- min_delta : $(get_json_field "$TASK_JSON" "min_delta")
- patience  : $(get_json_field "$TASK_JSON" "patience")

## Baseline repositories

$BASELINES
EOF
    _color_green "  [INIT] Created 01_topic_and_constraints.md"
fi
write_pipeline_state "$RUN_DIR" "$STATE_JSON"

# ---- Sequential phases: retrieval and code_intel --------------------------------
for phase_name in retrieval code_intel; do
    existing=$(get_phase_status "$STATE_JSON" "$phase_name")
    if [[ "$RESUME" == "true" && ("$existing" == "done" || "$existing" == "skipped") ]]; then
        _color_gray "[SKIP]  Phase '$phase_name' already: $existing"
        continue
    fi
    status=$(invoke_agent_phase "$phase_name" "$RUN_DIR" "false")
    STATE_JSON=$(set_phase_status "$STATE_JSON" "$phase_name" "$status")
    write_pipeline_state "$RUN_DIR" "$STATE_JSON"
done

# ---- Iteration loop: innovation + experiment -----------------------------------
inn_existing=$(get_phase_status "$STATE_JSON" "innovation")
scf_existing=$(get_phase_status "$STATE_JSON" "scaffold")
exp_existing=$(get_phase_status "$STATE_JSON" "experiment")

if [[ "$RESUME" == "true" ]] && \
   [[ "$inn_existing" == "done" || "$inn_existing" == "skipped" ]] && \
   [[ "$scf_existing" == "done" || "$scf_existing" == "skipped" ]] && \
   [[ "$exp_existing" == "done" || "$exp_existing" == "skipped" || "$exp_existing" == "done_with_errors" ]]; then
    _color_gray "[SKIP]  Iteration loop already complete (innovation=$inn_existing, scaffold=$scf_existing, experiment=$exp_existing)"
else
    invoke_iteration_loop "$RUN_DIR" "$STATE_JSON"
fi

# ---- Result Expectation Gate ---------------------------------------------------
_color_magenta "[INFO]  Running result expectation gate..."
invoke_result_expectation_gate "$RUN_DIR" "$STATE_JSON"

# ---- Writing phase -------------------------------------------------------------
existing=$(get_phase_status "$STATE_JSON" "writing")
if [[ "$RESUME" == "true" && ("$existing" == "done" || "$existing" == "skipped") ]]; then
    _color_gray "[SKIP]  Phase 'writing' already: $existing"
else
    status=$(invoke_agent_phase "writing" "$RUN_DIR" "false")
    STATE_JSON=$(set_phase_status "$STATE_JSON" "writing" "$status")
    write_pipeline_state "$RUN_DIR" "$STATE_JSON"
fi

# ---- Truthfulness Verification Gate --------------------------------------------
_color_magenta "[INFO]  Running truthfulness verification gate..."
invoke_truthfulness_verification "$RUN_DIR" "$STATE_JSON"

# ---- Review phase --------------------------------------------------------------
existing=$(get_phase_status "$STATE_JSON" "review")
if [[ "$RESUME" == "true" && ("$existing" == "done" || "$existing" == "skipped") ]]; then
    _color_gray "[SKIP]  Phase 'review' already: $existing"
else
    status=$(invoke_agent_phase "review" "$RUN_DIR" "false")
    STATE_JSON=$(set_phase_status "$STATE_JSON" "review" "$status")
    write_pipeline_state "$RUN_DIR" "$STATE_JSON"
fi

# ---- Revision Feedback Loop ----------------------------------------------------
ENABLE_REVISION=$(echo "$TASK_JSON" | jq -r '.enable_revision_loop // true')
if [[ "$ENABLE_REVISION" != "false" ]]; then
    _color_magenta "[INFO]  Entering revision iteration loop"
    invoke_revision_iteration_loop "$RUN_DIR" "$STATE_JSON"
else
    _color_gray "[INFO]  Revision loop disabled. Running single final revision phase."
    existing=$(get_phase_status "$STATE_JSON" "revision")
    if [[ "$RESUME" != "true" || ("$existing" != "done" && "$existing" != "skipped") ]]; then
        status=$(invoke_agent_phase "revision" "$RUN_DIR" "false")
        STATE_JSON=$(set_phase_status "$STATE_JSON" "revision" "$status")
        write_pipeline_state "$RUN_DIR" "$STATE_JSON"
    fi
fi

# ---- Summary -------------------------------------------------------------------
write_pipeline_state "$RUN_DIR" "$STATE_JSON"

BLOCKER_LOG="$RUN_DIR/blocker_log.jsonl"
BLOCKER_COUNT=0
if [[ -f "$BLOCKER_LOG" ]]; then
    BLOCKER_COUNT=$(wc -l < "$BLOCKER_LOG")
fi

_color_magenta ""
_color_magenta "===== PIPELINE COMPLETE ====="
_color_white "Run dir     : $RUN_DIR"
_color_white "Best metric : $(echo "$STATE_JSON" | jq -r '.best_metric // "n/a"')"
_color_white "Iterations  : $(echo "$STATE_JSON" | jq -r '.iter_round // 0')"
if (( BLOCKER_COUNT > 0 )); then
    _color_yellow "Blockers    : $BLOCKER_COUNT (see blocker_log.jsonl)"
else
    _color_green "Blockers    : 0"
fi
echo ""

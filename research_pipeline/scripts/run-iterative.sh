#!/usr/bin/env bash
#
# run-iterative.sh — Iterative RND Pipeline (bash port)
#
# Runs targeted iterations on an existing research project.
# Unlike run-pipeline.sh which builds from scratch, this script:
#   - Connects to an existing run directory
#   - Performs gap analysis (audit mode)
#   - Executes only the phases that need updating
#
# Usage:
#   bash research_pipeline/scripts/run-iterative.sh \
#       --task research_pipeline/tasks/my-task.json --mode audit
#
#   bash research_pipeline/scripts/run-iterative.sh \
#       --task research_pipeline/tasks/my-task.json --mode full --auto-confirm

set -uo pipefail

# ---- Argument parsing ----------------------------------------------------------
TASK_FILE=""
MODE=""
RUN_DIR_OVERRIDE=""
AUTO_CONFIRM=false
STRICT_EXEC=false
MAX_RETRIES=3
RETRY_DELAY_SEC=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task|-t)          TASK_FILE="$2";          shift 2 ;;
        --mode|-m)          MODE="$2";               shift 2 ;;
        --run-dir)          RUN_DIR_OVERRIDE="$2";   shift 2 ;;
        --auto-confirm|-a)  AUTO_CONFIRM=true;       shift ;;
        --strict-exec|-s)   STRICT_EXEC=true;        shift ;;
        --max-retries)      MAX_RETRIES="$2";        shift 2 ;;
        --retry-delay)      RETRY_DELAY_SEC="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $0 --task <task.json> [--mode audit|experiment|paper|review|revision|full] [--run-dir <path>] [--auto-confirm] [--strict-exec]"
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
if ! echo "$TASK_JSON" | jq empty 2>/dev/null; then
    echo "[ERROR] Invalid JSON in task file: $TASK_FILE" >&2
    exit 1
fi

TOPIC=$(get_json_field "$TASK_JSON" "topic")
TOPIC_SLUG=$(get_json_field "$TASK_JSON" "topic_slug")

# ---- Resolve iteration config --------------------------------------------------
ITER_MODE="$MODE"
if [[ -z "$ITER_MODE" ]]; then
    ITER_MODE=$(echo "$TASK_JSON" | jq -r '.iteration.mode // "audit"')
fi

# Validate mode
case "$ITER_MODE" in
    audit|experiment|paper|review|revision|full) ;;
    *) echo "[ERROR] Invalid mode: $ITER_MODE" >&2; exit 1 ;;
esac

# ---- Resolve run directory -----------------------------------------------------
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNS_BASE="$ROOT_DIR/research_runs/$TOPIC_SLUG"

RUN_DIR=""
if [[ -n "$RUN_DIR_OVERRIDE" ]]; then
    RUN_DIR="$RUN_DIR_OVERRIDE"
elif iter_run_dir=$(echo "$TASK_JSON" | jq -r '.iteration.run_dir // empty') && [[ -n "$iter_run_dir" ]]; then
    RUN_DIR="$iter_run_dir"
elif [[ -d "$RUNS_BASE" ]]; then
    RUN_DIR=$(ls -1d "$RUNS_BASE"/*/ 2>/dev/null | sort -r | head -1)
    RUN_DIR="${RUN_DIR%/}"
fi

if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
    echo "[ERROR] No run directory found for topic '$TOPIC_SLUG'. Run the full pipeline first." >&2
    exit 1
fi

# ---- Load state ----------------------------------------------------------------
STATE_JSON=$(read_pipeline_state "$RUN_DIR")
if [[ -z "$STATE_JSON" ]] || ! echo "$STATE_JSON" | jq empty 2>/dev/null; then
    echo "[ERROR] No valid state.json found in $RUN_DIR" >&2
    exit 1
fi

# ---- Banner --------------------------------------------------------------------
_color_magenta ""
_color_magenta "===== ITERATIVE RND PIPELINE ====="
_color_white "Topic    : $TOPIC"
_color_white "Run dir  : $RUN_DIR"
_color_cyan  "Mode     : $ITER_MODE"
_color_white "Metric   : $(echo "$STATE_JSON" | jq -r '.best_metric // "n/a"')"
_color_white "Rev round: $(echo "$STATE_JSON" | jq -r '.revision_round // 0')"
[[ "$STRICT_EXEC" == "true" ]]  && _color_yellow "[MODE]   STRICT-EXEC"
[[ "$AUTO_CONFIRM" == "true" ]] && _color_yellow "[MODE]   AUTO-CONFIRM"

# We need these globals for agent/experiment phases that reference them
RESUME=false  # iterative mode doesn't use resume semantics
DRY_RUN=false

# Phase catalogue (same as run-pipeline.sh but needed for phase functions)
PHASE_NAMES=(retrieval code_intel innovation scaffold experiment writing review revision)
PHASE_AGENTS=(PAPER_SCOUT CODE_SCOUT INNOVATION_DESIGNER EXPERIMENT_ENGINEER EXPERIMENT_ENGINEER WRITING_AGENT REVIEWER_AGENT REVIEWER_AGENT)
PHASE_OUTPUTS=(02_sota_evidence_table.md 03_open_source_landscape.md 05_feasibility_matrix.md 07_implementation_log.md 09_experiment_results.md 11_paper_draft.md 12_review_report.md 13_revision_plan.md)
PHASE_GROUPS=(A A B C C D E F)
PHASE_HAS_COMMANDS=(false false false false true false false false)
PHASE_INPUTS=(
    "01_topic_and_constraints.md"
    "01_topic_and_constraints.md"
    "02_sota_evidence_table.md 03_open_source_landscape.md"
    "04_innovation_hypotheses.md 05_feasibility_matrix.md 06_experiment_plan.md"
    "04_innovation_hypotheses.md 05_feasibility_matrix.md 06_experiment_plan.md"
    "02_sota_evidence_table.md 09_experiment_results.md 10_iteration_decisions.md"
    "11_paper_draft.md"
    "12_review_report.md"
)

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

# Source same invoke functions — need to re-source for phase functions
# (They are already available from pipeline-helpers.sh and the function definitions
#  from run-pipeline.sh are not available here, so we define simplified versions.)

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

    for inp in $inputs; do
        assert_input_file "$run_dir" "$inp" "$phase_name" "$STRICT_EXEC" || {
            if [[ "$STRICT_EXEC" == "true" ]]; then exit 1; fi
        }
    done

    if [[ "$force_run" != "true" && -f "$out_path" ]]; then
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
                add_blocker_log "$run_dir" "$phase_name" "StrictExec: forced rerun cannot use auto-refresh"
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
            echo "[ERROR] StrictExec blocked manual skip" >&2
            exit 1
        fi
        write_stub_output "$run_dir" "$output_file" "$phase_name" "User explicitly skipped this phase"
        add_blocker_log "$run_dir" "$phase_name" "User skipped"
        echo "skipped_stub"
        return 0
    fi

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

# ---- Audit Mode ----------------------------------------------------------------
invoke_audit_mode() {
    local run_dir="$1"

    _color_cyan ""
    _color_cyan "===== AUDIT MODE ====="

    local audit_path="$run_dir/iteration_audit.md"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "# Iteration Audit Report"
        echo ""
        echo "**Generated**: $now"
        echo "**Run directory**: $run_dir"
        echo ""

        # Phase status
        echo "## 1. Phase Status"
        echo ""
        echo "| Phase | Status |"
        echo "|---|---|"
        for key in $(echo "$STATE_JSON" | jq -r '.phase_status | keys[]' 2>/dev/null); do
            val=$(echo "$STATE_JSON" | jq -r ".phase_status[\"$key\"]")
            echo "| $key | $val |"
        done
        echo ""

        # Artifact inventory
        echo "## 2. Artifact Inventory"
        echo ""
        echo "### Core Files"
        echo ""
        echo "| File | Exists | Size |"
        echo "|---|---|---|"
        local core_files=(
            01_topic_and_constraints.md 02_sota_evidence_table.md
            03_open_source_landscape.md 04_innovation_hypotheses.md
            05_feasibility_matrix.md 06_experiment_plan.md
            07_implementation_log.md 08_debug_log.md
            09_experiment_results.md 10_iteration_decisions.md
            11_paper_draft.md 12_review_report.md 13_revision_plan.md
        )
        for f in "${core_files[@]}"; do
            local fp="$run_dir/$f"
            if [[ -f "$fp" ]]; then
                local sz
                sz=$(stat -c '%s' "$fp" 2>/dev/null || stat -f '%z' "$fp" 2>/dev/null || echo "?")
                echo "| $f | ✅ | $sz bytes |"
            else
                echo "| $f | ❌ | — |"
            fi
        done
        echo ""

        # Paper draft versions
        local drafts
        drafts=$(ls -1 "$run_dir"/paper_draft_v*.md 2>/dev/null | sort -r)
        if [[ -n "$drafts" ]]; then
            echo "### Paper Draft Versions"
            echo ""
            while IFS= read -r pd; do
                local name
                name=$(basename "$pd")
                local sz
                sz=$(stat -c '%s' "$pd" 2>/dev/null || stat -f '%z' "$pd" 2>/dev/null || echo "?")
                echo "- $name ($sz bytes)"
            done <<< "$drafts"
            echo ""
        fi

        # Result files
        if [[ -d "$run_dir/results" ]]; then
            local result_files
            result_files=$(ls -1 "$run_dir/results/"*.json 2>/dev/null | sort)
            if [[ -n "$result_files" ]]; then
                echo "### Result Files"
                echo ""
                while IFS= read -r rf; do
                    local name
                    name=$(basename "$rf")
                    local sz
                    sz=$(stat -c '%s' "$rf" 2>/dev/null || stat -f '%z' "$rf" 2>/dev/null || echo "?")
                    echo "- results/$name ($sz bytes)"
                done <<< "$result_files"
                echo ""
            fi
        fi

        # Experiment scripts
        if [[ -d "$run_dir/experiments" ]]; then
            local scripts
            scripts=$(ls -1 "$run_dir/experiments/"*.py 2>/dev/null | sort)
            if [[ -n "$scripts" ]]; then
                echo "### Experiment Scripts"
                echo ""
                while IFS= read -r sc; do
                    echo "- experiments/$(basename "$sc")"
                done <<< "$scripts"
                echo ""
            fi
        fi

        # Metrics
        echo "## 3. Metrics Summary"
        echo ""
        echo "- **Best metric**: $(echo "$STATE_JSON" | jq -r '.best_metric // "n/a"')"
        echo "- **Iteration rounds**: $(echo "$STATE_JSON" | jq -r '.iter_round // 0')"
        echo "- **Revision rounds**: $(echo "$STATE_JSON" | jq -r '.revision_round // 0')"
        local traj
        traj=$(echo "$STATE_JSON" | jq -r '.revision_score_trajectory // [] | join(" → ")')
        if [[ -n "$traj" ]]; then
            echo "- **Score trajectory**: $traj"
        fi
        echo ""

        # Blocker log
        if [[ -f "$run_dir/blocker_log.jsonl" ]]; then
            local count
            count=$(wc -l < "$run_dir/blocker_log.jsonl")
            echo "## 4. Blocker Log Summary"
            echo ""
            echo "Total entries: $count"
            echo ""
            echo "### Last 5 Entries"
            echo ""
            tail -5 "$run_dir/blocker_log.jsonl" | while IFS= read -r b; do
                echo "- \`$b\`"
            done
            echo ""
        fi

        # Suggested actions
        echo "## 5. Suggested Next Actions"
        echo ""
        echo "1. Run \`@ITERATIVE_RND\` with \`mode: experiment\` to fill any experiment gaps"
        echo "2. Run \`@ITERATIVE_RND\` with \`mode: paper\` to update the paper with latest results"
        echo "3. Run \`@ITERATIVE_RND\` with \`mode: review\` to get a fresh review"
        echo "4. Run \`@ITERATIVE_RND\` with \`mode: full\` for a complete iteration cycle"
        echo ""
    } > "$audit_path"

    _color_green "  [OK] Audit written to: iteration_audit.md"
}

# ---- Experiment Mode -----------------------------------------------------------
invoke_iterative_experiment_mode() {
    local run_dir="$1"

    _color_cyan ""
    _color_cyan "===== EXPERIMENT MODE ====="

    local -a gaps=()
    while IFS= read -r g; do
        [[ -n "$g" ]] && gaps+=("$g")
    done < <(echo "$TASK_JSON" | jq -r '.iteration.experiment_gaps[]? // empty')

    if [[ ${#gaps[@]} -eq 0 ]]; then
        _color_yellow "  [INFO] No specific experiment gaps specified in task file."
        _color_white "  [ACTION] Open Copilot Chat and run: @ITERATIVE_RND"
        _color_gray "           Describe the experiments to fill."
    else
        _color_white "  Experiment gaps to fill:"
        for g in "${gaps[@]}"; do
            _color_white "    - $g"
        done
    fi

    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        echo -n "  Press [Enter] when experiments are complete, or type 'skip': "
        read -r answer
        if [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]' | xargs)" == "skip" ]]; then
            echo "skipped"
            return 0
        fi
    else
        _color_gray "  [AUTO] Delegating to EXPERIMENT_ENGINEER via Copilot Chat."
    fi

    _color_green "  [OK] Experiment mode complete."
    echo "done"
}

# ---- Paper Mode ----------------------------------------------------------------
invoke_iterative_paper_mode() {
    local run_dir="$1"

    _color_cyan ""
    _color_cyan "===== PAPER MODE ====="

    # Find latest draft version
    local latest_draft="11_paper_draft.md"
    local drafts
    drafts=$(ls -1 "$run_dir"/paper_draft_v*.md 2>/dev/null | sort -r | head -1)
    if [[ -n "$drafts" ]]; then
        latest_draft=$(basename "$drafts")
    fi
    _color_white "  Latest draft: $latest_draft"

    # Determine next version
    local next_draft="paper_draft_v1.md"
    if [[ "$latest_draft" =~ v([0-9]+) ]]; then
        local next_ver=$(( ${BASH_REMATCH[1]} + 1 ))
        next_draft="paper_draft_v${next_ver}.md"
    fi

    _color_white "  Next version: $next_draft"
    _color_white "  [ACTION] Open Copilot Chat and run: @WRITING_AGENT"
    _color_white "  [INPUT]  Update $latest_draft with new results. Save as $next_draft"

    # Show focus sections if specified
    local sections
    sections=$(echo "$TASK_JSON" | jq -r '.iteration.paper_sections[]? // empty' 2>/dev/null)
    if [[ -n "$sections" ]]; then
        _color_white "  [FOCUS]  Sections to update:"
        while IFS= read -r s; do
            _color_white "           - $s"
        done <<< "$sections"
    fi

    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        echo -n "  Press [Enter] when paper is updated, or type 'skip': "
        read -r answer
        if [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]' | xargs)" == "skip" ]]; then
            echo "skipped"
            return 0
        fi
    fi

    _color_green "  [OK] Paper mode complete."
    echo "done"
}

# ---- Review Mode ---------------------------------------------------------------
invoke_iterative_review_mode() {
    local run_dir="$1"

    _color_cyan ""
    _color_cyan "===== REVIEW MODE ====="

    local review_count
    review_count=$(ls -1 "$run_dir"/*review_report*.md 2>/dev/null | wc -l)
    local next_num=$((review_count + 1))
    local review_file="review_report_iter${next_num}.md"
    local plan_file="revision_plan_iter${next_num}.md"

    _color_white "  Next review: $review_file"
    _color_white "  [ACTION] Open Copilot Chat and run: @REVIEWER_AGENT"
    _color_white "  [INPUT]  Review latest paper draft. Save as $review_file"

    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        echo -n "  Press [Enter] when review is done, or type 'skip': "
        read -r answer
        if [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]' | xargs)" == "skip" ]]; then
            echo "skipped"
            return 0
        fi
    fi

    # Try to parse review score
    local review_path="$run_dir/$review_file"
    if [[ -f "$review_path" ]]; then
        local new_score
        new_score=$(grep -oiP '##\s*Overall\s*Score[:\s]*\K[0-9]+\.?[0-9]*(?=\s*/\s*100)' "$review_path" 2>/dev/null | head -1)
        if [[ -n "$new_score" ]]; then
            _color_green "  New review score: $new_score / 100"
            STATE_JSON=$(echo "$STATE_JSON" | jq --argjson s "$new_score" '.revision_score_trajectory += [$s]')
            write_pipeline_state "$run_dir" "$STATE_JSON"
        fi
    fi

    _color_green "  [OK] Review mode complete."
    echo "done"
}

# ---- Main dispatch -------------------------------------------------------------
echo ""

# Update state with iteration info
STATE_JSON=$(echo "$STATE_JSON" | jq \
    --arg mode "$ITER_MODE" \
    --arg ts "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" \
    '.iteration_mode = $mode | .last_action_timestamp = $ts')
write_pipeline_state "$RUN_DIR" "$STATE_JSON"

case "$ITER_MODE" in
    audit)
        invoke_audit_mode "$RUN_DIR"
        ;;
    experiment)
        invoke_audit_mode "$RUN_DIR"
        invoke_iterative_experiment_mode "$RUN_DIR"
        ;;
    paper)
        invoke_iterative_paper_mode "$RUN_DIR"
        ;;
    review)
        invoke_iterative_review_mode "$RUN_DIR"
        ;;
    revision)
        invoke_audit_mode "$RUN_DIR"
        invoke_iterative_experiment_mode "$RUN_DIR"
        invoke_iterative_paper_mode "$RUN_DIR"
        invoke_iterative_review_mode "$RUN_DIR"
        ;;
    full)
        local_skip=()
        while IFS= read -r sp; do
            [[ -n "$sp" ]] && local_skip+=("$sp")
        done < <(echo "$TASK_JSON" | jq -r '.iteration.skip_phases[]? // empty')

        invoke_audit_mode "$RUN_DIR"

        skip_experiment=false
        skip_paper=false
        skip_review=false
        for s in "${local_skip[@]:-}"; do
            case "$s" in
                experiment) skip_experiment=true ;;
                paper)      skip_paper=true ;;
                review)     skip_review=true ;;
            esac
        done

        [[ "$skip_experiment" != "true" ]] && invoke_iterative_experiment_mode "$RUN_DIR"
        [[ "$skip_paper" != "true" ]]      && invoke_iterative_paper_mode "$RUN_DIR"
        [[ "$skip_review" != "true" ]]     && invoke_iterative_review_mode "$RUN_DIR"
        ;;
esac

# ---- Summary -------------------------------------------------------------------
BLOCKER_LOG="$RUN_DIR/blocker_log.jsonl"
BLOCKER_COUNT=0
if [[ -f "$BLOCKER_LOG" ]]; then
    BLOCKER_COUNT=$(wc -l < "$BLOCKER_LOG")
fi

_color_magenta ""
_color_magenta "===== ITERATIVE PIPELINE COMPLETE ====="
_color_white "Run dir     : $RUN_DIR"
_color_white "Mode        : $ITER_MODE"
_color_white "Best metric : $(echo "$STATE_JSON" | jq -r '.best_metric // "n/a"')"
_color_white "Rev round   : $(echo "$STATE_JSON" | jq -r '.revision_round // 0')"
local_traj=$(echo "$STATE_JSON" | jq -r '.revision_score_trajectory // [] | join(" -> ")')
if [[ -n "$local_traj" ]]; then
    _color_white "Score path  : $local_traj"
fi
if (( BLOCKER_COUNT > 0 )); then
    _color_yellow "Blockers    : $BLOCKER_COUNT (see blocker_log.jsonl)"
else
    _color_green "Blockers    : 0"
fi
echo ""

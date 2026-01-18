#!/bin/bash

# Ralph Autonomous Development Loop - Copilot CLI Version
# Works with GitHub Copilot CLI using plain text output and --continue for session persistence

set -e

# Ensure we have a complete PATH for finding copilot and other tools
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/response_analyzer.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"

# Configuration
PROMPT_FILE="PROMPT.md"
LOG_DIR="logs"
DOCS_DIR="docs/generated"
STATUS_FILE="status.json"
PROGRESS_FILE="progress.json"
MAIN_LOG_FILE="$LOG_DIR/ralph.log"
SESSION_LOG_FILE="$LOG_DIR/session-$(date '+%Y-%m-%d_%H-%M-%S').log"

# Read the selected CLI tool from config
CLI_CONFIG="$RALPH_HOME/cli_config"
if [ -f "$CLI_CONFIG" ]; then
    CLI_TOOL=$(cat "$CLI_CONFIG")
else
    CLI_TOOL="copilot"  # Default fallback
fi

# Map CLI tool to command
case "$CLI_TOOL" in
    "copilot")
        CLI_CODE_CMD="copilot"
        ;;
    "claude")
        CLI_CODE_CMD="claude"
        ;;
    *)
        CLI_CODE_CMD="copilot"
        ;;
esac

# Copilot CLI specific settings
COPILOT_TOOLS="write,read,shell(git *)"  # Tools allowed for Copilot
USE_CONTINUE=true                        # Enable session continuity with --continue
MAX_CALLS_PER_HOUR=100
TIMEOUT_MINUTES=15
VERBOSE_PROGRESS=false
SLEEP_DURATION=3600
CALL_COUNT_FILE=".call_count"
TIMESTAMP_FILE=".last_reset"

# Exit detection configuration
EXIT_SIGNALS_FILE=".exit_signals"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# Logging function
log_status() {
    local level=$1
    local message=$2
    local color=""
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP")  color=$PURPLE ;;
    esac
    
    # Output to terminal with color
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
    
    # Append to main log file (without color codes)
    echo "[$timestamp] [$level] $message" >> "$MAIN_LOG_FILE"
    
    # Also append to session log
    echo "[$timestamp] [$level] $message" >> "$SESSION_LOG_FILE"
}

# Build loop context with project status
build_loop_context() {
    local loop_count=$1
    local context="=== LOOP CONTEXT ==="$'\n'
    context+="Loop: $loop_count"$'\n'
    
    # Add remaining tasks from @fix_plan.md
    if [ -f "@fix_plan.md" ]; then
        local remaining=$(grep -c "^- \[ \]" "@fix_plan.md" 2>/dev/null || echo "0")
        context+="Remaining tasks: $remaining"$'\n'
    fi
    
    # Add previous response summary if it exists
    if [ -f ".response_analysis" ]; then
        context+="Previous work summary:"$'\n'
        head -20 ".response_analysis" | sed 's/^/  /' >> "$context"
    fi
    
    # Add circuit breaker state
    if [ -f ".circuit_breaker_state" ]; then
        local cb_state=$(cat ".circuit_breaker_state" 2>/dev/null || echo "HEALTHY")
        context+="Circuit breaker: $cb_state"$'\n'
    fi
    
    context+="=== END CONTEXT ==="
    echo "$context"
}

# Check if can make API call (rate limiting)
can_make_call() {
    local timestamp_file="$TIMESTAMP_FILE"
    local call_count_file="$CALL_COUNT_FILE"
    
    # Initialize files if they don't exist
    if [[ ! -f "$timestamp_file" ]]; then
        date +%s > "$timestamp_file"
        echo "0" > "$call_count_file"
        return 0
    fi
    
    local last_reset=$(cat "$timestamp_file")
    local current_time=$(date +%s)
    local time_passed=$((current_time - last_reset))
    local hour_seconds=3600
    
    # Reset counter if an hour has passed
    if [[ $time_passed -ge $hour_seconds ]]; then
        date +%s > "$timestamp_file"
        echo "0" > "$call_count_file"
        return 0
    fi
    
    # Check call count
    local calls=$(cat "$call_count_file" 2>/dev/null || echo "0")
    if [[ $calls -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1
    fi
    
    return 0
}

# Increment call counter
increment_call_counter() {
    local current=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    echo $((current + 1)) > "$CALL_COUNT_FILE"
}

# Wait for rate limit reset
wait_for_reset() {
    log_status "WARN" "Rate limit reached. Waiting for hourly reset..."
    local last_reset=$(cat "$TIMESTAMP_FILE" 2>/dev/null || date +%s)
    local current_time=$(date +%s)
    local wait_seconds=$((3600 - (current_time - last_reset)))
    
    if [[ $wait_seconds -gt 0 ]]; then
        log_status "INFO" "Waiting $((wait_seconds / 60)) minutes..."
        sleep $wait_seconds
    fi
}

# Check if should exit gracefully
should_exit_gracefully() {
    local loop_count=$1
    
    # Exit condition 1: Manual exit signal file
    if [[ -f ".exit_ralph" ]]; then
        echo "manual_exit_signal"
        return 0
    fi
    
    # Exit condition 2: Detect completion keywords in last response (HIGH PRIORITY)
    if [[ -f ".response_analysis" ]]; then
        if grep -qi "successfully completed\|100% complete\|sprint.*complete\|all.*features.*complete\|ready for production\|ready for deployment\|no.*remaining.*task\|sprint.*done" ".response_analysis" 2>/dev/null; then
            log_status "INFO" "✅ Completion confirmation detected in output"
            echo "copilot_completion_detected"
            return 0
        fi
    fi
    
    # Exit condition 3: No changes for N consecutive loops
    local no_change_threshold=2
    local no_change_count=0
    
    if [[ -f ".no_change_count" ]]; then
        no_change_count=$(cat ".no_change_count")
    fi
    
    # Check if current loop had no changes
    if [[ -f ".last_loop_files_changed" ]]; then
        local last_files=$(cat ".last_loop_files_changed")
        if [[ $last_files -eq 0 ]]; then
            ((no_change_count++))
            echo "$no_change_count" > ".no_change_count"
            log_status "INFO" "No changes detected (count: $no_change_count/$no_change_threshold)"
            
            if [[ $no_change_count -ge $no_change_threshold ]]; then
                echo "no_changes_consecutive_${no_change_threshold}_loops"
                return 0
            fi
        else
            # Reset counter on change
            echo "0" > ".no_change_count"
        fi
    fi
    
    # Exit condition 4: @fix_plan.md has all items done
    if [[ -f "@fix_plan.md" ]]; then
        local total=$(grep -c "^- \[" "@fix_plan.md" 2>/dev/null || echo "0")
        local incomplete=$(grep -c "^- \[ \]" "@fix_plan.md" 2>/dev/null || echo "0")
        
        if [[ $total -gt 0 && $incomplete -eq 0 ]]; then
            log_status "INFO" "✅ All fix_plan.md items completed"
            echo "all_tasks_in_fix_plan_completed"
            return 0
        fi
    fi
    
    # Exit condition 5: Time limit (max runtime in hours)
    local max_runtime_hours=3
    if [[ -f ".start_time" ]]; then
        local start_time=$(cat ".start_time")
        local current_time=$(date +%s)
        local runtime_seconds=$((current_time - start_time))
        local max_runtime_seconds=$((max_runtime_hours * 3600))
        
        if [[ $runtime_seconds -ge $max_runtime_seconds ]]; then
            echo "max_runtime_exceeded_${max_runtime_hours}h"
            return 0
        fi
    fi
    
    # Exit condition 6: Max loops reached (safety limit)
    local max_loops=15
    if [[ $loop_count -ge $max_loops ]]; then
        log_status "WARN" "Max loop limit reached"
        echo "max_loops_reached_${max_loops}"
        return 0
    fi
    
    return 1
}

# Update status file
update_status() {
    local loop_num=$1
    local calls_made=$2
    local status=$3
    local overall=$4
    local reason=${5:-""}
    
    cat > "$STATUS_FILE" << EOF
{
    "loop": $loop_num,
    "calls_made": $calls_made,
    "status": "$status",
    "overall_status": "$overall",
    "reason": "$reason",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
}

# Log loop progress to progress file
log_loop_progress() {
    local loop_num=$1
    local files_changed=$2
    local status=$3
    local notes=$4
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Initialize progress file if it doesn't exist
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        echo "{\"loops\": [], \"summary\": {}}" > "$PROGRESS_FILE"
    fi
    
    # Append loop entry using jq if available, otherwise use simple format
    if command -v jq &>/dev/null; then
        local temp=$(mktemp)
        jq ".loops += [{\"loop\": $loop_num, \"timestamp\": \"$timestamp\", \"files_changed\": $files_changed, \"status\": \"$status\", \"notes\": \"$notes\"}]" "$PROGRESS_FILE" > "$temp"
        mv "$temp" "$PROGRESS_FILE"
    else
        # Fallback: append to text log
        echo "Loop $loop_num | $timestamp | Files: $files_changed | Status: $status | Notes: $notes" >> "$LOG_DIR/progress.txt"
    fi
}

# Execute Copilot CLI
execute_cli_code() {
    local loop_count=$1
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/copilot_output_${timestamp}.log"
    local timeout_seconds=$((TIMEOUT_MINUTES * 60))
    
    # Build loop context
    local loop_context=$(build_loop_context "$loop_count")
    
    # Check rate limit
    if ! can_make_call; then
        log_status "WARN" "Rate limit reached"
        wait_for_reset
        return 1
    fi
    
    # Build full prompt
    local full_prompt="$loop_context"$'\n\n'"$(cat "$PROMPT_FILE")"
    
    log_status "INFO" "Executing Copilot CLI (loop $loop_count)..."
    
    # For first loop, use -p to start with initial prompt
    # For subsequent loops, use --continue to maintain session context
    if [[ $loop_count -eq 1 ]]; then
        # First loop: start new session with full prompt
        if copilot \
            -p "$full_prompt" \
            --allow-all-tools \
            --silent < /dev/null > "$output_file" 2>&1
        then
            log_status "SUCCESS" "✅ Copilot execution completed"
            increment_call_counter
            
            # Save response for analysis
            cp "$output_file" ".response_analysis"
            
            # Check git for changes
            local files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo "0")
            if [[ $files_changed -gt 0 ]]; then
                log_status "INFO" "✓ $files_changed files modified"
                git add -A && git commit -m "Loop $loop_count: Autonomous development progress" || true
                log_loop_progress "$loop_count" "$files_changed" "success" "Initial implementation"
                return 0
            else
                log_status "WARN" "No files changed in this loop"
                log_loop_progress "$loop_count" "0" "no_changes" "No files modified"
                return 0
            fi
        else
            log_status "ERROR" "❌ Copilot execution failed (exit code: $?)"
            log_loop_progress "$loop_count" "0" "failed" "Copilot execution error"
            return 1
        fi
    else
        # Subsequent loops: continue session and send next instruction
        if copilot \
            -i "$full_prompt" \
            --allow-all-tools \
            --continue \
            --silent < /dev/null > "$output_file" 2>&1
        then
            log_status "SUCCESS" "✅ Copilot execution completed"
            increment_call_counter
            
            # Save response for analysis
            cp "$output_file" ".response_analysis"
            
            # Check git for changes
            local files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo "0")
            if [[ $files_changed -gt 0 ]]; then
                log_status "INFO" "✓ $files_changed files modified"
                git add -A && git commit -m "Loop $loop_count: Autonomous development progress" || true
                log_loop_progress "$loop_count" "$files_changed" "success" "Continued implementation"
                return 0
            else
                log_status "WARN" "No files changed in this loop"
                log_loop_progress "$loop_count" "0" "no_changes" "No files modified"
                return 0
            fi
        else
            log_status "ERROR" "❌ Copilot execution failed (exit code: $?)"
            log_loop_progress "$loop_count" "0" "failed" "Copilot execution error"
            return 1
        fi
    fi
}

# Main loop
main() {
    log_status "INFO" "🚀 Starting Ralph autonomous development loop"
    log_status "INFO" "CLI tool: $CLI_TOOL"
    log_status "INFO" "Project PROMPT: $PROMPT_FILE"
    
    # Validate PROMPT file exists
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "PROMPT.md not found in current directory"
        exit 1
    fi
    
    local loop_count=0
    local max_loops=100  # Safety limit
    
    # Initialize start time
    date +%s > ".start_time"
    echo "0" > ".no_change_count"
    
    while [[ $loop_count -lt $max_loops ]]; do
        loop_count=$((loop_count + 1))
        
        log_status "LOOP" "═════════════════════════════"
        log_status "LOOP" "Starting Loop #$loop_count"
        log_status "LOOP" "═════════════════════════════"
        
        # Check for graceful exit
        local exit_reason=$(should_exit_gracefully "$loop_count")
        if [[ -n "$exit_reason" ]]; then
            log_status "SUCCESS" "🏁 Exit condition met: $exit_reason"
            log_loop_progress "$loop_count" "0" "exit" "Project completed: $exit_reason"
            log_status "SUCCESS" "✅ Ralph loop completed!"
            log_status "INFO" "Total loops: $loop_count"
            log_status "INFO" "Calls made: $(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")"
            log_status "INFO" "Main log: $MAIN_LOG_FILE"
            log_status "INFO" "Session log: $SESSION_LOG_FILE"
            log_status "INFO" "Progress file: $PROGRESS_FILE"
            break
        fi
        
        # Execute Copilot
        execute_cli_code "$loop_count"
        local exec_result=$?
        
        # Track files changed for exit condition checking
        local files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo "0")
        echo "$files_changed" > ".last_loop_files_changed"
        
        if [[ $exec_result -eq 0 ]]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "success" "running"
            
            # Brief pause between loops
            timeout 10 sleep 3 2>/dev/null || true
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "failed" "running"
            
            # Wait longer on failure
            timeout 30 sleep 10 2>/dev/null || true
        fi
    done
    
    # Log final status
    log_status "SUCCESS" "✅ Ralph loop completed!"
    log_status "INFO" "Total loops: $loop_count"
    log_status "INFO" "Calls made: $(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")"
    log_status "INFO" "Main log: $MAIN_LOG_FILE"
    log_status "INFO" "Session log: $SESSION_LOG_FILE"
    log_status "INFO" "Progress file: $PROGRESS_FILE"
}

# Show help
show_help() {
    cat << EOF
Ralph Autonomous Development Loop - Copilot CLI Version

Usage: ralph [OPTIONS]

Options:
  --monitor          Launch with integrated tmux monitoring
  --prompt FILE      Use custom PROMPT.md file (default: PROMPT.md)
  --help, -h         Show this help message
  --reset-circuit    Reset the circuit breaker
  --quiet            Suppress verbose output
  
Examples:
  ralph                                              # Start autonomous loop
  ralph --monitor                                    # Start with monitoring dashboard
  ralph --prompt Development/Sprints/Jan1c/PROMPT.md # Use custom prompt file
  ralph --reset-circuit                              # Reset circuit breaker after issues

EOF
}

# Handle arguments
USE_MONITOR=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --monitor)
            USE_MONITOR=true
            shift
            ;;
        --prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        --reset-circuit)
            rm -f ".circuit_breaker_state"
            log_status "SUCCESS" "Circuit breaker reset"
            exit 0
            ;;
        --quiet)
            VERBOSE_PROGRESS=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Start main function with or without monitor
if [[ "$USE_MONITOR" == "true" ]]; then
    if command -v tmux &>/dev/null; then
        tmux new-session -d -s ralph-dev "bash -c 'source ~/.ralph/ralph_monitor.sh; main'"
        main
    else
        log_status "WARN" "tmux not found, running without monitor"
        main
    fi
else
    main
fi

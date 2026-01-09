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
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP")  color=$PURPLE ;;
    esac
    
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
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
    # Check if @fix_plan.md has all items done
    if [ -f "@fix_plan.md" ]; then
        local incomplete=$(grep -c "^- \[ \]" "@fix_plan.md" 2>/dev/null || echo "1")
        if [[ $incomplete -eq 0 ]]; then
            echo "all_tasks_completed"
            return 0
        fi
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
    
    # Execute Copilot with proper flags (macOS compatible - no timeout command)
    if copilot \
        -p "$full_prompt" \
        --allow-tool write \
        --allow-tool read \
        --allow-tool "shell(git *)" \
        --continue \
        --silent > "$output_file" 2>&1
    then
        log_status "SUCCESS" "✅ Copilot execution completed"
        increment_call_counter
        
        # Save response for analysis
        cp "$output_file" ".response_analysis"
        
        # Detect completion from output (be specific - only "Project done" or "all done", not "Loop COMPLETE")
        if grep -qi "project.*done\|all.*done\|project.*complete.*finished\|ready for production" "$output_file" 2>/dev/null; then
            log_status "INFO" "Project completion detected"
            return 0
        fi
        
        # Check git for changes
        local files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo "0")
        if [[ $files_changed -gt 0 ]]; then
            log_status "INFO" "✓ $files_changed files modified"
            git add -A && git commit -m "Loop $loop_count: Autonomous development progress" || true
            return 0
        else
            log_status "WARN" "No files changed in this loop"
            return 0
        fi
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_status "ERROR" "❌ Copilot execution timed out"
        else
            log_status "ERROR" "❌ Copilot execution failed (exit code: $exit_code)"
        fi
        return 1
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
    
    while [[ $loop_count -lt $max_loops ]]; do
        loop_count=$((loop_count + 1))
        
        log_status "LOOP" "═════════════════════════════"
        log_status "LOOP" "Starting Loop #$loop_count"
        log_status "LOOP" "═════════════════════════════"
        
        # Check for graceful exit
        local exit_reason=$(should_exit_gracefully)
        if [[ -n "$exit_reason" ]]; then
            log_status "SUCCESS" "🏁 Exit condition met: $exit_reason"
            break
        fi
        
        # Execute Copilot
        execute_cli_code "$loop_count"
        local exec_result=$?
        
        if [[ $exec_result -eq 0 ]]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "success" "running"
            
            # Brief pause between loops
            sleep 3
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "failed" "running"
            
            # Wait longer on failure
            sleep 10
        fi
    done
    
    log_status "SUCCESS" "✅ Ralph loop completed!"
    log_status "INFO" "Total loops: $loop_count"
    log_status "INFO" "Calls made: $(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")"
}

# Show help
show_help() {
    cat << EOF
Ralph Autonomous Development Loop - Copilot CLI Version

Usage: ralph [OPTIONS]

Options:
  --monitor          Launch with integrated tmux monitoring
  --help, -h         Show this help message
  --reset-circuit    Reset the circuit breaker
  --quiet            Suppress verbose output
  
Examples:
  ralph                    # Start autonomous loop
  ralph --monitor          # Start with monitoring dashboard
  ralph --reset-circuit    # Reset circuit breaker after issues

EOF
}

# Handle arguments
case "${1:-}" in
    --monitor)
        # Start with monitor
        if command -v tmux &>/dev/null; then
            tmux new-session -d -s ralph-dev "bash -c 'source ~/.ralph/ralph_monitor.sh; main'"
            main
        else
            log_status "WARN" "tmux not found, running without monitor"
            main
        fi
        ;;
    --help|-h)
        show_help
        ;;
    --reset-circuit)
        rm -f ".circuit_breaker_state"
        log_status "SUCCESS" "Circuit breaker reset"
        ;;
    --quiet)
        VERBOSE_PROGRESS=false
        main
        ;;
    *)
        main
        ;;
esac

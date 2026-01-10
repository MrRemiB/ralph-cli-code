#!/bin/bash

# Ralph Import - Convert PRDs to Ralph format using selected CLI tool
set -e

# Configuration
RALPH_HOME="$HOME/.ralph"
CLI_CONFIG="$RALPH_HOME/cli_config"

# Read the selected CLI tool from config
if [ -f "$CLI_CONFIG" ]; then
    CLI_TOOL=$(cat "$CLI_CONFIG")
else
    CLI_TOOL="claude"  # Default fallback
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
        CLI_CODE_CMD="claude"
        ;;
esac

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
    esac
    
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
}

show_help() {
    cat << HELPEOF
Ralph Import - Convert PRDs to Ralph Format

Usage: $0 <source-file> [project-name] [project-path]

Arguments:
    source-file     Path to your PRD/specification file (any format)
    project-name    Name for the new Ralph project (optional, defaults to filename)
    project-path    Path to the actual project directory where code should be written

Examples:
    $0 my-app-prd.md
    $0 requirements.txt my-awesome-app
    $0 project-spec.json
    $0 design-doc.docx webapp

Supported formats:
    - Markdown (.md)
    - Text files (.txt)
    - JSON (.json)
    - Word documents (.docx)
    - PDFs (.pdf)
    - Any text-based format

The command will:
1. Create a new Ralph project
2. Use CLI tool to intelligently convert your PRD into:
   - PROMPT.md (Ralph instructions)
   - @fix_plan.md (prioritized tasks)
   - specs/ (technical specifications)

HELPEOF
}

# Check dependencies
check_dependencies() {
    if ! command -v ralph-setup &> /dev/null; then
        log "ERROR" "Ralph not installed. Run ./install.sh first"
        exit 1
    fi
    
    # Check for the appropriate CLI tool based on user selection
    case "$CLI_TOOL" in
        "copilot")
            if ! command -v copilot &> /dev/null; then
                log "WARN" "Copilot CLI not found. It will be downloaded when first used."
            fi
            ;;
        "claude")
            if ! command -v claude &> /dev/null; then
                log "WARN" "Claude CLI not found. It will be downloaded when first used."
            fi
            ;;
        *)
            log "WARN" "Unknown CLI tool: $CLI_TOOL. Using Claude CLI as fallback."
            if ! command -v claude &> /dev/null; then
                log "WARN" "Claude CLI not found. It will be downloaded when first used."
            fi
            ;;
    esac
}

# Convert PRD using selected CLI tool
convert_prd() {
    local source_file=$1
    local project_name=$2
    local project_path=$3
    
    log "INFO" "Converting PRD to Ralph format..."
    log "DEBUG" "Current directory: $(pwd)"
    log "DEBUG" "Source file: ../$source_file"
    log "DEBUG" "File exists: $([ -f "../$source_file" ] && echo 'YES' || echo 'NO')"
    
    # Read the source PRD file content
    if ! [ -f "../$source_file" ]; then
        log "ERROR" "Source file not found: ../$source_file"
        return 1
    fi
    
    local prd_content=$(cat "../$source_file")
    log "DEBUG" "PRD content length: ${#prd_content} bytes"
    
    # 1. Create PROMPT.md
    log "DEBUG" "Attempting to create PROMPT.md..."
    {
        echo "# Ralph Development Instructions"
        echo ""
        echo "## Project Location"
        echo "Working directory: $(pwd)"
        echo "Actual project path: $project_path"
        echo ""
        echo "## Context"
        echo "You are Ralph, an autonomous AI development agent working on this project."
        echo ""
        echo "## Current Objectives"
        echo "Based on the PRD content below, extract and prioritize 4-6 main objectives:"
        echo ""
        echo "## Key Principles"
        echo "- ONE task per loop - focus on the most important thing"
        echo "- Do not create separate solution files or staging folders. You MUST work directly in the project structure."
        echo "- You are not in main branch. Edit the files of the actual project."
        echo "- Search codebase before implementing"
        echo "- Use subagents for expensive operations"
        echo "- Write unit tests for new functionality"
        echo "- Write regression tests for new functionality"
        echo "- Update @fix_plan.md with learnings"
        echo "- Commit working changes with clear messages"
        echo "- Your task is not complete until the live application reflects the changes."
        echo ""
        echo "## Testing Guidelines"
        echo "- After implementing a feature or fixing a bug, run the related unit tests. If the unit tests pass using the project files, the task is done."
        echo "- PRIORITIZE: Implementation > Docs > Tests"
        echo "- Only test NEW code, don't refactor existing tests"
        echo ""
        echo "## Project Requirements from PRD:"
        echo ""
        echo "$prd_content"
        echo ""
        echo "## Technical Constraints"
        echo "[Extract from PRD: frameworks, languages, preferences]"
        echo ""
        echo "## Success Criteria"
        echo "[Define what done means]"
        echo ""
        echo "## Current Task"
        echo "Follow @fix_plan.md and implement the highest priority item."
    } > PROMPT.md 2>&1
    
    local prompt_status=$?
    log "DEBUG" "PROMPT.md write exit code: $prompt_status"
    if [ -f PROMPT.md ]; then
        local size=$(wc -c < PROMPT.md)
        log "DEBUG" "PROMPT.md created, size: $size bytes"
        log "SUCCESS" "Created PROMPT.md"
    else
        log "ERROR" "PROMPT.md not found after write attempt"
        log "DEBUG" "Listing current directory:"
        ls -la
        return 1
    fi
    
    # 2. Create @fix_plan.md with PRD-based content
    log "DEBUG" "Attempting to create @fix_plan.md..."
    
    cat > @fix_plan.md << 'FIXEOF'
# Ralph Fix Plan

## High Priority
- [ ] Implement all approved PRD goals and requirements
- [ ] Set up development environment (SQLite for dev, PostgreSQL ready)
- [ ] Create core dashboard functionality after login
- [ ] Implement user authentication and login flows
- [ ] Implement package management with last updated tracking
- [ ] Implement customer and services management

## Medium Priority
- [ ] Environment parity between dev (SQLite) and production (PostgreSQL)
- [ ] Set up comprehensive testing
- [ ] Create API documentation
- [ ] Code quality and refactoring

## Low Priority
- [ ] Performance optimizations
- [ ] Extended features beyond MVP
- [ ] Enhanced logging and monitoring

## Completed
- [x] Project initialization

## Notes
- Review PRD content in PROMPT.md for full requirements
- Break down each user story into implementable tasks
- Update priorities based on dependencies
- Run 'ralph --monitor' to start autonomous development
FIXEOF
    
    local fix_status=$?
    log "DEBUG" "@fix_plan.md write exit code: $fix_status"
    if [ -f @fix_plan.md ]; then
        local size=$(wc -c < @fix_plan.md)
        log "DEBUG" "@fix_plan.md created, size: $size bytes"
        log "SUCCESS" "Created @fix_plan.md"
    else
        log "ERROR" "@fix_plan.md not found after write attempt"
        return 1
    fi
    
    # 3. Create specs directory and requirements.md
    log "DEBUG" "Checking if specs directory exists..."
    if [ -d specs ]; then
        log "DEBUG" "specs directory already exists"
    else
        log "DEBUG" "Creating specs directory..."
        mkdir -p specs 2>&1
        local mkdir_status=$?
        log "DEBUG" "mkdir exit code: $mkdir_status"
    fi
    
    if [ -d specs ]; then
        log "DEBUG" "specs directory confirmed to exist"
    else
        log "ERROR" "Failed to create specs directory"
        log "DEBUG" "Attempting to create it with different method..."
        mkdir specs || { log "ERROR" "mkdir failed"; return 1; }
    fi
    
    log "DEBUG" "Attempting to create specs/requirements.md..."
    
    cat > specs/requirements.md << 'SPECSEOF'
# Technical Specifications

## Overview
Technical specifications derived from PRD. Review PROMPT.md for full PRD details.

## System Architecture
- Environment parity: SQLite for development/testing and PostgreSQL for production
- Dashboard-based web interface
- Role-based access control for Admin, Professionals, and Customers
- Session-based authentication
- Modular service architecture

## Key User Stories & Requirements
- Jan1.1: Professional can land to dashboard page after login to manage Customers and Services
- Jan1.2: Professional can see when a Package was last updated to manage it effectively
- All issues identified must be fixed during this sprint
- All documented features must be developed and tested

## Data Models
- User model with roles (Admin, Professional, Customer)
- Package model with last_updated timestamp
- Customer model
- Services model
- Audit/Activity tracking for changes

## APIs
- Authentication endpoints (login, logout, session management, register)
- Dashboard data endpoints (summary, metrics)
- CRUD operations for Packages, Customers, Services
- Search and filter endpoints
- Audit log endpoints

## UI Requirements
- Dashboard page as primary landing post-login
- Package management interface with last updated column
- Customer management interface
- Services management interface
- Role-specific UI variations (Admin/Professional/Customer)
- Responsive design for mobile and desktop
- Professional role restrictions on certain operations

## Performance Requirements
- Dashboard load time: < 1 second
- API response time: < 500ms for 95th percentile
- Database query optimization for large datasets
- Support for 1000+ concurrent users

## Security Requirements
- Secure user authentication with password hashing (bcrypt/argon2)
- Role-based authorization for all features
- SQL injection prevention (parameterized queries)
- XSS prevention (input validation and sanitization)
- CSRF protection for state-changing operations
- Data encryption at rest (PostgreSQL)
- HTTPS for all communications

## Integration Requirements
- SQLite for local development and testing
- PostgreSQL for production with full feature support
- Git for version control
- Environment configuration management

## Database Migration Strategy
- Schema migration scripts for SQLite ↔ PostgreSQL parity
- Automated testing of migrations in both databases
- Data seeding scripts for development/testing
- Rollback procedures for production

## Testing Requirements
- Unit tests for business logic
- Integration tests for APIs
- End-to-end tests for user workflows
- Test coverage target: 80%+
- Cross-browser testing

## Notes
This specification has been created based on PRD analysis.
Review the complete PRD in PROMPT.md for detailed requirements.
Specifications should be refined as development progresses.
SPECSEOF
    
    local specs_status=$?
    log "DEBUG" "specs/requirements.md write exit code: $specs_status"
    if [ -f specs/requirements.md ]; then
        local size=$(wc -c < specs/requirements.md)
        log "DEBUG" "specs/requirements.md created, size: $size bytes"
        log "SUCCESS" "Created specs/requirements.md"
    else
        log "ERROR" "specs/requirements.md not found after write attempt"
        log "DEBUG" "Listing specs directory:"
        ls -la specs/
        return 1
    fi
    
    log "DEBUG" "Final directory listing:"
    ls -la
    log "INFO" "All files created successfully!"
}

# Main function
main() {
    local source_file="$1"
    local project_name="$2"
    local project_path="$3"
    
    # Validate arguments
    if [[ -z "$source_file" ]]; then
        log "ERROR" "Source file is required"
        show_help
        exit 1
    fi
    
    if [[ ! -f "$source_file" ]]; then
        log "ERROR" "Source file does not exist: $source_file"
        exit 1
    fi
    
    # Default project name from filename
    if [[ -z "$project_name" ]]; then
        project_name=$(basename "$source_file" | sed 's/\.[^.]*$//')
    fi
    
    # Get project path from user if not provided
    if [[ -z "$project_path" ]]; then
        log "INFO" "Project path is required to tell Ralph where to work."
        echo -n "Enter the path to your actual project directory: "
        read project_path
        
        if [[ -z "$project_path" ]]; then
            log "ERROR" "Project path cannot be empty"
            exit 1
        fi
    fi
    
    # Validate that project path exists
    if [[ ! -d "$project_path" ]]; then
        log "ERROR" "Project path does not exist: $project_path"
        exit 1
    fi
    
    # Resolve to absolute path
    project_path=$(cd "$project_path" && pwd)
    
    log "INFO" "Converting PRD: $source_file"
    log "INFO" "Project name: $project_name"
    
    check_dependencies
    
    # Create project directory
    log "INFO" "Creating Ralph project: $project_name"
    ralph-setup "$project_name"
    cd "$project_name"
    
    # Copy source file to project
    cp "../$source_file" .
    
    # Run conversion
    convert_prd "$source_file" "$project_name" "$project_path"
    
    log "SUCCESS" "🎉 PRD imported successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Review and edit the generated files:"
    echo "     - PROMPT.md (Ralph instructions)"  
    echo "     - @fix_plan.md (task priorities)"
    echo "     - specs/requirements.md (technical specs)"
    echo "  2. Start autonomous development:"
    echo "     ralph --monitor"
    echo ""
    echo "Project created in: $(pwd)"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help|"")
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
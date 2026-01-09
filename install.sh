#!/bin/bash

# Ralph for any CLI - Global Installation Script
set -e

# Configuration
INSTALL_DIR="$HOME/.local/bin"
RALPH_HOME="$HOME/.ralph"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Select CLI tool with interactive menu
select_cli_tool() {
    log "INFO" "Selecting CLI tool for Ralph..."
    
    local options=("Copilot CLI" "Gemini CLI" "OpenCode CLI" "Claude CLI")
    local available=(true false false true)  # Only Copilot and Claude available
    local selected=0
    local choice=""
    
    # Save selection to config
    local config_file="$RALPH_HOME/cli_config"
    
    while true; do
        clear
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║     Ralph - Select Your CLI Tool                           ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        
        for i in "${!options[@]}"; do
            local option="${options[$i]}"
            local is_available="${available[$i]}"
            local prefix="  "
            local status=""
            
            # Highlight selected option
            if [ $i -eq $selected ]; then
                prefix="▶ "
            fi
            
            # Mark unavailable options
            if [ "$is_available" = false ]; then
                status=" [Coming Soon]"
                echo -e "${YELLOW}${prefix}${option}${status}${NC}"
            else
                echo -e "${GREEN}${prefix}${option}${NC}"
            fi
        done
        
        echo ""
        echo "Use ↑↓ arrows to navigate, Enter to select"
        echo ""
        
        # Read single key input
        read -rsn1 key
        
        case "$key" in
            $'\x1b')  # Escape sequence
                read -rsn2 key  # Read the rest of the sequence
                case "$key" in
                    '[A')  # Up arrow
                        selected=$((selected - 1))
                        if [ $selected -lt 0 ]; then
                            selected=$((${#options[@]} - 1))
                        fi
                        ;;
                    '[B')  # Down arrow
                        selected=$((selected + 1))
                        if [ $selected -ge ${#options[@]} ]; then
                            selected=0
                        fi
                        ;;
                esac
                ;;
            '')  # Enter key
                # Check if selected option is available
                if [ "${available[$selected]}" = true ]; then
                    choice="${options[$selected]}"
                    break
                else
                    # Show unavailable message
                    clear
                    echo ""
                    echo -e "${RED}❌ ${options[$selected]} is not yet available${NC}"
                    echo "Please select Copilot CLI or Claude CLI"
                    echo ""
                    read -p "Press Enter to continue..."
                fi
                ;;
        esac
    done
    
    clear
    
    # Convert choice to identifier
    local cli_identifier=""
    case "$choice" in
        "Copilot CLI")
            cli_identifier="copilot"
            ;;
        "Claude CLI")
            cli_identifier="claude"
            ;;
    esac
    
    # Save to config
    mkdir -p "$RALPH_HOME"
    echo "$cli_identifier" > "$config_file"
    
    log "SUCCESS" "Selected CLI: $choice"
    echo ""
    
    return 0
}

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        missing_deps+=("Node.js/npm")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies:"
        echo "  Ubuntu/Debian: sudo apt-get install nodejs npm jq git"
        echo "  macOS: brew install node jq git"
        echo "  CentOS/RHEL: sudo yum install nodejs npm jq git"
        exit 1
    fi
    
    # Check tmux (optional)
    if ! command -v tmux &> /dev/null; then
        log "WARN" "tmux not found. Install for integrated monitoring: apt-get install tmux / brew install tmux"
    fi
    
    log "SUCCESS" "Dependencies check completed"
}

# Create installation directory
create_install_dirs() {
    log "INFO" "Creating installation directories..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$RALPH_HOME"
    mkdir -p "$RALPH_HOME/templates"
    mkdir -p "$RALPH_HOME/lib"

    log "SUCCESS" "Directories created: $INSTALL_DIR, $RALPH_HOME"
}

# Install Ralph scripts
install_scripts() {
    log "INFO" "Installing Ralph scripts..."
    
    # Copy templates to Ralph home
    cp -r "$SCRIPT_DIR/templates/"* "$RALPH_HOME/templates/"

    # Copy lib scripts (response_analyzer.sh, circuit_breaker.sh)
    cp -r "$SCRIPT_DIR/lib/"* "$RALPH_HOME/lib/"
    
    # Create the main ralph command
    cat > "$INSTALL_DIR/ralph" << 'EOF'
#!/bin/bash
# Ralph for any CLI - Main Command

RALPH_HOME="$HOME/.ralph"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the actual ralph loop script with global paths
exec "$RALPH_HOME/ralph_loop.sh" "$@"
EOF

    # Create ralph-monitor command
    cat > "$INSTALL_DIR/ralph-monitor" << 'EOF'
#!/bin/bash
# Ralph Monitor - Global Command

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_monitor.sh" "$@"
EOF

    # Create ralph-setup command
    cat > "$INSTALL_DIR/ralph-setup" << 'EOF'
#!/bin/bash
# Ralph Project Setup - Global Command

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/setup.sh" "$@"
EOF

    # Create ralph-import command
    cat > "$INSTALL_DIR/ralph-import" << 'EOF'
#!/bin/bash
# Ralph PRD Import - Global Command

RALPH_HOME="$HOME/.ralph"

exec "$RALPH_HOME/ralph_import.sh" "$@"
EOF

    # Copy actual script files to Ralph home with modifications for global operation
    cp "$SCRIPT_DIR/ralph_monitor.sh" "$RALPH_HOME/"
    
    # Copy PRD import script to Ralph home
    cp "$SCRIPT_DIR/ralph_import.sh" "$RALPH_HOME/"
    
    # Make all commands executable
    chmod +x "$INSTALL_DIR/ralph"
    chmod +x "$INSTALL_DIR/ralph-monitor" 
    chmod +x "$INSTALL_DIR/ralph-setup"
    chmod +x "$INSTALL_DIR/ralph-import"
    chmod +x "$RALPH_HOME/ralph_monitor.sh"
    chmod +x "$RALPH_HOME/ralph_import.sh"
    chmod +x "$RALPH_HOME/lib/"*.sh

    log "SUCCESS" "Ralph scripts installed to $INSTALL_DIR"
}

# Install global ralph_loop.sh
install_ralph_loop() {
    log "INFO" "Installing global ralph_loop.sh..."
    
    # Create modified ralph_loop.sh for global operation
    sed \
        -e "s|RALPH_HOME=\"\$HOME/.ralph\"|RALPH_HOME=\"\$HOME/.ralph\"|g" \
        -e "s|\$script_dir/ralph_monitor.sh|\$RALPH_HOME/ralph_monitor.sh|g" \
        -e "s|\$script_dir/ralph_loop.sh|\$RALPH_HOME/ralph_loop.sh|g" \
        "$SCRIPT_DIR/ralph_loop.sh" > "$RALPH_HOME/ralph_loop.sh"
    
    chmod +x "$RALPH_HOME/ralph_loop.sh"
    
    log "SUCCESS" "Global ralph_loop.sh installed"
}

# Install global setup.sh
install_setup() {
    log "INFO" "Installing global setup script..."
    
    # Create modified setup.sh for global operation
    cat > "$RALPH_HOME/setup.sh" << 'EOF'
#!/bin/bash

# Ralph Project Setup Script - Global Version
set -e

PROJECT_NAME=${1:-"my-project"}
RALPH_HOME="$HOME/.ralph"

echo "🚀 Setting up Ralph project: $PROJECT_NAME"

# Create project directory in current location
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Create structure
mkdir -p {specs/stdlib,src,examples,logs,docs/generated}

# Copy templates from Ralph home
cp "$RALPH_HOME/templates/PROMPT.md" .
cp "$RALPH_HOME/templates/fix_plan.md" @fix_plan.md
cp "$RALPH_HOME/templates/AGENT.md" @AGENT.md
cp -r "$RALPH_HOME/templates/specs/"* specs/ 2>/dev/null || true

# Initialize git
git init
echo "# $PROJECT_NAME" > README.md
git add .
git commit -m "Initial Ralph project setup"

echo "✅ Project $PROJECT_NAME created!"
echo "Next steps:"
echo "  1. Edit PROMPT.md with your project requirements"
echo "  2. Update specs/ with your project specifications"  
echo "  3. Run: ralph --monitor"
echo "  4. Monitor: ralph-monitor (if running manually)"
EOF

    chmod +x "$RALPH_HOME/setup.sh"
    
    log "SUCCESS" "Global setup script installed"
}

# Check PATH
check_path() {
    log "INFO" "Checking PATH configuration..."
    
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log "WARN" "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add this to your ~/.bashrc, ~/.zshrc, or ~/.profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        echo "Then run: source ~/.bashrc (or restart your terminal)"
        echo ""
    else
        log "SUCCESS" "$INSTALL_DIR is already in PATH"
    fi
}

# Main installation
main() {
    echo "🚀 Installing Ralph globally..."
    echo ""
    
    select_cli_tool
    check_dependencies
    create_install_dirs
    install_scripts
    install_ralph_loop
    install_setup
    check_path
    
    echo ""
    log "SUCCESS" "🎉 Ralph installed successfully!"
    echo ""
    echo "Global commands available:"
    echo "  ralph --monitor          # Start Ralph with integrated monitoring"
    echo "  ralph --help            # Show Ralph options"
    echo "  ralph-setup my-project  # Create new Ralph project"
    echo "  ralph-import prd.md     # Convert PRD to Ralph project"
    echo "  ralph-monitor           # Manual monitoring dashboard"
    echo ""
    echo "Quick start:"
    echo "  1. ralph-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit PROMPT.md with your requirements"
    echo "  4. ralph --monitor"
    echo ""
    
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "⚠️  Don't forget to add $INSTALL_DIR to your PATH (see above)"
    fi
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        log "INFO" "Uninstalling Ralph for any CLI..."
        rm -f "$INSTALL_DIR/ralph" "$INSTALL_DIR/ralph-monitor" "$INSTALL_DIR/ralph-setup" "$INSTALL_DIR/ralph-import"
        rm -rf "$RALPH_HOME"
        log "SUCCESS" "Ralph for any CLI uninstalled"
        ;;
    --help|-h)
        echo "Ralph for any CLI Installation"
        echo ""
        echo "Usage: $0 [install|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Ralph globally (default)"
        echo "  uninstall  Remove Ralph installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
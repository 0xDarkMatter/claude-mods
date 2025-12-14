#!/usr/bin/env bash
#
# Modern CLI Toolkit Installer (Linux/macOS)
# Token-efficient tools for AI coding assistants
#

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Modern CLI Toolkit Installer (Unix)                    ║${NC}"
echo -e "${BLUE}║       Token-efficient tools for AI coding assistants         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Detect OS and package manager
detect_package_manager() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            echo "brew"
        else
            echo -e "${RED}ERROR: Homebrew not found. Install from https://brew.sh${NC}"
            exit 1
        fi
    elif command -v apt &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v cargo &> /dev/null; then
        echo "cargo"
    else
        echo -e "${RED}ERROR: No supported package manager found.${NC}"
        exit 1
    fi
}

PKG_MANAGER=$(detect_package_manager)
echo -e "Detected package manager: ${GREEN}$PKG_MANAGER${NC}"
echo ""

installed=0
skipped=0
failed=0

install_tool() {
    local name=$1
    local binary=$2
    local brew_pkg=$3
    local apt_pkg=$4
    local cargo_pkg=$5

    echo -n "  Installing $name... "

    # Check if already installed
    if command -v "$binary" &> /dev/null; then
        echo -e "${YELLOW}SKIP (already installed)${NC}"
        ((skipped++))
        return
    fi

    case $PKG_MANAGER in
        brew)
            if brew install "$brew_pkg" &> /dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((installed++))
            else
                echo -e "${RED}FAILED${NC}"
                ((failed++))
            fi
            ;;
        apt)
            if sudo apt install -y "$apt_pkg" &> /dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((installed++))
            else
                # Fallback to cargo if apt package not available
                if [ -n "$cargo_pkg" ] && command -v cargo &> /dev/null; then
                    if cargo install "$cargo_pkg" &> /dev/null; then
                        echo -e "${GREEN}OK (via cargo)${NC}"
                        ((installed++))
                    else
                        echo -e "${RED}FAILED${NC}"
                        ((failed++))
                    fi
                else
                    echo -e "${RED}FAILED${NC}"
                    ((failed++))
                fi
            fi
            ;;
        dnf)
            if sudo dnf install -y "$apt_pkg" &> /dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((installed++))
            else
                echo -e "${RED}FAILED${NC}"
                ((failed++))
            fi
            ;;
        pacman)
            if sudo pacman -S --noconfirm "$apt_pkg" &> /dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((installed++))
            else
                echo -e "${RED}FAILED${NC}"
                ((failed++))
            fi
            ;;
        cargo)
            if cargo install "$cargo_pkg" &> /dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((installed++))
            else
                echo -e "${RED}FAILED${NC}"
                ((failed++))
            fi
            ;;
    esac
}

echo "File Search & Navigation"
echo "────────────────────────"
install_tool "fd (find replacement)" "fd" "fd" "fd-find" "fd-find"
install_tool "ripgrep (grep replacement)" "rg" "ripgrep" "ripgrep" "ripgrep"
install_tool "eza (ls replacement)" "eza" "eza" "eza" "eza"
install_tool "bat (cat replacement)" "bat" "bat" "bat" "bat"
install_tool "zoxide (cd replacement)" "zoxide" "zoxide" "zoxide" "zoxide"
install_tool "broot (tree replacement)" "broot" "broot" "broot" "broot"
echo ""

echo "Data Processing"
echo "────────────────"
install_tool "sd (sed replacement)" "sd" "sd" "sd" "sd"
install_tool "jq (JSON processor)" "jq" "jq" "jq" ""
install_tool "yq (YAML processor)" "yq" "yq" "yq" ""
echo ""

echo "Git Operations"
echo "──────────────"
install_tool "delta (git diff)" "delta" "git-delta" "git-delta" "git-delta"
install_tool "difft (semantic diff)" "difft" "difftastic" "difftastic" "difftastic"
install_tool "lazygit (git TUI)" "lazygit" "lazygit" "lazygit" ""
install_tool "gh (GitHub CLI)" "gh" "gh" "gh" ""
echo ""

echo "System Monitoring"
echo "─────────────────"
install_tool "dust (du replacement)" "dust" "dust" "du-dust" "du-dust"
install_tool "bottom (top replacement)" "btm" "bottom" "bottom" "bottom"
install_tool "procs (ps replacement)" "procs" "procs" "procs" "procs"
echo ""

echo "Code Analysis"
echo "─────────────"
install_tool "tokei (line counter)" "tokei" "tokei" "tokei" "tokei"
install_tool "ast-grep (AST search)" "sg" "ast-grep" "" "ast-grep"
install_tool "hyperfine (benchmarking)" "hyperfine" "hyperfine" "hyperfine" "hyperfine"
echo ""

echo "Interactive Selection"
echo "─────────────────────"
install_tool "fzf (fuzzy finder)" "fzf" "fzf" "fzf" ""
echo ""

echo "Documentation"
echo "─────────────"
install_tool "tldr (man replacement)" "tldr" "tealdeer" "tldr" "tealdeer"
echo ""

echo "Python"
echo "──────"
install_tool "uv (pip replacement)" "uv" "uv" "" ""
echo ""

echo "Task Running"
echo "────────────"
install_tool "just (make replacement)" "just" "just" "just" "just"
echo ""

echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Results: $installed installed, $skipped skipped, $failed failed${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

# Post-install: Update tldr cache
if command -v tldr &> /dev/null; then
    echo ""
    echo -n "Updating tldr cache..."
    tldr --update &> /dev/null || true
    echo -e " ${GREEN}OK${NC}"
fi

# Post-install: Shell integration hints
echo ""
echo -e "${YELLOW}Shell Integration:${NC}"
echo ""
echo "Add to your ~/.bashrc or ~/.zshrc:"
echo ""
echo "  # zoxide (smart cd)"
echo '  eval "$(zoxide init bash)"  # or zsh'
echo ""
echo "  # fzf integration"
echo '  [ -f ~/.fzf.bash ] && source ~/.fzf.bash  # or .zsh'
echo '  export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"'
echo ""

# Install custom CLI wrappers
echo ""
echo -e "${BLUE}Installing custom CLI wrappers...${NC}"
echo "────────────────────────────────"

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

# Perplexity CLI wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/perplexity.py" ]; then
    cp "$SCRIPT_DIR/perplexity.py" "$LOCAL_BIN/perplexity"
    chmod +x "$LOCAL_BIN/perplexity"
    echo -e "  perplexity CLI: ${GREEN}OK${NC}"
else
    echo -e "  perplexity CLI: ${YELLOW}SKIP (perplexity.py not found)${NC}"
fi

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    echo ""
    echo -e "${YELLOW}Add ~/.local/bin to your PATH:${NC}"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo -e "${BLUE}Verify installation with:${NC}"
echo '  which fd rg eza bat zoxide delta difft jq yq sd lazygit gh tokei uv just fzf dust btm procs tldr'
echo '  perplexity --list-models'
echo ""

#!/usr/bin/env bash
set -euo pipefail

# clean.sh — Clean build artifacts
# Usage: ./scripts/clean.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

info()    { printf "${BLUE}[INFO]${RESET} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${RESET}   %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
error()   { printf "${RED}[FAIL]${RESET} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_deps() {
    if ! command -v xcodebuild &>/dev/null; then
        error "xcodebuild not found. Install Xcode from the Mac App Store."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Clean helpers
# ---------------------------------------------------------------------------
CLEANED=0

remove_dir() {
    local dir="$1" label="$2"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        info "Removed ${label}: ${dir}"
        CLEANED=$((CLEANED + 1))
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_deps
    info "Project: ${BOLD}${PROJECT_ROOT}${RESET}"
    echo

    # xcodebuild clean
    info "Running ${BOLD}xcodebuild clean${RESET} ..."
    xcodebuild \
        -project "$PROJECT_ROOT/Babylon.xcodeproj" \
        -scheme Babylon \
        clean 2>&1 | tail -3
    CLEANED=$((CLEANED + 1))
    success "xcodebuild clean completed"
    echo

    # Remove local build artifact directories
    remove_dir "$PROJECT_ROOT/DerivedData" "DerivedData"
    remove_dir "$PROJECT_ROOT/build"       "build"
    remove_dir "$PROJECT_ROOT/.build"      ".build (SPM)"

    echo
    if [[ $CLEANED -gt 0 ]]; then
        success "Clean complete (${CLEANED} action(s) performed)."
    else
        info "Nothing to clean."
    fi
}

main

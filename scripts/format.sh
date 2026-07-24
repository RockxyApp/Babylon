#!/usr/bin/env bash
set -euo pipefail

# format.sh — Auto-format code, then verify with swiftlint
# Usage: ./scripts/format.sh

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
MISSING=0

check_tool() {
    local tool="$1" install_msg="$2"
    if ! command -v "$tool" &>/dev/null; then
        error "${tool} not found."
        info "  Install: ${install_msg}"
        MISSING=1
    fi
}

check_tool swiftformat "brew install swiftformat"
check_tool swiftlint   "brew install swiftlint"

if [[ $MISSING -ne 0 ]]; then
    exit 1
fi

# ---------------------------------------------------------------------------
# Format
# ---------------------------------------------------------------------------
run_swiftformat() {
    info "Running ${BOLD}swiftformat${RESET} ..."

    # Capture list of changed files by running in --verbose mode
    local output
    output=$(cd "$PROJECT_ROOT" && swiftformat . --verbose 2>&1)

    local changed
    changed=$(echo "$output" | grep -c "^.* changed$" || true)
    local unchanged
    unchanged=$(echo "$output" | grep -c "^.* unchanged$" || true)

    if [[ $changed -gt 0 ]]; then
        info "swiftformat modified ${BOLD}${changed}${RESET} file(s) (${unchanged} unchanged)"
        # Show which files changed
        echo "$output" | grep "^.* changed$" | while IFS= read -r line; do
            printf "  ${YELLOW}*${RESET} %s\n" "$line"
        done
    else
        success "swiftformat: all files already formatted (${unchanged} checked)"
    fi
}

run_swiftlint_verify() {
    info "Verifying with ${BOLD}swiftlint lint --strict${RESET} ..."
    local status=0
    local output
    output=$(cd "$PROJECT_ROOT" && swiftlint lint --strict 2>&1) || status=$?

    if [[ $status -eq 0 ]]; then
        success "swiftlint: no violations"
    else
        local violations
        violations=$(echo "$output" | grep -cE "(warning:|error:)" || true)
        warn "swiftlint: ${violations} violation(s) remain (require manual fix)"
        echo "$output"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Project: ${BOLD}${PROJECT_ROOT}${RESET}"
    echo

    run_swiftformat
    echo
    run_swiftlint_verify

    echo
    success "Formatting complete."
}

main

#!/usr/bin/env bash
set -euo pipefail

# lint.sh — Check code quality (read-only, never modifies files)
# Usage: ./scripts/lint.sh

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
# Lint checks
# ---------------------------------------------------------------------------
OVERALL=0

run_swiftformat_lint() {
    info "Running ${BOLD}swiftformat --lint${RESET} ..."
    local output status=0
    output=$(cd "$PROJECT_ROOT" && swiftformat --lint . 2>&1) || status=$?

    if [[ $status -eq 0 ]]; then
        success "swiftformat: no formatting issues"
    else
        local count
        count=$(echo "$output" | grep -c "warning:" || true)
        error "swiftformat: ${count} formatting issue(s)"
        echo "$output"
        OVERALL=1
    fi
}

run_swiftlint() {
    info "Running ${BOLD}swiftlint lint --strict${RESET} ..."
    local output status=0
    output=$(cd "$PROJECT_ROOT" && swiftlint lint --strict 2>&1) || status=$?

    # Count violations from the summary line or from individual warnings/errors
    local violations
    violations=$(echo "$output" | grep -cE "(warning:|error:)" || true)

    if [[ $status -eq 0 ]]; then
        success "swiftlint: no violations"
    else
        error "swiftlint: ${violations} violation(s)"
        echo "$output"
        OVERALL=1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Project: ${BOLD}${PROJECT_ROOT}${RESET}"
    echo

    run_swiftformat_lint
    echo
    run_swiftlint

    echo
    if [[ $OVERALL -eq 0 ]]; then
        success "All lint checks passed."
    else
        error "Lint checks found issues. Run ./scripts/format.sh to auto-fix formatting."
        exit 1
    fi
}

main

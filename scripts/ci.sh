#!/usr/bin/env bash
set -euo pipefail

# ci.sh — Full CI pipeline: lint, build (Debug + Release), test
# Usage: ./scripts/ci.sh

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
    local missing=0
    for tool in xcodebuild swiftformat swiftlint; do
        if ! command -v "$tool" &>/dev/null; then
            error "${tool} not found."
            missing=1
        fi
    done
    if [[ $missing -ne 0 ]]; then
        info "Install missing tools:"
        info "  xcodebuild  — Install Xcode from the Mac App Store"
        info "  swiftformat — brew install swiftformat"
        info "  swiftlint   — brew install swiftlint"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step runner — tracks results for summary table
# ---------------------------------------------------------------------------
declare -a STEP_NAMES=()
declare -a STEP_RESULTS=()
declare -a STEP_DURATIONS=()
OVERALL_STATUS=0

run_step() {
    local name="$1"; shift

    printf "\n${BOLD}=== %s ===${RESET}\n" "$name"

    local start_time
    start_time=$(date +%s)

    local status=0
    "$@" || status=$?

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    STEP_NAMES+=("$name")
    STEP_DURATIONS+=("${duration}s")

    if [[ $status -eq 0 ]]; then
        STEP_RESULTS+=("PASS")
        success "${name} passed (${duration}s)"
    else
        STEP_RESULTS+=("FAIL")
        error "${name} failed (${duration}s)"
        OVERALL_STATUS=1
    fi
}

# ---------------------------------------------------------------------------
# Individual CI steps
# ---------------------------------------------------------------------------
step_lint() {
    cd "$PROJECT_ROOT"
    swiftformat --lint . 2>&1
    swiftlint lint --strict 2>&1
}

step_release_audit() {
    "$PROJECT_ROOT/scripts/public-release-audit.sh"
}

step_build_debug() {
    xcodebuild \
        -project "$PROJECT_ROOT/Babylon.xcodeproj" \
        -scheme Babylon \
        -destination 'generic/platform=iOS' \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | tail -5
}

step_build_release() {
    xcodebuild \
        -project "$PROJECT_ROOT/Babylon.xcodeproj" \
        -scheme Babylon \
        -destination 'generic/platform=iOS' \
        -configuration Release \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | tail -5
}

step_test() {
    cd "$PROJECT_ROOT"
    swift test --no-parallel 2>&1 | tail -20
}

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
print_summary() {
    local total_steps=${#STEP_NAMES[@]}

    printf "\n${BOLD}%-25s %-10s %s${RESET}\n" "Step" "Result" "Duration"
    printf "%-25s %-10s %s\n" "-------------------------" "----------" "--------"

    for i in $(seq 0 $(( total_steps - 1 ))); do
        local result="${STEP_RESULTS[$i]}"
        local color="$GREEN"
        [[ "$result" == "FAIL" ]] && color="$RED"
        printf "%-25s ${color}%-10s${RESET} %s\n" \
            "${STEP_NAMES[$i]}" "$result" "${STEP_DURATIONS[$i]}"
    done

    echo
    if [[ $OVERALL_STATUS -eq 0 ]]; then
        success "CI pipeline: all steps passed"
    else
        error "CI pipeline: one or more steps failed"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_deps
    info "Project: ${BOLD}${PROJECT_ROOT}${RESET}"
    info "Starting CI pipeline ..."

    # Run all steps, continuing even if earlier ones fail
    run_step "Release Audit" step_release_audit
    run_step "Lint"          step_lint
    run_step "Build Debug"   step_build_debug
    run_step "Build Release" step_build_release
    run_step "Test"          step_test

    print_summary
    exit $OVERALL_STATUS
}

main

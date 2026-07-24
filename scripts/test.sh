#!/usr/bin/env bash
set -euo pipefail

# test.sh — Run Babylon tests on the iOS Simulator
# Usage: ./scripts/test.sh [--filter ClassName[/testMethod]] [--destination "..."]

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
# Parse arguments
# ---------------------------------------------------------------------------
DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=latest"
FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            [[ $# -lt 2 ]] && { error "--filter requires a value"; exit 1; }
            FILTER="$2"; shift 2
            ;;
        --destination)
            [[ $# -lt 2 ]] && { error "--destination requires a value"; exit 1; }
            DESTINATION="$2"; shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--filter ClassName[/testMethod]] [--destination \"...\"]"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Usage: $0 [--filter ClassName[/testMethod]] [--destination \"...\"]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_deps
    info "Project: ${BOLD}${PROJECT_ROOT}${RESET}"
    info "Destination: ${DESTINATION}"

    local cmd=(
        xcodebuild
        -project "$PROJECT_ROOT/Babylon.xcodeproj"
        -scheme Babylon
        -destination "$DESTINATION"
        CODE_SIGNING_ALLOWED=NO
        test
    )

    if [[ -n "$FILTER" ]]; then
        cmd+=(-only-testing:"BabylonTests/${FILTER}")
        info "Filter: BabylonTests/${FILTER}"
    fi

    echo

    local start_time
    start_time=$(date +%s)

    local use_xcpretty=false
    if command -v xcpretty &>/dev/null; then
        use_xcpretty=true
    fi

    local status=0
    if $use_xcpretty; then
        "${cmd[@]}" 2>&1 | xcpretty --test || status=${PIPESTATUS[0]}
    else
        "${cmd[@]}" || status=$?
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    echo
    if [[ $status -eq 0 ]]; then
        success "Tests passed (${duration}s)"
    else
        error "Tests failed (${duration}s)"
        exit $status
    fi
}

main

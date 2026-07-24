#!/usr/bin/env bash
set -euo pipefail

# build.sh — Build the Babylon framework (Debug and/or Release)
# Usage: ./scripts/build.sh [--debug-only] [--release-only]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Color helpers (degrade gracefully when stdout is not a terminal)
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
BUILD_DEBUG=true
BUILD_RELEASE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug-only)   BUILD_RELEASE=false; shift ;;
        --release-only) BUILD_DEBUG=false;   shift ;;
        -h|--help)
            echo "Usage: $0 [--debug-only] [--release-only]"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Usage: $0 [--debug-only] [--release-only]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Build helper
# ---------------------------------------------------------------------------
USE_XCPRETTY=false
if command -v xcpretty &>/dev/null; then
    USE_XCPRETTY=true
else
    warn "xcpretty not found — raw xcodebuild output will be shown."
    warn "Install with: gem install xcpretty"
fi

run_build() {
    local config="$1"
    info "Building ${BOLD}${config}${RESET} ..."

    local start_time
    start_time=$(date +%s)

    local cmd=(
        xcodebuild
        -project "$PROJECT_ROOT/Babylon.xcodeproj"
        -scheme Babylon
        -destination 'generic/platform=iOS'
        -configuration "$config"
        CODE_SIGNING_ALLOWED=NO
        build
    )

    if $USE_XCPRETTY; then
        "${cmd[@]}" 2>&1 | xcpretty
        local status=${PIPESTATUS[0]}
    else
        "${cmd[@]}"
        local status=$?
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    if [[ $status -eq 0 ]]; then
        success "${config} build succeeded (${duration}s)"
    else
        error "${config} build failed (${duration}s)"
        exit $status
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_deps
    info "Project: ${BOLD}${PROJECT_ROOT}${RESET}"
    echo

    if $BUILD_DEBUG; then
        run_build Debug
        echo
    fi

    if $BUILD_RELEASE; then
        run_build Release
        echo
    fi

    success "All requested builds completed."
}

main

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT

cd "$PROJECT_ROOT"

git ls-files --cached --others --exclude-standard | while IFS= read -r path; do
    case "$path" in
        .github/*|Babylon/*|Babylon.xcodeproj/*|BabylonTests/*|docs/*|scripts/*) ;;
        .gitignore|.swiftformat|.swiftlint.yml|CHANGELOG.md|CODE_OF_CONDUCT.md|CONTRIBUTING.md|LICENSE|Package.swift|README.md|SECURITY.md) ;;
        *)
            printf 'Unexpected public path: %s\n' "$path" >&2
            exit 1
            ;;
    esac
    if [[ "$path" == *xcuserdata* ]]; then
        printf 'User-specific Xcode data is publishable: %s\n' "$path" >&2
        exit 1
    fi
    # Path-shape checks above must run for tracked-but-deleted files too. Only
    # the content scan below needs the file to be readable on disk.
    [[ -e "$path" ]] || continue
    printf '%s\n' "$path"
done > "$MANIFEST"

user_path='/'"Users"'/'
team_setting='DEVELOPMENT'_'TEAM'
email_pattern='[[:alnum:]._%+-]+@[[:alnum:].-]+\.[A-Za-z]{2,}'
credential_pattern='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}'

if xargs rg -n --no-messages -e "$user_path" -e "$team_setting" < "$MANIFEST"; then
    printf 'Local machine metadata found in public files.\n' >&2
    exit 1
fi

if xargs rg -n --no-messages -e "$email_pattern" -e "$credential_pattern" < "$MANIFEST"; then
    printf 'Potential personal contact or credential material found in public files.\n' >&2
    exit 1
fi

grep -q 'Apache License' LICENSE
grep -q 'Version 2.0' LICENSE
git diff --check

# A clean working tree says nothing about what history already carries. Audit the
# ref that is actually being published, not every local branch: a development
# clone keeps private branches that are never pushed to the public remote.
AUDIT_REF="${BABYLON_AUDIT_REF:-HEAD}"
revisions="$(git rev-list "$AUDIT_REF")"
if [[ -n "$revisions" ]]; then
    if git log "$AUDIT_REF" --pretty=format: --name-only | grep -q 'xcuserdata'; then
        printf 'User-specific Xcode data is present in the history of %s.\n' "$AUDIT_REF" >&2
        exit 1
    fi
    if git grep -nI -E "$user_path|$team_setting|$credential_pattern" $revisions -- ; then
        printf 'Local machine metadata or credential material is present in the history of %s.\n' "$AUDIT_REF" >&2
        exit 1
    fi
fi

printf 'Public audit passed for %s working-tree files and %s commits.\n' \
    "$(wc -l < "$MANIFEST" | tr -d ' ')" \
    "$(printf '%s\n' "$revisions" | grep -c . || true)"

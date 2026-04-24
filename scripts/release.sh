#!/usr/bin/env bash
set -euo pipefail

REPO="${WASMZ_REPO:-Ray-D-Song/wasmz}"
REMOTE="${WASMZ_REMOTE:-origin}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "» $*"
}

latest_tag() {
    git tag --sort=-v:refname | head -n 1
}

confirm() {
    local msg="$1"
    local response
    read -p "$msg [y/N] " response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
Usage: ./release.sh [--push-only] [--repo OWNER/REPO]

Create and push a new GitHub release.

Options:
  --push-only    Skip tagging, only push the current commit
  --repo REPO   GitHub repository (default: Ray-D-Song/wasmz)
  -h, --help   Show this help

Environment:
  WASMZ_REPO    Same as --repo
  WASMZ_REMOTE   Git remote name (default: origin)
EOF
}

PUSH_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push-only)
            PUSH_ONLY=true
            shift
            ;;
        --repo)
            [[ $# -ge 2 ]] || die "--repo requires a value"
            REPO="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

need_cmd git
need_cmd gh

cd "$(dirname "$0")/.."

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)

info "Current branch: $BRANCH"
info "GitHub repo: $REPO"

if [[ -n "$(git status --porcelain)" ]]; then
    die "Working tree has uncommitted changes. Commit or stash them first."
fi

if ! git diff-index --quiet HEAD 2>/dev/null; then
    die "Index has uncommitted changes. Commit or stash them first."
fi

CURRENT_TAG="$(latest_tag)"
if [[ -n "$CURRENT_TAG" ]]; then
    info "Latest tag: $CURRENT_TAG"
else
    info "No existing tags found"
fi

if [[ "$PUSH_ONLY" == true ]]; then
    NEW_TAG="$CURRENT_TAG"
    info "Using existing tag: $NEW_TAG"
else
    echo ""
    echo "Enter a new version tag (e.g., v1.2.3):"
    echo "Press Enter to use '${CURRENT_TAG:-<none>}' as reference:"
    read -r NEW_TAG
    NEW_TAG="${NEW_TAG:-$CURRENT_TAG}"

    if [[ -z "$NEW_TAG" ]]; then
        die "Tag cannot be empty"
    fi

    if [[ "$NEW_TAG" == "$CURRENT_TAG" ]]; then
        die "New tag must be different from current tag: $CURRENT_TAG"
    fi

    if [[ "$NEW_TAG" != v* ]] && [[ "$NEW_TAG" != V* ]]; then
        die "Tag should start with 'v' (e.g., v1.0.0)"
    fi
fi

echo ""
info "Summary:"
info "  Branch: $BRANCH"
info "  Tag: $NEW_TAG"
echo ""

if ! confirm "Create tag $NEW_TAG and push to $REMOTE?"; then
    info "Aborted"
    exit 0
fi

git tag "$NEW_TAG"
info "Created tag: $NEW_TAG"

if ! git push "$REMOTE" "$BRANCH" 2>&1; then
    git tag -d "$NEW_TAG"
    die "Failed to push branch"
fi

info "Pushed branch: $BRANCH"

if ! git push "$REMOTE" "$NEW_TAG" 2>&1; then
    die "Failed to push tag. You can push it manually with:"
    die "  git push $REMOTE $NEW_TAG"
fi

info "Pushed tag: $NEW_TAG"
echo ""
info "Release workflow started. Monitor at:"
info "  https://github.com/$REPO/actions"
echo ""
info "Done!"
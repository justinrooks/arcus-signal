#!/usr/bin/env bash
set -euo pipefail

# Read-only release evidence helper for Arcus Signal.
#
# Examples:
#   tools/release-context.sh git
#   tools/release-context.sh git --baseline v1.0.0
#   tools/release-context.sh git --target-tag v1.1.1
#   tools/release-context.sh section --notes-file release/RELEASE_NOTES.md --tag v1.0.0

usage() {
  cat <<'EOF'
Usage:
  release-context.sh git [--baseline TAG_OR_REVISION] [--target-tag TAG]
  release-context.sh section --notes-file PATH --tag TAG

Commands:
  git       Print repository, baseline, commit-range, commits, and changed paths.
  section   Print the exact Markdown section for TAG from a notes file.

Options:
  --baseline REF       Explicit baseline tag or revision for the git command.
  --target-tag TAG     Verify and report the target tag and commit.
  --notes-file PATH    Markdown release-notes file for the section command.
  --tag TAG            Exact release tag/heading to extract.
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_git_repo() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a Git worktree"
}

repo_root() {
  git rev-parse --show-toplevel
}

resolve_commit() {
  local ref="$1"
  git rev-parse --verify "${ref}^{commit}" 2>/dev/null \
    || die "could not resolve revision: $ref"
}

root_commit() {
  git rev-list --max-parents=0 --reverse HEAD | head -n 1
}

latest_version_tag() {
  git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true
}

print_git_context() {
  local baseline=""
  local target_tag=""
  local target_commit=""
  local head_commit
  local baseline_commit
  local range
  local root
  local initial_release=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --baseline)
        [[ "$#" -ge 2 ]] || die "--baseline requires a value"
        baseline="$2"
        shift 2
        ;;
      --target-tag)
        [[ "$#" -ge 2 ]] || die "--target-tag requires a value"
        target_tag="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "unknown git option: $1"
        ;;
    esac
  done

  require_git_repo
  root="$(repo_root)"
  head_commit="$(resolve_commit HEAD)"

  if [[ -n "$target_tag" ]]; then
    target_commit="$(resolve_commit "$target_tag")"
  fi

  if [[ -z "$baseline" ]]; then
    baseline="$(latest_version_tag)"
    if [[ -z "$baseline" ]]; then
      baseline="repository-root"
      baseline_commit="$(root_commit)"
      initial_release=1
    fi
  fi

  if [[ "$initial_release" -eq 0 ]]; then
    baseline_commit="$(resolve_commit "$baseline")"
    range="${baseline_commit}..${head_commit}"
  else
    range="${baseline_commit}..${head_commit} (initial release includes baseline)"
  fi

  printf 'Repository: %s\n' "$root"
  printf 'HEAD: %s\n' "$head_commit"
  printf 'Baseline: %s\n' "$baseline"
  printf 'Baseline commit: %s\n' "$baseline_commit"
  printf 'Commit range: %s\n' "$range"

  if [[ -n "$target_tag" ]]; then
    printf 'Target tag: %s\n' "$target_tag"
    printf 'Target commit: %s\n' "$target_commit"
  fi

  printf '\nCommits:\n'
  if [[ "$initial_release" -eq 1 ]]; then
    git log --no-decorate --format='%H %s' "$head_commit"
  elif [[ "$baseline_commit" == "$head_commit" ]]; then
    printf '%s\n' '(none)'
  else
    git log --no-decorate --format='%H %s' "$range"
  fi

  printf '\nChanged paths:\n'
  if [[ "$initial_release" -eq 1 ]]; then
    git log --format='' --name-status "$head_commit" | sed '/^$/d'
  elif [[ "$baseline_commit" == "$head_commit" ]]; then
    printf '%s\n' '(none)'
  else
    git diff --name-status "$range"
  fi
}

print_section() {
  local notes_file=""
  local tag=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --notes-file)
        [[ "$#" -ge 2 ]] || die "--notes-file requires a value"
        notes_file="$2"
        shift 2
        ;;
      --tag)
        [[ "$#" -ge 2 ]] || die "--tag requires a value"
        tag="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "unknown section option: $1"
        ;;
    esac
  done

  [[ -n "$notes_file" ]] || die "section requires --notes-file"
  [[ -n "$tag" ]] || die "section requires --tag"
  [[ -f "$notes_file" ]] || die "release-notes file not found: $notes_file"

  awk -v target="$tag" '
    function heading_tag(line, value) {
      value = line
      sub(/^##[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      sub(/^\[/, "", value)
      sub(/\][[:space:]]*$/, "", value)
      return value
    }
    /^##[[:space:]]+/ {
      heading = heading_tag($0)
      is_release_heading = (heading == "Unreleased" || heading ~ /^v[0-9]+\\.[0-9]+\\.[0-9]+$/)
      if (found && is_release_heading && heading != target) {
        exit
      }
      if (heading == target) {
        found = 1
      }
    }
    found { print }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$notes_file" || die "release section not found for tag: $tag"
}

command="${1:-}"
shift || true

case "$command" in
  git)
    print_git_context "$@"
    ;;
  section)
    print_section "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

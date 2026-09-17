#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: repo_preflight.sh [options]

Options:
  --json              Emit machine-readable JSON.
  --base REF         Base ref for merge-base inspection (default: main).
  --scope-file PATH  Newline-separated expected paths for dirty-file classification.
  --output PATH      Write the JSON result to PATH.
  --help              Show this help.

The command is read-only. Without --scope-file, dirty files are reported but are
not classified as unrelated because the intended change scope is unknown.
EOF
}

json_array() {
  if [[ "$#" -eq 0 || ("$#" -eq 1 && -z "$1") ]]; then
    printf '[]'
  else
    printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'
  fi
}

contains_expected_path() {
  local candidate="$1"
  local expected
  while IFS= read -r expected || [[ -n "$expected" ]]; do
    [[ -n "$expected" ]] || continue
    expected="${expected#./}"
    [[ "$candidate" == "$expected" || "$candidate" == "$expected"/* ]] && return 0
  done < "$scope_file"
  return 1
}

base_ref="main"
scope_file=""
output_path=""
json_mode=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json) json_mode=1; shift ;;
    --base)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--base requires a value' >&2; exit 2; }
      base_ref="$2"; shift 2 ;;
    --scope-file)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--scope-file requires a value' >&2; exit 2; }
      scope_file="$2"; shift 2 ;;
    --output)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--output requires a value' >&2; exit 2; }
      output_path="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { printf '%s\n' 'Required command not found: git' >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'Required command not found: jq' >&2; exit 3; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { printf '%s\n' 'Not inside a Git repository.' >&2; exit 3; }
[[ -z "$scope_file" || -f "$scope_file" ]] || { printf 'Scope file not found: %s\n' "$scope_file" >&2; exit 3; }
cd "$repo_root"

remote="$(git remote get-url origin 2>/dev/null || true)"
repository="$remote"
case "$remote" in
  git@github.com:*) repository="${remote#git@github.com:}" ;;
  https://github.com/*) repository="${remote#https://github.com/}" ;;
esac
repository="${repository%.git}"

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD')"
head="$(git rev-parse HEAD 2>/dev/null || true)"
merge_base="$(git merge-base HEAD "$base_ref" 2>/dev/null || true)"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

staged_files=()
unstaged_files=()
untracked_files=()
ambiguous_files=()
all_dirty_files=()

while IFS= read -r status_line || [[ -n "$status_line" ]]; do
  [[ -n "$status_line" ]] || continue
  status_code="${status_line:0:2}"
  path="${status_line:3}"
  [[ "$path" == *' -> '* ]] && path="${path##* -> }"

  if [[ "$status_code" == '??' ]]; then
    if [[ -d "$path" ]]; then
      while IFS= read -r untracked_path || [[ -n "$untracked_path" ]]; do
        [[ -n "$untracked_path" ]] || continue
        all_dirty_files+=("$untracked_path")
        untracked_files+=("$untracked_path")
      done < <(git ls-files --others --exclude-standard -- "$path")
    else
      all_dirty_files+=("$path")
      untracked_files+=("$path")
    fi
    continue
  fi

  all_dirty_files+=("$path")

  index_status="${status_code:0:1}"
  worktree_status="${status_code:1:1}"
  [[ "$index_status" != ' ' ]] && staged_files+=("$path")
  [[ "$worktree_status" != ' ' ]] && unstaged_files+=("$path")
  [[ "$index_status" != ' ' && "$worktree_status" != ' ' ]] && ambiguous_files+=("$path")
done < <(git status --porcelain=v1)

if [[ -n "$scope_file" ]]; then
  unrelated_dirty_files=()
  for path in "${all_dirty_files[@]-}"; do
    contains_expected_path "$path" || unrelated_dirty_files+=("$path")
  done
  scope_status="provided"
else
  unrelated_dirty_files_json=null
  scope_status="unknown"
fi

if [[ "${#ambiguous_files[@]}" -gt 0 ]]; then
  overall_status="unsafe"
elif [[ "${#all_dirty_files[@]}" -gt 0 ]]; then
  overall_status="attention"
else
  overall_status="ready"
fi
[[ -n "$head" ]] || overall_status="error"

staged_json="$(json_array "${staged_files[@]-}")"
unstaged_json="$(json_array "${unstaged_files[@]-}")"
untracked_json="$(json_array "${untracked_files[@]-}")"
ambiguous_json="$(json_array "${ambiguous_files[@]-}")"
if [[ -n "$scope_file" ]]; then
  unrelated_dirty_files_json="$(json_array "${unrelated_dirty_files[@]-}")"
fi

result="$(jq -n \
  --arg repository "$repository" \
  --arg root "$repo_root" \
  --arg branch "$branch" \
  --arg base "$base_ref" \
  --arg head "$head" \
  --arg merge_base "$merge_base" \
  --arg remote "$remote" \
  --arg upstream "$upstream" \
  --arg status "$overall_status" \
  --arg scope "$scope_status" \
  --argjson staged "$staged_json" \
  --argjson unstaged "$unstaged_json" \
  --argjson untracked "$untracked_json" \
  --argjson unrelated "$unrelated_dirty_files_json" \
  --argjson ambiguous "$ambiguous_json" \
  --argjson clean "$([[ "${#all_dirty_files[@]}" -eq 0 ]] && printf true || printf false)" \
  --argjson errors "$([[ -n "$head" ]] && printf '[]' || printf '["Unable to resolve HEAD."]')" \
  '{schema_version: 1, status: $status, repository: $repository, root: $root,
    branch: $branch, base: $base, head: $head, merge_base: $merge_base,
    remote: $remote, upstream: $upstream,
    worktree: {clean: $clean, scope: $scope, staged_files: $staged,
      unstaged_files: $unstaged, untracked_files: $untracked,
      unrelated_dirty_files: $unrelated, ambiguous_files: $ambiguous},
    errors: $errors}')"

if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  printf '%s\n' "$result" > "$output_path"
fi

if [[ "$json_mode" -eq 1 ]]; then
  printf '%s\n' "$result"
else
  printf 'Repository: %s\nRoot: %s\nBranch: %s\nHEAD: %s\nBase: %s\nMerge base: %s\nWorking tree: %s\n' \
    "${repository:-unknown}" "$repo_root" "$branch" "${head:-unknown}" "$base_ref" "${merge_base:-unavailable}" "$overall_status"
  [[ "${#staged_files[@]}" -eq 0 ]] || printf 'Staged files: %s\n' "${#staged_files[@]}"
  [[ "${#unstaged_files[@]}" -eq 0 ]] || printf 'Unstaged files: %s\n' "${#unstaged_files[@]}"
  [[ "${#untracked_files[@]}" -eq 0 ]] || printf 'Untracked files: %s\n' "${#untracked_files[@]}"
  if [[ -n "$scope_file" ]]; then
    printf 'Unrelated dirty files: %s\n' "${#unrelated_dirty_files[@]}"
  else
    printf '%s\n' 'Unrelated dirty files: unavailable (no scope file supplied)'
  fi
fi

if [[ -z "$head" ]]; then
  exit 3
elif [[ "${#ambiguous_files[@]}" -gt 0 ]]; then
  exit 4
elif [[ "${#all_dirty_files[@]}" -gt 0 ]]; then
  exit 1
else
  exit 0
fi

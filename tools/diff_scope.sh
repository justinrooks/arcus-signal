#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: diff_scope.sh BASE HEAD [options]

Produce a mechanical changed-file and risk-boundary report.

Options:
  --scope-file PATH  Newline-separated expected repository-relative paths.
  --output DIR       Write result.json to DIR.
  --json             Emit machine-readable JSON.
  --quiet            Suppress the human summary; print the artifact path.
  --help             Show this help.

The command is read-only. It does not modify Git state or inspect source bodies.
Exit codes: 0 success, 1 out-of-scope candidates found, 2 invalid invocation,
3 unavailable prerequisite/ref.
EOF
}

[[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
base="$1"; head="$2"; shift 2
scope_file=""; output_dir=""; json_mode=0; quiet=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --scope-file) [[ "$#" -ge 2 ]] || exit 2; scope_file="$2"; shift 2 ;;
    --output) [[ "$#" -ge 2 ]] || exit 2; output_dir="$2"; shift 2 ;;
    --json) json_mode=1; shift ;;
    --quiet) quiet=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for command_name in git jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command_name" >&2; exit 3;
  }
done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { printf '%s\n' 'Not inside a Git repository.' >&2; exit 3; }
cd "$repo_root"
[[ -z "$scope_file" || -f "$scope_file" ]] || { printf 'Scope file not found: %s\n' "$scope_file" >&2; exit 3; }
git rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || { printf 'Base ref not found: %s\n' "$base" >&2; exit 3; }
git rev-parse --verify "$head^{commit}" >/dev/null 2>&1 || { printf 'Head ref not found: %s\n' "$head" >&2; exit 3; }

if [[ -z "$output_dir" ]]; then output_dir="$(mktemp -d /private/tmp/arcus-diff-scope.XXXXXX)"; else mkdir -p "$output_dir"; fi
changed_path="$output_dir/changed-files.tsv"; numstat_path="$output_dir/numstat.tsv"; result_path="$output_dir/result.json"
git diff --name-status --find-renames "$base" "$head" > "$changed_path"
git diff --numstat "$base" "$head" > "$numstat_path"

changed_files='[]'; boundaries='[]'; out_of_scope='[]'
production_count=0; test_count=0; migration_count=0; documentation_count=0; tooling_count=0; other_count=0
added_lines=0; deleted_lines=0

while IFS=$'\t' read -r status path extra || [[ -n "$status" ]]; do
  [[ -n "$status" && -n "$path" ]] || continue
  [[ "$status" == R* ]] && path="$extra"
  case "$path" in
    Sources/App/Migrations/*|Sources/App/**/Migrations/*) category="migration"; migration_count=$((migration_count + 1)) ;;
    Sources/*) category="production"; production_count=$((production_count + 1)) ;;
    Tests/*) category="tests"; test_count=$((test_count + 1)) ;;
    docs/*) category="documentation"; documentation_count=$((documentation_count + 1)) ;;
    tools/*) category="tooling"; tooling_count=$((tooling_count + 1)) ;;
    *) category="other"; other_count=$((other_count + 1)) ;;
  esac
  changed_files="$(jq --arg status "$status" --arg path "$path" --arg category "$category" '. + [{status: $status, path: $path, category: $category}]' <<< "$changed_files")"
  case "$path" in
    Sources/App/Controllers/*|Sources/App/apiRoutes.swift) boundaries="$(jq '. + ["api"] | unique' <<< "$boundaries")" ;;
    Sources/App/Jobs/*|Sources/App/Worker/*|Sources/App/Services/*) boundaries="$(jq '. + ["worker"] | unique' <<< "$boundaries")" ;;
    Sources/App/Migrations/*|Sources/App/Models/*|Sources/App/Services/*Persistence*|docs/Sql/*) boundaries="$(jq '. + ["persistence"] | unique' <<< "$boundaries")" ;;
    Sources/App/Infrastructure/Notifications/*|Sources/App/Jobs/Notification*|Sources/App/Services/*Notification*) boundaries="$(jq '. + ["notification"] | unique' <<< "$boundaries")" ;;
    Sources/App/Jobs/*|Sources/App/Worker/*|Sources/App/Infrastructure/*) boundaries="$(jq '. + ["concurrency"] | unique' <<< "$boundaries")" ;;
    Package.swift|docker-compose.yml|docker-compose.yaml|.github/*) boundaries="$(jq '. + ["configuration"] | unique' <<< "$boundaries")" ;;
  esac
done < "$changed_path"
while IFS=$'\t' read -r added deleted _ || [[ -n "$added" ]]; do
  [[ "$added" =~ ^[0-9]+$ && "$deleted" =~ ^[0-9]+$ ]] || continue
  added_lines=$((added_lines + added)); deleted_lines=$((deleted_lines + deleted))
done < "$numstat_path"

if [[ -n "$scope_file" ]]; then
  out_of_scope="$(jq -n --argjson changed "$changed_files" --rawfile scope "$scope_file" '
    ($scope | split("\n") | map(sub("^\\./"; "") | select(length > 0))) as $expected |
    [$changed[] | (.path) as $path | select(($expected | index($path)) == null) | $path] | unique
  ')"
fi

repository="$(git config --get remote.origin.url 2>/dev/null || true)"; repository="${repository#git@github.com:}"; repository="${repository#https://github.com/}"; repository="${repository%.git}"
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD')"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq -n --arg base "$base" --arg head "$head" --arg repository "$repository" --arg branch "$branch" \
  --arg started "$started_at" --arg finished "$finished_at" --arg result "$result_path" \
  --argjson changed "$changed_files" --argjson production "$production_count" --argjson tests "$test_count" \
  --argjson migrations "$migration_count" --argjson documentation "$documentation_count" --argjson tooling "$tooling_count" --argjson other "$other_count" \
  --argjson added "$added_lines" --argjson deleted "$deleted_lines" --argjson boundaries "$boundaries" --argjson out_of_scope "$out_of_scope" \
  '{schema_version: 1, status: (if ($out_of_scope | length) > 0 then "attention" else "passed" end), repository: $repository, branch: $branch, base: $base, head: $head, changed_files: $changed, counts: {production: $production, tests: $tests, migrations: $migrations, documentation: $documentation, tooling: $tooling, other: $other}, boundaries: $boundaries, diff_lines: {added: $added, deleted: $deleted}, out_of_scope_candidates: (if ($out_of_scope | length) > 0 then $out_of_scope else null end), started_at: $started, finished_at: $finished, artifact: $result, errors: []}' > "$result_path"

if [[ "$json_mode" -eq 1 ]]; then jq -c . "$result_path"; elif [[ "$quiet" -eq 1 ]]; then printf '%s\n' "$result_path"; else jq -r '"Arcus Signal diff scope complete.\n\n  - Range: \(.base)..\(.head)\n  - Changed files: \(.changed_files | length)\n  - Lines: +\(.diff_lines.added)/-\(.diff_lines.deleted)\n  - Boundaries: \(.boundaries | join(", "))\n  - Artifact: \(.artifact)"' "$result_path"; fi
[[ "$(jq -r '.status' "$result_path")" == "passed" ]] || exit 1

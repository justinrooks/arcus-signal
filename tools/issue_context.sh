#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: issue_context.sh ISSUE_NUMBER [options]

Create a compact Arcus Signal issue-context packet from GitHub and local docs.

Options:
  --repo OWNER/REPO     GitHub repository (default: origin remote).
  --progress PATH       Progress/runbook Markdown file to inspect.
  --output DIR          Directory for packet artifacts.
  --json                Emit the packet JSON on stdout.
  --quiet               Suppress progress output; errors still go to stderr.
  --help                Show this help.

The command is read-only. It does not modify GitHub, the repository, or source files.
Exit codes: 0 success, 1 expected issue ambiguity, 2 invalid invocation,
3 unavailable prerequisite/environment, 4 unsafe repository state.
EOF
}

issue_number=""
repository=""
progress_path=""
output_dir=""
json_mode=0
quiet=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--repo requires a value' >&2; exit 2; }
      repository="$2"; shift 2 ;;
    --progress)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--progress requires a value' >&2; exit 2; }
      progress_path="$2"; shift 2 ;;
    --output)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--output requires a value' >&2; exit 2; }
      output_dir="$2"; shift 2 ;;
    --json) json_mode=1; shift ;;
    --quiet) quiet=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$issue_number" ]] || { printf '%s\n' 'Only one issue number is allowed.' >&2; exit 2; }
      issue_number="$1"; shift ;;
  esac
done

[[ "$issue_number" =~ ^[0-9]+$ && "$issue_number" -gt 0 ]] || {
  printf '%s\n' 'Provide a positive GitHub issue number.' >&2; exit 2;
}

for command_name in git gh jq rg; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command_name" >&2; exit 3;
  }
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { printf '%s\n' 'Not inside a Git repository.' >&2; exit 3; }
cd "$repo_root"

if [[ -z "$repository" ]]; then
  remote="$(git remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    git@github.com:*) repository="${remote#git@github.com:}" ;;
    https://github.com/*) repository="${remote#https://github.com/}" ;;
    *) printf '%s\n' 'Could not derive a GitHub repository from origin.' >&2; exit 3 ;;
  esac
  repository="${repository%.git}"
fi

if [[ -z "$output_dir" ]]; then
  output_dir="$(mktemp -d "/private/tmp/arcus-issue-${issue_number}.XXXXXX")"
else
  mkdir -p "$output_dir"
fi

progress_path="${progress_path:-docs/plans/location-driven-alert-reconciliation-progress.md}"
issue_json_path="$output_dir/issue.json"
comments_path="$output_dir/comments.json"
progress_section_path="$output_dir/progress-section.md"
repo_packet_path="$output_dir/repo.json"
result_path="$output_dir/result.json"

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
head="$(git rev-parse HEAD 2>/dev/null || true)"

gh issue view "$issue_number" --repo "$repository" \
  --json number,title,body,state,url,labels,comments,assignees,milestone \
  > "$issue_json_path"
jq -c '.comments // []' "$issue_json_path" > "$comments_path"

parent_issue="$(jq -r '.body // ""' "$issue_json_path" | rg -io 'parent (?:epic|issue):[[:space:]]*#([0-9]+)' | head -n 1 | sed -E 's/.*#([0-9]+)/\1/' || true)"
dependency_issues="$(jq -r '.body // ""' "$issue_json_path" | rg -io '(depends on|blocked by|after)[[:space:]]+#([0-9]+)' | sed -E 's/.*#([0-9]+)/\1/' | sort -nu | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)' || true)"
[[ -n "$dependency_issues" ]] || dependency_issues='[]'

issue_text_path="$output_dir/issue-text.md"
jq -r '(.body // "") + "\n\n" + ([.comments[]?.body // empty] | join("\n\n---\n\n"))' "$issue_json_path" > "$issue_text_path"

mentioned_paths_path="$output_dir/mentioned-paths.txt"
mentioned_commands_path="$output_dir/validation-commands.txt"
if [[ -f "$progress_path" ]]; then
  awk -v issue="#$issue_number" '
    $0 ~ "### Issue " issue " " { found=1 }
    found && $0 ~ /^### Issue / && $0 !~ "### Issue " issue " " { exit }
    found { print }
  ' "$progress_path" > "$progress_section_path"
else
  : > "$progress_section_path"
fi

context_text_path="$output_dir/context-text.md"
cat "$issue_text_path" "$progress_section_path" > "$context_text_path"

rg -o '`[^`]+`' "$context_text_path" 2>/dev/null |
  sed 's/^`//; s/`$//' |
  rg '^(Sources/|Tests/|docs/|Package\.swift$|tools/)' |
  sort -u > "$mentioned_paths_path" || true

rg -o 'swift test[^`\n]*' "$context_text_path" 2>/dev/null |
  sed 's/[[:space:]]*$//' | sort -u > "$mentioned_commands_path" || true

stop_condition="$(awk '
  tolower($0) ~ /^\*{0,2}stop condition:\*{0,2}/ {
    value=$0
    sub(/^\*{0,2}Stop condition:\*{0,2}[[:space:]]*/, "", value)
    if (value != "") { print value; exit }
    capture=1
    next
  }
  capture && $0 ~ /[^[:space:]]/ {
    value=$0
    sub(/^[[:space:]]*[-*][[:space:]]*/, "", value)
    print value
    exit
  }
' "$context_text_path")"

set +e
tools/repo_preflight.sh --json --output "$repo_packet_path" >/dev/null
repo_status=$?
set -e
[[ "$repo_status" -ne 2 && "$repo_status" -ne 3 && "$repo_status" -ne 4 ]] || exit "$repo_status"

production_paths="$(awk '/^Sources\// { print }' "$mentioned_paths_path" | jq -Rsc 'split("\n") | map(select(length > 0))')"
test_paths="$(awk '/^Tests\// { print }' "$mentioned_paths_path" | jq -Rsc 'split("\n") | map(select(length > 0))')"
documentation_paths="$(awk '/^docs\// { print }' "$mentioned_paths_path" | jq -Rsc 'split("\n") | map(select(length > 0))')"

issue_status="$(jq -r '.state' "$issue_json_path")"
issue_title="$(jq -r '.title' "$issue_json_path")"
issue_url="$(jq -r '.url' "$issue_json_path")"
label_names="$(jq -c '[.labels[]?.name]' "$issue_json_path")"
finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --argjson issue "$(jq '{number,title,body_path: null,state,url,labels:[.labels[]?.name],comments_count:(.comments | length),assignees:[.assignees[]?.login],milestone:(.milestone.title // null)}' "$issue_json_path")" \
  --arg issue_body_path "$issue_text_path" \
  --arg comments_path "$comments_path" \
  --arg repository "$repository" \
  --arg branch "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD')" \
  --arg revision "$head" \
  --arg parent_issue "$parent_issue" \
  --argjson dependencies "$dependency_issues" \
  --arg progress "$progress_path" \
  --arg progress_section "$progress_section_path" \
  --argjson production "$production_paths" \
  --argjson tests "$test_paths" \
  --argjson docs "$documentation_paths" \
  --argjson validation "$(jq -Rsc 'split("\n") | map(select(length > 0))' "$mentioned_commands_path")" \
  --arg stop_condition "$stop_condition" \
  --arg repo_packet "$repo_packet_path" \
  --arg started "$started_at" \
  --arg finished "$finished_at" \
  --arg output "$output_dir" \
  --argjson repo_exit "$repo_status" \
  '{schema_version: 1, status: (if ($parent_issue == "" or ($validation | length) == 0 or $stop_condition == "") then "attention" else "passed" end),
    repository: $repository, branch: $branch, revision: $revision,
    issue: ($issue + {body_path: $issue_body_path, comments_path: $comments_path}),
    parent_issue: (if $parent_issue == "" then null else ($parent_issue | tonumber) end),
    dependency_issues: $dependencies,
    scope: {production_files: $production, test_files: $tests, documentation_files: $docs,
      source: "issue/progress mentioned paths; not authoritative inference"},
    progress: {path: $progress, section: $progress_section},
    validation: $validation, stop_condition: (if $stop_condition == "" then null else $stop_condition end),
    repository_packet: $repo_packet, repository_preflight_exit: $repo_exit,
    started_at: $started, finished_at: $finished, artifact: ($output + "/result.json"), errors: []}' \
  > "$result_path"

if [[ "$json_mode" -eq 1 ]]; then
  jq -c . "$result_path"
elif [[ "$quiet" -eq 0 ]]; then
  jq -r '"Arcus Signal issue context complete.

  - Issue: #\(.issue.number) \(.issue.title)
  - Repository: \(.repository)
  - Status: \(.status)
  - Parent: \(.parent_issue // "none")
  - Validation commands: \(.validation | length)
  - Artifact: \(.artifact)"' "$result_path"
else
  printf '%s\n' "$result_path"
fi

if [[ "$(jq -r '.status' "$result_path")" == "attention" ]]; then
  exit 1
fi

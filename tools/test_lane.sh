#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test_lane.sh (--filter REGEX ... | --full) [options]

Run one explicit SwiftPM validation lane and preserve inspectable evidence.

Options:
  --filter REGEX       Run one matching SwiftPM test filter. Repeatable.
  --full               Run the complete SwiftPM test suite.
  --no-parallel        Pass --no-parallel to SwiftPM.
  --configuration NAME SwiftPM configuration (debug or release).
  --output DIR         Directory for logs and result.json.
  --help               Show this help.

Filters run sequentially and stop after the first failure. Commands are never
retried automatically. The repository and its tracked files are not modified.
EOF
}

json_array_from_lines() {
  if [[ ! -s "$1" ]]; then
    printf '[]'
  else
    jq -Rsc 'split("\n") | map(select(length > 0))' "$1"
  fi
}

classify_failure() {
  local log_path="$1"
  if rg -q -i 'not accessible or not writable|operation not permitted|unable to load standard library|could not resolve dependencies|failed to clone|failed to fetch|network is unreachable|no such file or directory' "$log_path"; then
    printf 'unavailable'
    return
  fi
  if rg -q -i 'test run with .* failed|tests? failed|test case .* failed|failures?:' "$log_path"; then
    printf 'test_failed'
  else
    printf 'compile_failed'
  fi
}

filters=()
full_mode=0
no_parallel=0
configuration="debug"
output_dir=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --filter)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--filter requires a value' >&2; exit 2; }
      [[ -n "$2" ]] || { printf '%s\n' '--filter cannot be empty' >&2; exit 2; }
      filters+=("$2")
      shift 2
      ;;
    --full)
      full_mode=1
      shift
      ;;
    --no-parallel)
      no_parallel=1
      shift
      ;;
    --configuration)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--configuration requires a value' >&2; exit 2; }
      case "$2" in
        debug|release) configuration="$2" ;;
        *) printf 'Unsupported configuration: %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || { printf '%s\n' '--output requires a value' >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$full_mode" -eq 1 && "${#filters[@]}" -gt 0 ]]; then
  printf '%s\n' '--full cannot be combined with --filter' >&2
  exit 2
fi
if [[ "$full_mode" -eq 0 && "${#filters[@]}" -eq 0 ]]; then
  printf '%s\n' 'Provide --full or at least one --filter.' >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || { printf '%s\n' 'Required command not found: git' >&2; exit 3; }
command -v swift >/dev/null 2>&1 || { printf '%s\n' 'Required command not found: swift' >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'Required command not found: jq' >&2; exit 3; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { printf '%s\n' 'Not inside a Git repository.' >&2; exit 3; }
cd "$repo_root"

if [[ -z "$output_dir" ]]; then
  output_dir="$(mktemp -d /private/tmp/arcus-validation.XXXXXX)"
else
  mkdir -p "$output_dir"
fi

head="$(git rev-parse HEAD 2>/dev/null || true)"
swift_version="$(swift --version 2>&1 | head -n 1)"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
command_log="$output_dir/commands.txt"
stdout_log="$output_dir/stdout.log"
stderr_log="$output_dir/stderr.log"
: > "$command_log"
: > "$stdout_log"
: > "$stderr_log"

lane_status="passed"
exit_code=0
executed=0
passed=0
failed=0
test_count_executed=0
test_count_passed=0
test_count_failed=0
lane_index=0

run_lane() {
  local filter="$1"
  local lane_log="$output_dir/lane-${lane_index}.log"
  local lane_stdout="$output_dir/lane-${lane_index}.stdout.log"
  local lane_stderr="$output_dir/lane-${lane_index}.stderr.log"
  local -a command=(swift test
    --configuration "$configuration"
    --scratch-path "$output_dir/.build"
    --cache-path "$output_dir/swiftpm-cache"
    --config-path "$output_dir/swiftpm-config"
    --security-path "$output_dir/swiftpm-security")
  [[ "$no_parallel" -eq 1 ]] && command+=(--no-parallel)
  [[ -n "$filter" ]] && command+=(--filter "$filter")

  printf '%q ' "${command[@]}" | sed 's/ $//' >> "$command_log"
  printf '\n' >> "$command_log"

  set +e
  SWIFT_MODULE_CACHE_PATH="$output_dir/swift-module-cache" \
    CLANG_MODULE_CACHE_PATH="$output_dir/clang-module-cache" \
    "${command[@]}" >"$lane_stdout" 2>"$lane_stderr"
  local command_status=$?
  set -e
  cat "$lane_stdout" >> "$stdout_log"
  cat "$lane_stderr" >> "$stderr_log"
  cat "$lane_stdout" "$lane_stderr" > "$lane_log"

  local summary_line=""
  summary_line="$(rg -i 'Test run with [0-9]+ tests? in .* (passed|failed)' "$lane_log" | tail -n 1 || true)"
  if [[ "$summary_line" =~ Test[[:space:]]run[[:space:]]with[[:space:]]([0-9]+)[[:space:]]tests? ]]; then
    test_count_executed=$((test_count_executed + BASH_REMATCH[1]))
    test_count_passed=$((test_count_passed + $(rg -c -i 'Test ".*" passed' "$lane_log" || printf '0')))
    test_count_failed=$((test_count_failed + $(rg -c -i 'Test ".*" failed' "$lane_log" || printf '0')))
  fi

  if [[ "$command_status" -eq 0 && "$summary_line" =~ Test[[:space:]]run[[:space:]]with[[:space:]]0[[:space:]]tests? ]] || \
     [[ "$command_status" -eq 0 && -z "$summary_line" ]]; then
    lane_status="unavailable"
    failed=$((failed + 1))
    exit_code=4
  elif [[ "$command_status" -eq 0 ]]; then
    lane_status="passed"
    passed=$((passed + 1))
  else
    lane_status="$(classify_failure "$lane_log")"
    failed=$((failed + 1))
    exit_code="$command_status"
  fi
  executed=$((executed + 1))
  lane_index=$((lane_index + 1))
  return "$command_status"
}

if [[ "$full_mode" -eq 1 ]]; then
  run_lane "" || true
else
  for filter in "${filters[@]}"; do
    run_lane "$filter" || break
  done
fi

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result_path="$output_dir/result.json"
jq -n \
  --arg status "$lane_status" \
  --arg revision "$head" \
  --arg started "$started_at" \
  --arg finished "$finished_at" \
  --arg configuration "$configuration" \
  --arg root "$repo_root" \
  --arg swift "$swift_version" \
  --arg output "$output_dir" \
  --argjson executed "$executed" \
  --argjson passed "$passed" \
  --argjson failed "$failed" \
  --argjson exit_code "$exit_code" \
  --argjson test_count_executed "$test_count_executed" \
  --argjson test_count_passed "$test_count_passed" \
  --argjson test_count_failed "$test_count_failed" \
  --slurpfile commands <(json_array_from_lines "$command_log") \
  '{schema_version: 1, status: $status, revision: $revision, repository_root: $root,
    commands: $commands[0],
    lanes: {executed: $executed, passed: $passed, failed: $failed},
    tests: {executed: $test_count_executed, passed: $test_count_passed, failed: $test_count_failed},
    exit_code: $exit_code, configuration: $configuration, started_at: $started,
    finished_at: $finished, swift_version: $swift, output_directory: $output,
    log: ($output + "/stdout.log"), stderr: ($output + "/stderr.log"),
    result: ($output + "/result.json")}' > "$result_path"

jq -c '{status, revision, commands, tests, exit_code, log, result}' "$result_path"
exit "$exit_code"

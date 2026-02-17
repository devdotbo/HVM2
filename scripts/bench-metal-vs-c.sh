#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Compare HVM2 C and Metal runtimes on realistic workloads.

Usage:
  scripts/bench-metal-vs-c.sh [--preset realistic|stress|all] [program.hvm ...]

Environment:
  REPEATS      Number of measured runs per backend (default: 3)
  WARMUP       Number of warmup runs per backend (default: 1)
  RUN_TIMEOUT  Per-run timeout in seconds; 0 disables timeout (default: 120)
  HVM_BIN      Path to hvm binary (default: target/release/hvm)
  SKIP_BUILD   Set to 1 to skip cargo build --release (default: 0)

Presets:
  realistic    Heavy workloads that currently run on Metal by default.
  stress       Very heavy workloads that may timeout or hit resource limits.
  all          realistic + stress.

Examples:
  scripts/bench-metal-vs-c.sh
  REPEATS=1 WARMUP=0 scripts/bench-metal-vs-c.sh --preset realistic
  RUN_TIMEOUT=30 scripts/bench-metal-vs-c.sh --preset stress
  scripts/bench-metal-vs-c.sh examples/sort_bitonic/main.hvm
USAGE
}

preset_programs() {
  local preset="$1"
  case "$preset" in
    realistic)
      cat <<'LIST'
examples/sum_rec/main.hvm
examples/sort_bitonic/main.hvm
benchmarks/metal/sum_tree_depth18.hvm
LIST
      ;;
    stress)
      cat <<'LIST'
examples/sort_radix/main.hvm
examples/stress/main.hvm
examples/sum_tree/main.hvm
LIST
      ;;
    all)
      cat <<'LIST'
examples/sum_rec/main.hvm
examples/sort_bitonic/main.hvm
benchmarks/metal/sum_tree_depth18.hvm
examples/sort_radix/main.hvm
examples/stress/main.hvm
examples/sum_tree/main.hvm
LIST
      ;;
    *)
      echo "Unknown preset: $preset" >&2
      return 1
      ;;
  esac
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPEATS="${REPEATS:-3}"
WARMUP="${WARMUP:-1}"
RUN_TIMEOUT="${RUN_TIMEOUT:-120}"
SKIP_BUILD="${SKIP_BUILD:-0}"
HVM_BIN="${HVM_BIN:-$ROOT_DIR/target/release/hvm}"

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || ! [[ "$WARMUP" =~ ^[0-9]+$ ]] || ! [[ "$RUN_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "REPEATS, WARMUP and RUN_TIMEOUT must be non-negative integers." >&2
  exit 1
fi
if [[ "$REPEATS" -eq 0 ]]; then
  echo "REPEATS must be greater than 0." >&2
  exit 1
fi

total_runs=$((WARMUP + REPEATS))

if [[ "$SKIP_BUILD" != "1" ]]; then
  cargo build --release >/dev/null
fi

if [[ ! -x "$HVM_BIN" ]]; then
  echo "hvm binary not found or not executable at: $HVM_BIN" >&2
  exit 1
fi

if ! "$HVM_BIN" --help | grep -q "run-metal"; then
  echo "This hvm binary does not expose run-metal. Build a Metal-enabled HVM2 binary first." >&2
  exit 1
fi

PRESET="realistic"
declare -a CLI_PROGRAMS=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --preset)
      shift
      if [[ -z "${1:-}" ]]; then
        echo "--preset requires a value." >&2
        exit 1
      fi
      PRESET="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      CLI_PROGRAMS+=("$1")
      ;;
  esac
  shift
done

declare -a PROGRAMS=()
if [[ "${#CLI_PROGRAMS[@]}" -gt 0 ]]; then
  PROGRAMS=("${CLI_PROGRAMS[@]}")
else
  while IFS= read -r line; do
    [[ -n "$line" ]] && PROGRAMS+=("$line")
  done < <(preset_programs "$PRESET")
fi

resolve_program() {
  local program="$1"
  if [[ -f "$program" ]]; then
    printf "%s\n" "$program"
    return 0
  fi
  if [[ -f "$ROOT_DIR/$program" ]]; then
    printf "%s\n" "$ROOT_DIR/$program"
    return 0
  fi
  return 1
}

mean_col() {
  local file="$1"
  local col="$2"
  awk -v col="$col" '{sum += $col} END {printf "%.6f", sum / NR}' "$file"
}

median_col() {
  local file="$1"
  local col="$2"
  cut -f"$col" "$file" | sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) {
        print "nan"
      } else if (NR % 2 == 1) {
        printf "%.6f", a[(NR + 1) / 2]
      } else {
        printf "%.6f", (a[NR / 2] + a[NR / 2 + 1]) / 2
      }
    }
  '
}

RUN_STATUS=0
RUN_OUTPUT=""
run_backend() {
  local backend="$1"
  local program="$2"
  if [[ "$RUN_TIMEOUT" -gt 0 ]]; then
    set +e
    RUN_OUTPUT="$(perl -e 'alarm shift @ARGV; exec @ARGV' "$RUN_TIMEOUT" "$HVM_BIN" "$backend" "$program" 2>&1)"
    RUN_STATUS=$?
    set -e
  else
    set +e
    RUN_OUTPUT="$("$HVM_BIN" "$backend" "$program" 2>&1)"
    RUN_STATUS=$?
    set -e
  fi
}

sanitize_cell() {
  local val="$1"
  val="${val//$'\r'/}"
  val="${val//$'\n'/ }"
  val="${val//|/\\|}"
  printf "%s" "$val"
}

failure_note() {
  local status="$1"
  local output="$2"
  local line=""

  if [[ "$status" -eq 142 ]]; then
    printf "timeout(%ss)" "$RUN_TIMEOUT"
    return
  fi

  line="$(printf "%s\n" "$output" | awk '/Metal runtime error|runtime not available|supports only Apple Silicon|built without Metal runtime support|panicked at|failed to/{print; exit}')"
  if [[ -z "$line" ]]; then
    line="$(printf "%s\n" "$output" | awk 'NF {print; exit}')"
  fi
  if [[ -z "$line" ]]; then
    line="exit=$status"
  else
    line="exit=$status: $line"
  fi
  sanitize_cell "$line"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hvm-metal-bench-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Benchmark settings:"
echo "  hvm binary : $HVM_BIN"
echo "  preset     : $PRESET"
echo "  warmup     : $WARMUP"
echo "  repeats    : $REPEATS"
echo "  timeout    : ${RUN_TIMEOUT}s (0 disables)"
echo "  total runs : $total_runs"
echo

echo "Programs:"
for program_input in "${PROGRAMS[@]}"; do
  echo "  - $program_input"
done
echo

echo "| program | backend | n | status | mean time (s) | median time (s) | mean mips | mean itrs |"
echo "|---|---|---:|---|---:|---:|---:|---:|"

for program_input in "${PROGRAMS[@]}"; do
  if ! program="$(resolve_program "$program_input")"; then
    printf "| %s | run-c | 0 | FAIL (program not found) | - | - | - | - |\n" "$(sanitize_cell "$program_input")"
    printf "| %s | run-metal | 0 | FAIL (program not found) | - | - | - | - |\n" "$(sanitize_cell "$program_input")"
    printf "| %s | speedup (C/Metal) | - | SKIP | n/a | - | - | - |\n" "$(sanitize_cell "$program_input")"
    continue
  fi

  c_ok=0
  m_ok=0
  c_time=""
  m_time=""

  for backend in run-c run-metal; do
    result_file="$tmp_dir/$(basename "$program").${backend}.tsv"
    : > "$result_file"

    backend_ok=1
    backend_note=""

    for idx in $(seq 1 "$total_runs"); do
      run_backend "$backend" "$program"
      if [[ "$RUN_STATUS" -ne 0 ]]; then
        backend_ok=0
        backend_note="$(failure_note "$RUN_STATUS" "$RUN_OUTPUT")"
        break
      fi

      time_s="$(printf "%s\n" "$RUN_OUTPUT" | awk '/^- TIME:/ {gsub(/s$/, "", $3); print $3; exit}')"
      mips="$(printf "%s\n" "$RUN_OUTPUT" | awk '/^- MIPS:/ {print $3; exit}')"
      itrs="$(printf "%s\n" "$RUN_OUTPUT" | awk '/^- ITRS:/ {print $3; exit}')"

      if [[ -z "$time_s" || -z "$mips" || -z "$itrs" ]]; then
        backend_ok=0
        backend_note="could not parse runtime stats"
        break
      fi

      if [[ "$idx" -gt "$WARMUP" ]]; then
        printf "%s\t%s\t%s\n" "$time_s" "$mips" "$itrs" >> "$result_file"
      fi
    done

    if [[ "$backend_ok" -eq 1 ]]; then
      mean_time="$(mean_col "$result_file" 1)"
      median_time="$(median_col "$result_file" 1)"
      mean_mips="$(mean_col "$result_file" 2)"
      mean_itrs="$(mean_col "$result_file" 3)"

      if [[ "$backend" == "run-c" ]]; then
        c_ok=1
        c_time="$mean_time"
      else
        m_ok=1
        m_time="$mean_time"
      fi

      printf "| %s | %s | %s | OK | %s | %s | %s | %.0f |\n" \
        "$(sanitize_cell "$program_input")" "$backend" "$REPEATS" "$mean_time" "$median_time" "$mean_mips" "$mean_itrs"
    else
      printf "| %s | %s | 0 | FAIL (%s) | - | - | - | - |\n" \
        "$(sanitize_cell "$program_input")" "$backend" "$(sanitize_cell "$backend_note")"
    fi
  done

  if [[ "$c_ok" -eq 1 && "$m_ok" -eq 1 ]]; then
    speedup="$(awk -v c="$c_time" -v m="$m_time" 'BEGIN { if (m == 0) { print "inf" } else { printf "%.3fx", c / m } }')"
    printf "| %s | speedup (C/Metal) | - | OK | %s | - | - | - |\n" "$(sanitize_cell "$program_input")" "$speedup"
  else
    printf "| %s | speedup (C/Metal) | - | SKIP | n/a | - | - | - |\n" "$(sanitize_cell "$program_input")"
  fi
done

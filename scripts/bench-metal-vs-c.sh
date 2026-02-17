#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Compare HVM2 C and Metal runtimes on one or more .hvm programs.

Usage:
  scripts/bench-metal-vs-c.sh [program.hvm ...]

Environment:
  REPEATS    Number of measured runs per backend (default: 5)
  WARMUP     Number of warmup runs per backend (default: 1)
  HVM_BIN    Path to hvm binary (default: target/release/hvm)
  SKIP_BUILD Set to 1 to skip cargo build --release (default: 0)

Examples:
  scripts/bench-metal-vs-c.sh examples/sum_rec/main.hvm
  REPEATS=3 WARMUP=0 scripts/bench-metal-vs-c.sh tests/programs/hello-world.hvm
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPEATS="${REPEATS:-5}"
WARMUP="${WARMUP:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
HVM_BIN="${HVM_BIN:-$ROOT_DIR/target/release/hvm}"

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || ! [[ "$WARMUP" =~ ^[0-9]+$ ]]; then
  echo "REPEATS and WARMUP must be non-negative integers." >&2
  exit 1
fi
if [[ "$REPEATS" -eq 0 ]]; then
  echo "REPEATS must be greater than 0." >&2
  exit 1
fi

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

declare -a PROGRAMS
if [[ "$#" -eq 0 ]]; then
  PROGRAMS=("examples/sum_rec/main.hvm")
else
  PROGRAMS=("$@")
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

total_runs=$((WARMUP + REPEATS))
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hvm-metal-bench-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Benchmark settings:"
echo "  hvm binary : $HVM_BIN"
echo "  warmup     : $WARMUP"
echo "  repeats    : $REPEATS"
echo "  total runs : $total_runs"
echo

echo "| program | backend | n | mean time (s) | median time (s) | mean mips | mean itrs |"
echo "|---|---|---:|---:|---:|---:|---:|"

for program_input in "${PROGRAMS[@]}"; do
  if ! program="$(resolve_program "$program_input")"; then
    echo "Program not found: $program_input" >&2
    exit 1
  fi

  for backend in run-c run-metal; do
    result_file="$tmp_dir/$(basename "$program").${backend}.tsv"
    : > "$result_file"

    for idx in $(seq 1 "$total_runs"); do
      set +e
      output="$("$HVM_BIN" "$backend" "$program" 2>&1)"
      status=$?
      set -e
      if [[ "$status" -ne 0 ]]; then
        echo "Benchmark run failed: $backend $program (exit=$status)" >&2
        echo "$output" >&2
        exit "$status"
      fi

      time_s="$(printf "%s\n" "$output" | awk '/^- TIME:/ {gsub(/s$/, "", $3); print $3; exit}')"
      mips="$(printf "%s\n" "$output" | awk '/^- MIPS:/ {print $3; exit}')"
      itrs="$(printf "%s\n" "$output" | awk '/^- ITRS:/ {print $3; exit}')"

      if [[ -z "$time_s" || -z "$mips" || -z "$itrs" ]]; then
        echo "Could not parse runtime stats from output for $backend $program" >&2
        echo "$output" >&2
        exit 1
      fi

      if [[ "$idx" -gt "$WARMUP" ]]; then
        printf "%s\t%s\t%s\n" "$time_s" "$mips" "$itrs" >> "$result_file"
      fi
    done

    mean_time="$(mean_col "$result_file" 1)"
    median_time="$(median_col "$result_file" 1)"
    mean_mips="$(mean_col "$result_file" 2)"
    mean_itrs="$(mean_col "$result_file" 3)"

    printf "| %s | %s | %s | %s | %s | %s | %.0f |\n" \
      "$program_input" "$backend" "$REPEATS" "$mean_time" "$median_time" "$mean_mips" "$mean_itrs"
  done

  c_time="$(mean_col "$tmp_dir/$(basename "$program").run-c.tsv" 1)"
  m_time="$(mean_col "$tmp_dir/$(basename "$program").run-metal.tsv" 1)"
  speedup="$(awk -v c="$c_time" -v m="$m_time" 'BEGIN { if (m == 0) { print "inf" } else { printf "%.3fx", c / m } }')"
  printf "| %s | speedup (C/Metal) | - | %s | - | - | - |\n" "$program_input" "$speedup"
done

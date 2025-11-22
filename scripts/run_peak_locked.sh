#!/usr/bin/env bash
set -euo pipefail
OUTDIR=/tmp/bchan_spsc_peak_$(date +%s)
mkdir -p "$OUTDIR"

echo "Logs -> $OUTDIR"

PERF_EVENTS=(cycles instructions branches branch-misses L1-dcache-loads L1-dcache-load-misses cache-references cache-misses context-switches)
PERF_EVENTS_ARG=$(IFS=,; echo "${PERF_EVENTS[*]}")

REPEATS=7
DURATION=35
BATCH=64

OLD_GOVERNORS="$OUTDIR/old_governors.txt"
SHIELDED=0

function save_governors() {
  : > "$OLD_GOVERNORS"
  for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu=$(basename "$cpu_dir")
    gov_file="$cpu_dir/cpufreq/scaling_governor"
    if [ -f "$gov_file" ]; then
      gov=$(cat "$gov_file")
      echo "$cpu $gov" >> "$OLD_GOVERNORS"
    fi
  done
}

function restore_governors() {
  if [ -f "$OLD_GOVERNORS" ]; then
    while read -r cpu gov; do
      gov_file="/sys/devices/system/cpu/${cpu}/cpufreq/scaling_governor"
      if [ -f "$gov_file" ]; then
        echo "$gov" > "$gov_file" || true
      fi
    done < "$OLD_GOVERNORS"
  fi
}

function cleanup() {
  echo "Restoring governors..."
  restore_governors
  if [ "$SHIELDED" -eq 1 ]; then
    if command -v cset >/dev/null 2>&1; then
      echo "Resetting cset shield..."
      cset shield --reset || true
    fi
  fi
}

trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root to set governors and (optionally) cset shielding."
  echo "Rerun with: sudo $0" | tee "$OUTDIR/error.txt"
  exit 1
fi

echo "Saving current governors to $OLD_GOVERNORS"
save_governors

if command -v cpupower >/dev/null 2>&1; then
  echo "Setting cpupower governor to performance"
  cpupower frequency-set -g performance || true
else
  echo "Setting scaling_governor files to 'performance'"
  for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    gov_file="$cpu_dir/cpufreq/scaling_governor"
    if [ -f "$gov_file" ]; then
      echo performance > "$gov_file" || true
    fi
  done
fi

if command -v cset >/dev/null 2>&1; then
  echo "Creating cset shield for CPUs 0,1"
  cset shield --cpu=0,1 --threads
  SHIELDED=1
fi

echo "Running perf stat repeated measurements (r=${REPEATS}) for ${DURATION}s, batch=${BATCH}"
echo "perf events: $PERF_EVENTS_ARG"

CMD=(taskset -c 0,1 perf stat -e "$PERF_EVENTS_ARG" -r "$REPEATS" ./zig-out/bin/bench-simple-spsc-batched -- "$DURATION" "$BATCH")

echo "Running: ${CMD[*]}" | tee "$OUTDIR/peak_cmd.txt"
# Run and capture output
"${CMD[@]}" 2>&1 | tee "$OUTDIR/peak.log"

echo "Peak run complete. Logs in $OUTDIR"


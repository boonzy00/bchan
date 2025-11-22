#!/usr/bin/env bash
#!/usr/bin/env bash
#!/usr/bin/env bash
set -euo pipefail

# run_scaling_locked.sh
# Run batched SPSC bench for a set of batch sizes under locked CPU governor / shield.
# MUST be run as root to set governors and cset shielding. If not run as root, the
# script will instruct the user to re-run with sudo.

OUTDIR=/tmp/bchan_scaling_locked_$(date +%s)
mkdir -p "$OUTDIR"

echo "Logs -> $OUTDIR"

BATCHES=(1 4 16 64 256)
DURATION=30

if [ "$(id -u)" -ne 0 ]; then
  echo "This script should be run as root to ensure stable frequency and shielding."
  echo "Rerun with: sudo $0" | tee "$OUTDIR/error.txt"
  exit 1
fi

echo "Setting governors to performance (best-effort)"
#!/usr/bin/env bash
#!/usr/bin/env bash
#!/usr/bin/env bash
set -euo pipefail

# run_scaling_locked.sh
# Run batched SPSC bench for a set of batch sizes under locked CPU governor / shield.
# MUST be run as root to set governors and cset shielding. If not run as root, the
# script will instruct the user to re-run with sudo.

OUTDIR=/tmp/bchan_scaling_locked_$(date +%s)
mkdir -p "$OUTDIR"

echo "Logs -> $OUTDIR"

BATCHES=(1 4 16 64 256)
DURATION=30

if [ "$(id -u)" -ne 0 ]; then
  echo "This script should be run as root to ensure stable frequency and shielding."
  echo "Rerun with: sudo $0" | tee "$OUTDIR/error.txt"
  exit 1
fi

echo "Setting governors to performance (best-effort)"
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g performance || true
else
  for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    gov_file="$cpu_dir/cpufreq/scaling_governor"
    if [ -f "$gov_file" ]; then
      echo performance > "$gov_file" || true
    fi
  done
fi

if command -v cset >/dev/null 2>&1; then
  echo "Applying cset shield for CPUs 0,1"
  cset shield --cpu=0,1 --threads || true
fi

for b in "${BATCHES[@]}"; do
  echo "=== batch $b ===" | tee -a "$OUTDIR/scaling_locked.log"
  taskset -c 0,1 ./zig-out/bin/bench-simple-spsc-batched -- "$DURATION" "$b" 2>&1 | tee -a "$OUTDIR/scaling_locked.log"
done

echo "Scaling runs complete. Logs in $OUTDIR"

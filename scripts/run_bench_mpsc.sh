#!/usr/bin/env bash
set -euo pipefail
OUTDIR=/tmp/mpsc_runs_$(date +%s)
mkdir -p "$OUTDIR"
VALFILE="$OUTDIR/values.txt"
rm -f "$VALFILE"
for i in 1 2 3 4 5; do
  echo "--- run $i ---" | tee -a "$OUTDIR/run.log"
  echo "taskset -c 0-7 perf stat -d -r1 ./zig-out/bin/bench-mpsc" | tee -a "$OUTDIR/run.log"
  timeout 300s taskset -c 0-7 perf stat -d -r1 ./zig-out/bin/bench-mpsc 2>&1 | tee -a "$OUTDIR/run.log"
  # extract throughput from bench output
  val=$(grep "Batch.*M msg/s" "$OUTDIR/run.log" | tail -n1 | grep -oE "[0-9]+\.[0-9]+" || true)
  if [ -n "$val" ]; then
    echo "$val" >> "$VALFILE"
  fi
done

echo
if [ -s "$VALFILE" ]; then
  echo "Values:"; cat "$VALFILE"
  awk '{sum+=$1; sumsq+=$1*$1} END {n=NR; mean=sum/n; sd=sqrt(sumsq/n - mean*mean); printf "mean=%.2f M msg/s  sd=%.2f  n=%d\n", mean, sd, n}' "$VALFILE"
else
  echo "No numeric values collected"
fi

echo "Logs: $OUTDIR"

#!/usr/bin/env bash
set -euo pipefail
OUTDIR=/tmp/bchan_bench_runs_$(date +%s)
mkdir -p "$OUTDIR"
BENCHES=("./zig-out/bin/bench-spsc" "./zig-out/bin/bench-mpsc" "./zig-out/bin/bench-mpsc-vyukov")
CNT=5
CORES=0-7

for b in "${BENCHES[@]}"; do
  base=$(basename "$b")
  
  echo "=== BENCH: $base ===" | tee "$OUTDIR/$base.log"
  for i in $(seq 1 $CNT); do
    echo "-- run $i --" | tee -a "$OUTDIR/$base.log"
    echo "Running: taskset -c $CORES perf stat -d -r1 $b" | tee -a "$OUTDIR/$base.log"
    timeout 300s taskset -c $CORES perf stat -d -r1 "$b" 2>&1 | tee -a "$OUTDIR/$base.log"
    val=$(grep -oE '[0-9]+\.[0-9]+' "$OUTDIR/$base.log" | tail -n1 || true)
    if [ -n "$val" ]; then
      echo "$val" >> "$OUTDIR/${base}_values.txt"
    fi
  done
  if [ -s "$OUTDIR/${base}_values.txt" ]; then
    awk '{sum+=$1; sumsq+=$1*$1} END {n=NR; mean=sum/n; sd=sqrt(sumsq/n - mean*mean); printf "mean=%.2f M msg/s  sd=%.2f  n=%d\n", mean, sd, n}' "$OUTDIR/${base}_values.txt" | tee -a "$OUTDIR/$base.log"
  fi
done

echo "All done. Results in: $OUTDIR"

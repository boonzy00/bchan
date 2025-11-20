#!/usr/bin/env bash
set -euo pipefail
OUTFILE=/tmp/vyukov_vals.txt
rm -f "$OUTFILE"
for i in 1 2 3 4 5; do
  echo "--- Run $i ---"
  ./zig-out/bin/bench-mpsc-vyukov 2>&1 | tee /tmp/vyukov_run_${i}.log
  val=$(grep -oE '[0-9]+\.[0-9]+' /tmp/vyukov_run_${i}.log | head -1 || true)
  if [ -n "${val}" ]; then
    echo "$val" >> "$OUTFILE"
  else
    echo "(no numeric result)"
  fi
done

echo
if [ -s "$OUTFILE" ]; then
  echo "Collected values:"
  cat "$OUTFILE"
  awk '{sum+=$1; sumsq+=$1*$1} END {n=NR; mean=sum/n; sd=sqrt(sumsq/n - mean*mean); printf "mean=%.2f M msg/s  sd=%.2f  n=%d\n", mean, sd, n}' "$OUTFILE"
else
  echo "No values collected"
fi

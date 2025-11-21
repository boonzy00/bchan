#!/usr/bin/env bash
set -euo pipefail

echo "Building ReleaseFast..."
zig build -Doptimize=ReleaseFast bench-mpsc

echo "Running scaling benchmark (mean of 5 runs per config)..."
echo

for p in 1 4 16 64 256 512; do
    echo "=== $p producers ==="
    sum=0
    success=0
    for i in {1..5}; do
        echo -n "run $i... "
        # pass max_producers as the 4th arg to the bench binary
        out=$(./zig-out/bin/bench-mpsc "$p" 64 100000 "$p" 2>&1) || true
        line=$(printf "%s" "$out" | grep "Batch" | tail -n1 || true)
        if [ -n "$line" ]; then
            mps=$(printf "%s" "$line" | awk '{print $(NF-2)}')
            echo "${mps} M msg/s"
            sum=$(echo "$sum + $mps" | bc -l)
            success=$((success + 1))
        else
            echo "failed or timed out"
        fi
    done
    if [ $success -gt 0 ]; then
        mean=$(echo "scale=2; $sum / $success" | bc -l)
    else
        mean=0
    fi
    echo "→ mean: $mean M msg/s (based on $success successful runs)"
    echo
done

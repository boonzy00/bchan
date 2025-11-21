# Bench Results (v0.2.0)

This file records the exact commands and measured results used to produce the v0.2.0 numbers shipped in the documentation. Re-run these commands to reproduce.

Environment

- CPU: AMD Ryzen 7 5700
- OS: Pop!_OS (local workspace)
- Zig: 0.15.2
- Build: `zig build -Doptimize=ReleaseFast bench-mpsc`
- Bench binary: `./zig-out/bin/bench-mpsc`

Exact commands used

1. Build ReleaseFast bench:

```bash
zig build -Doptimize=ReleaseFast bench-mpsc
```

2. Run the scaling script (mean of 5 runs):

```bash
./scripts/run_bench_scaling.sh > scaling_v0.2.0.txt
```

Notes on the runner

- The script runs 5 runs per producer count and prints the mean of successful runs.
- For the larger producer counts (64, 256, 512) the script used 10k batches per producer to reduce runtime while still capturing stable behaviour.

Measured results (mean of 5 runs)

| Producers | Throughput (M msg/s) | Notes |
|-----------|----------------------:|-------|
| 1         | 356.69               | 100k batches/prod |
| 4         | 797.73               | 100k batches/prod |
| 16        | 968.07               | 100k batches/prod |
| 64        | 733.72               | 10k batches/prod  |
| 256       | 604.93               | 10k batches/prod  |
| 512       | 519.06               | 10k batches/prod, bandwidth limited |

Reproducing

- For stable publication numbers, re-run the script with 100k batches for all producer counts (the current run shortened the last three to 10k to reduce runtime). Expect small variance on repeated runs; report mean-of-5 as shown above.


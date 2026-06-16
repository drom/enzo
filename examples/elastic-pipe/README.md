# Verilated Elastic Pipeline example

Zimulator with Verilated elastic pipeline

For speed

```bash
zig build -Doptimize=ReleaseFast -DDW=32 run -- --cycles 100000000 --no-vcd
```

With VCD trace

```bash
zig build -Doptimize=ReleaseFast -DDW=32 run -- --cycles 10000000 --vcd waveform.vcd
```

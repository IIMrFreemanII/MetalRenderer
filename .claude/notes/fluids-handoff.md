# Liquids: handoff to the M4 Max (2026-10-08)

Branch `claude/fluid-simulations-cb93e5`. Water, blood and honey (PBF and MLS-MPM), their surfaces rebuilt every
frame and shaded as refracting, absorbing liquids, coupled both ways with the bodies. Built and measured on the
**M1 Max (software RT, no Metal 4 ray tracing)** only. The README's "Liquids" section has the design, the costs and
the limits.

## Where things are
- `PhysicsFluid.swift` (presets, `FluidSystem`, `FluidWorld`, `addLiquid`), `PhysicsFluidCPU.swift` (the reference),
  `PhysicsFluidGPU.swift` (buffers; each group's steps as rounds, a liquid's step each, side by side),
  `Shaders/Fluid.metal`.
- `FluidSurface.swift` + `Shaders/FluidSurface.metal`: splat, blur, surface nets by scans.
- `Shaders/Liquid.metal`: `liquidKernel` (before the trace: bends the primary ray) and `liquidApplyKernel` (after
  the glass). `PathTrace.metal`: kind 5, a dielectric with a medium.
- `Scene+Fluids.swift`, bench modes `fluids` and `fluidsdemo` (`Benchmark+Modes.swift`), `FluidTests`.
- The physics pass is a **concurrent** encoder when the scene has liquids (`FrameEncoder.compute(_:serial:concurrent:)`):
  `PhysicsGPU` puts a barrier before each of its dispatches, `FluidGPU.run` one between rounds.

## M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`)
Paused at 6 s: 4.9 ms. Moving, the first 5 s: 15.0 ms; from 12 s at 16k / 32k / 64k a liquid: 19.6 / 23.6 / 26.5 ms.
The rebuilt BLAS is 4.4–5.6 ms of it.

## To do on the M4 Max
1. **Metal 4**: `METALRENDERER_BENCH=fluids` with `METALRENDERER_BENCH_ONLY=metal4` — never run. Check the
   concurrent physics pass under `Metal4Frame` (its `serial = false` path and `memoryBarrier` → `barrier()`) and the
   liquid against the Metal 3 still (`pngdiff.py`).
2. The rebuilt structures go through `Metal4Frame.updatePrimitives`' Metal 3 interlude every frame: port
   `PrimitiveRefit` to an `encode4` like `PlantTracing.Refit.encode4`, then time it.
3. Re-time the table above with hardware RT (the BLAS rebuild should shrink most).
4. Run `FluidTests` there (GPU against CPU, bit-identical replays).

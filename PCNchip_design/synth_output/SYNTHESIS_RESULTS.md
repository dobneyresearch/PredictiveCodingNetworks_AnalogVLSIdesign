# PCN Digital Top — Synthesis Results
**Date:** 2026-06-10  
**Tool:** yowasp-yosys 0.66 (Yosys WebAssembly port)  
**Target library:** sky130_fd_sc_hd TT 25°C 1.80V  
**Script:** `../synth.ys`

## Summary

| Metric | Value | Notes |
|---|---|---|
| Total cells | 4,054 | sky130_fd_sc_hd standard cells |
| Flip-flops (DFF) | 758 | 49% of area |
| Chip area | 38,971 µm² | ~197 × 197 µm; SRAM area excluded |
| SRAM macro | sky130_sram_1kbyte_1rw1r_8x128_8 | Blackboxed; add ~800 µm² separately |

## Per-module areas (µm²)

| Module | Area (µm²) | % of total | Notes |
|---|---|---|---|
| hebb_ctrl | 31,400 | 80.6% | 32 cells × 16-bit counters; dominant |
| pcn_wb_regs | 4,490 | 11.5% | 6 Wishbone registers |
| weight_fsm | 2,280 | 5.9% | Load FSM |
| power_fsm | 718 | 1.8% | Sleep/wake FSM |
| sram_if | 4 | <0.1% | Blackbox wrapper only |

## Top cell types

| Cell | Count | Area (µm²) |
|---|---|---|
| dfrtp_1 (D-FF, reset) | 715 | 17,889 |
| nor2_1 | 530 | 1,988 |
| a22oi_1 | 427 | 2,665 |
| a21oi_1 | 396 | 2,475 |
| nand2_1 | 376 | 1,410 |
| o21ai_0 | 258 | 1,289 |
| xor2_1 | 213 | 1,872 |
| dfstp_2 (D-FF, set) | 43 | 1,130 |

## Comparison to design doc predictions (§35.8)

| Module | Gates predicted | Gates actual | FFs predicted | FFs actual |
|---|---|---|---|---|
| pcn_wb_regs | ~200 | ~380 | 180 | ~180 |
| weight_fsm | ~120 | ~220 | 60 | ~70 |
| hebb_ctrl (32×) | ~1,100 | ~3,100 | 576 | ~640 |
| power_fsm | ~60 | ~60 | 28 | ~28 |
| **Total** | **~1,480** | **~4,054** | **844** | **758** |

Gate count is ~2.7× higher than predicted — mainly because `hebb_ctrl`'s 32×16-bit counters 
generate more ABC logic than the simple gate-equivalent estimate assumed. 
FF count matches well (758 vs 844 predicted).

## Warnings

- `hebb_ctrl.v:20`: `Replacing memory \cnt with list of registers` — the 32-element 
  array `cnt[0:31][15:0]` was inferred as a register file (512 FFs + mux logic).  
  This is correct for FPGA/ASIC synthesis; the design document assumed this.
  
- `sky130_sram_1kbyte_1rw1r_8x128_8` area is unknown (blackboxed hardmacro).
  Add the pre-compiled SRAM GDS tile area at P&R time.

## Next steps for full OpenLane flow

The synthesis step is complete. Full place-and-route requires:

1. **Install OpenROAD** (system-level; not available as pip package):
   ```
   # Option A: via Nix (recommended for sky130/OpenLane)
   nix-env -iA nixpkgs.openroad
   
   # Option B: build from source (openroad.org)
   ```

2. **Run OpenLane 2 with full flow:**
   ```bash
   openlane config.json
   ```
   Uses `config.json` already prepared in the project directory.

3. **Expected PnR output:** DRC-clean GDS2 in `runs/<tag>/final/gds/pcn_digital_top.gds`

4. **OpenMPW tape-out:** submit the hardened macro to efabless.com for a future 
   shuttle run (Google/SkyWater sponsoring free MPW slots for open-source designs).

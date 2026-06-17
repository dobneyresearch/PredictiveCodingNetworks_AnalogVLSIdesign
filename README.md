# PCN Chip — Analog CMOS Predictive Coding Network with On-Chip Hebbian Learning

An open-source hardware implementation of a Predictive Coding Network (PCN) in the
[SkyWater 130 nm process (Sky130A)](https://github.com/google/skywater-pdk), verified
by SPICE simulation and synthesised RTL place-and-route.

Weights are stored as voltages on 200 fF capacitors inside a five-transistor OTA.
Inference is computed by transconductance and Kirchhoff's current law.
Hebbian weight updates happen on-chip — no weight data crosses the chip boundary
during inference or learning.

A target companion arXiv preprint is in `paper/main_v3.tex` (not yet on arXiv)

Architecture designed by Saul Dobney, coded and validated using Claude Code

---

## Key results

| Metric | Value | Method |
|---|---|---|
| Single-cell gain | 6.82 V/V | SPICE (Sky130A TT 27 °C) |
| 4-layer spatial cascade gains | 1.43 / 0.45 / 0.70 / 0.54 V/V | SPICE |
| Temporal reuse gain (per VL) | 6.68 V/V | SPICE |
| ADC/DAC round-trip error | 0.50 LSB | SPICE |
| GHA prediction error reduction | 484× (single step) | Software sim |
| Template selectivity | 1.00 | Software sim |
| Digital timing slack @ 50 MHz | +8.46 ns | OpenLane P&R (Sky130A TT) |
| Projected TOPS/W at 28 nm | ~320 GOPS/W | Estimate |
| Projected TOPS/W at 7 nm | ~3.8 TOPS/W | Estimate |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  PCN Module (16 × 16)               │
│                                                     │
│  inp[0..15] ──►  MAC cell array  ──► iout[0..15]   │
│                  (5T OTA × 256)                     │
│                  Vw = f(SRAM → DAC → Cw)            │
│                  Hebbian: ΔVw per pulse             │
└────────────────────────┬────────────────────────────┘
                         │ PMOS source-follower level shift (+0.67 V)
                         ▼
                  (next layer or ADC save)

Temporal reuse: one physical array × N_virt virtual layers
  Phase 1 — ADC saves activations to SRAM
  Phase 2 — Weight DAC loads next VL weights
  Phase 3 — Input DAC replays activations (resets common mode)
  Phase 4 — Array computes; Hebbian gate fires if |ε| > θ
```

**MAC cell transistors**: MN1/MN2 differential pair (W=2/L=0.35 µm),
MP1/MP2 PMOS current mirror load (W=4/L=0.7 µm, CLM-optimised),
MN3 tail (W=10/L=0.35 µm, gate=Vw — weight sets Gm),
MN4+MP4 CMOS transmission gate (Cw access), Cw=200 fF.

---

## Repository structure

```
PCNchip_design/
│
├── pcn_mac_cell.spice          # 5T OTA MAC cell (production netlist)
├── pcn_mac_cell_v3b.spice      # Characterisation variants (Path A study)
├── pcn_array_*.spice           # Generated 4×4 / 16×16 / 16×32 / 32×32 / 32×64 arrays
├── pcn_module_*.spice          # Arrays with peripheral bias ports
├── pcn_chip_4layer.spice       # 4-layer 16×16 spatial stack
├── layer_link.spice            # PMOS SF inter-layer level shifter
├── layer_link_route_*.spice    # Routing-weight variants (4/16/32 routing cells)
├── bias_gen.spice              # Vbias_n / Vcm / Vπ generator
├── weight_dac.spice            # 8-bit R-2R weight DAC
├── inp_dac.spice               # 8-bit R-2R activation (input) DAC
│
├── tb_pcn_4layer.spice         # 4-layer cascade testbench (T1/T2/T3)
├── tb_pcn_4col_2vl.spice       # 4-column 2-VL GHA timing testbench (all PASS)
├── tb_temporal_reuse.spice     # 3-VL temporal reuse (gain 6.82 V/V)
├── tb_temporal_full.spice      # Full round-trip: inp_dac + weight_dac + array
├── tb_sram_reload.spice        # Save/load path verification
├── tb_pcn_2layer_*.spice       # 2-layer integration testbenches
├── tb_pcn_route_test.spice     # Dynamic routing weight testbench
├── tb_bias_gen.spice           # Bias generator testbench
├── tb_dvw_pulse.spice          # Hebbian pulse characterisation
│
├── gen_array.py                # Generates pcn_array_*.spice and pcn_module_*.spice
├── gen_tb_2layer.py            # Generates 2-layer testbench SPICE
├── gen_tb_4layer.py            # Generates 4-layer testbench SPICE
├── run_sim.sh                  # ngspice runner (--netlist flag for non-default)
├── plot_results.py             # Plots output CSV data
│
├── rtl/                        # Synthesisable Verilog RTL
│   ├── pcn_digital_top.v       # Top-level integration
│   ├── weight_fsm.v            # 22-state FSM (weight load, temporal reuse, ADC sweep)
│   ├── hebb_ctrl.v             # Per-row Hebbian enable, gated by HEBB_ROW_MASK
│   ├── pcn_wb_regs.v           # Wishbone register file (13 registers, base 0x3000_0000)
│   ├── sar_adc.v               # 8-bit SAR ADC (10-cycle latency)
│   ├── act_sram.v              # Activation register file (N_cells × 8-bit)
│   ├── sram_if.v               # SRAM interface
│   ├── sram_blackbox.v         # OpenRAM macro black-box wrapper
│   ├── power_fsm.v             # Sleep/wake power controller
│   ├── tb_pcn_digital_top.v    # Digital integration testbench (13/13 tests PASS)
│   └── tb_sar_adc.v            # SAR ADC testbench (11/11 tests PASS)
│
├── sim/                        # Python software simulation
│   ├── pcn_core.py             # PCNLayer + PCNTemporalStack (v1/BCM/v2 modes, 8-bit quant)
│   ├── tasks.py                # Benchmark tasks: Gaussian PCA, templates, bars/stripes
│   ├── train.py                # Training loops: train_layer, compare_modes, train_temporal
│   ├── run_sim.py              # Runs E1–E4 experiments; saves figures to sim/results/
│   ├── circuit_sim.py          # Hardware-calibrated model; 7 circuit experiments C1–C7
│   ├── run_circuit_sim.py      # Runs C1–C7; cross-validates against SPICE
│   ├── pcn_predict.py          # 2-layer GHA multi-cell PCN; 484× pred_err reduction
│   ├── pcn_mnist.py            # MNIST digit classification using hardware-faithful PCN simulation
│   └── results/                # Output figures (c1–c7, e1–e4, p_predictive_network)
│
├── pnr/                        # OpenLane place-and-route
│   ├── config.yaml             # OpenLane 2 configuration
│   ├── macro_placement.cfg     # OpenRAM SRAM macro placement
│   └── src/                    # RTL sources for P&R (mirrors rtl/ minus testbenches)
│
├── synth_output/               # Yosys synthesis results
│   ├── pcn_digital_top_synth.v # Post-synthesis netlist
│   └── SYNTHESIS_RESULTS.md    # Cell count, area, timing summary
│
├── magic/                      # Analog layout (in progress)
│   ├── mac_cell.mag            # MAC cell Magic layout (layer names corrected)
│   ├── mac_cell_seed.tcl       # Seed script for Magic (3200×2200 units = 16×11 µm)
│   ├── Makefile                # make seed → opens Magic; make drc / make lvs
│   └── SETUP.md                # Magic version requirements and build instructions
│
├── xschem/                     # Schematic capture
│   ├── mac_cell.sch            # MAC cell schematic
│   ├── mac_cell.sym            # MAC cell symbol
│   └── mac_cell_tb.sch         # MAC cell testbench schematic
│
├── paper/                      # ArXiv preprint
│   ├── main_v3.tex             # Current submission draft (IEEEtran, 10 pages)
│   ├── refs.bib                # Bibliography (19 entries)
│   └── main_v3.pdf             # Compiled PDF
│
├── pred_code_networks.md       # Full design journal (~10,500 lines; §1–§75)
├── FeFET_7nm_discussion.md     # Weight storage options: MIM cap, FeFET, PCM, RRAM, WSI
├── sky130_summary.md           # Sky130A process design overview
├── simulations_summary.md      # Python software simulation summary: MNIST, EMNIST
├── PCN_versus_spiking.md       # Comparison of PCN and Spiking Neural Nets approaches
├── quickstart.md               # Quick-start guide for running simulations
└── config.json                 # OpenLane project configuration
```

---

## Prerequisites

### SPICE simulation
```bash
sudo apt install ngspice
```
Requires the [SkyWater 130 nm PDK](https://github.com/google/skywater-pdk) installed
via [volare](https://github.com/efabless/volare):
```bash
pip install volare
volare enable --pdk sky130 0fe599b2
export PDK_ROOT=~/.volare
```

### RTL simulation
```bash
sudo apt install iverilog
```

### Python software simulation
```bash
pip install numpy matplotlib scipy
```

### Place and route
[OpenLane 2](https://openlane2.readthedocs.io) via Docker:
```bash
docker pull ghcr.io/efabless/openlane2:2.3.10
```

### Analog layout
Magic 8.3.411 or later (build from source — see `magic/SETUP.md`):
```bash
git clone https://github.com/RTimothyEdwards/magic
cd magic && ./configure && make -j$(nproc) && sudo make install
```

---

## Running simulations

### SPICE — 4-layer cascade
```bash
cd PCNchip_design
PDK=~/.volare/sky130/versions/0fe599b2/sky130A
sed "s|\$PDK_ROOT|$PDK|g" tb_pcn_4layer.spice | ngspice -b
```
Or use the runner script:
```bash
bash run_sim.sh                          # default testbench
bash run_sim.sh --netlist tb_temporal_reuse.spice
```

### RTL — digital integration tests (13 tests)
```bash
cd rtl
iverilog -o tb_pcn.vvp tb_pcn_digital_top.v pcn_digital_top.v \
    weight_fsm.v hebb_ctrl.v pcn_wb_regs.v sar_adc.v \
    act_sram.v sram_if.v sram_blackbox.v power_fsm.v
vvp tb_pcn.vvp
```

### Python — software experiments (E1–E4)
```bash
cd sim
python run_sim.py        # Gaussian PCA, template learning, quantisation, temporal reuse
python run_circuit_sim.py  # Circuit-level validation C1–C7 (hardware-calibrated model)
python pcn_predict.py    # 2-layer GHA multi-cell PCN
```
Results are written to `sim/results/`.

---

## Wishbone register map

| Offset | Name | Width | Function |
|---|---|---|---|
| 0x00 | WEIGHT_DATA | 8 | Weight byte to write |
| 0x04 | CELL_ADDR | 16 | Target cell/column address |
| 0x08 | CTRL | 7 | start_load, load_all, hebb_en, sleep_req, rst_weights, start_temporal, start_adc_sweep |
| 0x0C | STATUS | 4 | sleep_ack, hebb_actv, busy, ready |
| 0x10 | HEBB_MASK | N_rows | Static per-row Hebbian enable |
| 0x14 | HEBB_PW | 16 | Hebbian pulse width (cycles) |
| 0x18 | SRAM_DATA | 8 | Direct SRAM r/w |
| 0x20 | N_VIRT_LAYERS | 4 | Virtual layer count (1–8) |
| 0x24 | HEBB_ROW_MASK | N_rows | Dynamic per-row GHA mask |
| 0x28 | IERR_DIG | N_rows | Read-only precision-gate flags |
| 0x2C | INP_DAC_DATA | 8 | Direct input DAC write (GHA residual reload) |
| 0x30 | ACT_SRAM_DATA | 8 | Direct activation SRAM r/w |

---

## Scalability projections

| Configuration | Effective weights | Comparable scale |
|---|---|---|
| 1 chip, Sky130A, N=100 | ~200 K | small feature extractor |
| 1 chip, 28 nm, N=100 | ~1.6 M | — |
| 100 chips, 28 nm, N=20 | ~320 M | ResNet-50 class |
| 100 chips, 7 nm, N=100 | ~10 B | GPT-2 class |

All inter-chip interfaces are digital SPI — no analog signals cross chip boundaries.
Weight bandwidth is zero: weights never leave the chip.

---

## Paper

`paper/main_v3.tex` — *Scalable Modular Analog VLSI for Predictive Coding Networks:
Temporal Multiplexing, Learned Routing, and Zero Weight Bandwidth* — Saul Dobney, 2026.
IEEEtran format, targeting cs.AR + cs.NE cross-listing.

---

## Status

| Domain | Status |
|---|---|
| MAC cell SPICE | Complete — all parameters verified |
| Analog peripheral circuits | Complete — bias gen, weight DAC, input DAC, PMOS SF |
| 4-layer spatial cascade | Complete — gains verified by SPICE |
| Temporal reuse | Complete — 3-VL SPICE + full round-trip |
| Digital RTL | Complete — 22-state FSM, 13/13 tests pass |
| Place and route | Complete — OpenLane 2, 0 DRC violations, +8.46 ns slack |
| Software simulation | Complete — E1–E4 + C1–C7 + GHA multi-cell |
| Analog layout (Magic) | **In progress** — blocked on Magic 8.3.411+ build |
| Tape-out | Not started |

---

## Licence

Design files, RTL, and simulation scripts: [Apache 2.0](LICENSE)

The SkyWater 130 nm PDK is subject to its own licence terms.

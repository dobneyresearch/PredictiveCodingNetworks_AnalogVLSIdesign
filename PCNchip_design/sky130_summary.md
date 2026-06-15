# Sky130A PCN Chip — Design Summary

**Predictive Coding Network analog CMOS proof-of-concept**
Process: SkyWater Sky130A (130 nm open PDK) · VDD = 1.8 V · Target: Efabless Caravel

---

## What the chip is

A **four-layer Predictive Coding Network** implemented in analog CMOS. PCNs are hierarchical inference engines in which each layer generates a top-down prediction of the layer below and only the prediction *error* propagates upward — the architecture that best describes known cortical computation and is computationally advantageous for silicon because:

- **Computation is local**: each weight is updated using only the error at its own cell
- **Only errors travel**: inter-layer bandwidth is proportional to surprise, not to input size
- **Power scales with activity**: silent cells draw their quiescent current only; active cells drive the KCL bus

The chip computes dot products entirely in the analog domain (KCL current summation), executes on-chip Hebbian weight updates, and stores learned weights as analog voltages on 200 fF gate capacitors. During inference, no weight data crosses the chip boundary and no weight memory bandwidth is consumed.

---

## Core architecture: 4-layer spatial stack

The fundamental design is four physical PCN layers stacked vertically and connected by layer-link circuits:

```
  [Layer 3 — 16×16 MAC array]
         ↕ layer_link_2-3
  [Layer 2 — 16×16 MAC array]
         ↕ layer_link_1-2
  [Layer 1 — 16×16 MAC array]
         ↕ layer_link_0-1
  [Layer 0 — 16×16 MAC array]
```

Each layer-link provides:
- **Ascending path**: source-follower carrying the layer's output current upward (inference)
- **Descending path**: prediction current driven downward (top-down expectation)
- **Dynamic routing** (optional): Hebbian routing weights at layer boundaries that learn inter-layer connectivity (§6 of paper); 10× larger Cw_route, 10× slower adaptation timescale

| Level | Size | Description |
|---|---|---|
| MAC cell | 1 | 5-transistor OTA + 200 fF weight cap + CMOS TG |
| Row | 16 cells | One output neuron; KCL current summation |
| Layer | 16 × 16 = **256 cells** | One PCN layer |
| **Full chip** | **4 × 256 = 1,024 cells** | Four stacked PCN layers |
| Layer-link circuits | 3 | Connect layers 0→1, 1→2, 2→3 |
| **Physical weights** | **1,024** | One 200 fF cap per MAC cell |

---

## MAC cell architecture

Each cell is a 5-transistor PMOS-load OTA:

| Device | Type | W/L (µm) | Role |
|---|---|---|---|
| MN1 / MN2 | NFET diff pair | 2 / 0.35, nf=2 | Differential input; ABBA interdigitated |
| MP1 / MP2 | PMOS mirror | 4 / 0.7, nf=2 | Current mirror load; L=0.7µm chosen to reduce CLM and center V(iout) near Vcm in single-cell operation |
| MN3 | NFET tail | 10 / 0.35, nf=4 | Gate = Vw; I_tail ∝ (Vw−Vth)² → gm(Vw) — weight IS the tail bias |
| MN4 / MP4 | CMOS TG | 0.5/0.5 + 1.0/0.35 | Write access to weight capacitor |
| Cw | NFET gate cap | ≈ 200 fF | Weight storage; Vw range 0.50–1.35 V |

The weight is stored as Vw on Cw. The tail transistor MN3 converts Vw → I_tail, setting the OTA transconductance. All cells in a row sum drain currents on a shared KCL bus — the dot product **y = Wx** appears as a current in one settling time.

**Weight resolution**: ~6.6 effective bits (114 usable codes over Vw = 0.50–1.35 V).
**Hebbian update**: ≈ 4 mV per 50 µs pulse; SRAM-shadowed for persistence across power cycles.

---

## Layer-link and spatial cascade

The layer-link circuit between adjacent modules carries signals in both directions. The ascending path uses a **PMOS source follower**: because the PMOS source is the high terminal, the SF raises voltage by |Vgs_P| ≈ +0.67 V rather than dropping it. This is necessary because the balanced output voltage of a 16×16 module is ≈ 0.468 V — below the NMOS threshold — making an NMOS SF unable to drive the upper module's diff pair.

| SF type | Transfer | V(m0_iout) = 0.468 V → V(m1_inp) | Upper diff pair |
|---|---|---|---|
| NMOS SF | −0.62 V | −0.15 V | Dead (below Vth) |
| **PMOS SF (current design)** | **+0.67 V** | **1.14 V** | **Active ✓** |

**Balanced operating point**: V(iout_balanced) = 0.468 V in a 16×16 module, not Vcm = 0.9 V. The difference arises because `current_sub`'s diode-connected PMOS (XMPS1) loads the iout bus; at equilibrium the XMPS1 source current balances the net CLM-induced sink from 16 parallel MAC cells, settling below Vcm.

**Reference SF and vcm_upper**: A matched reference PMOS SF driven by a `vcm_iout` bias (= 0.468 V, the measured balanced OP) produces vcm_upper ≈ 1.137 V, which equals V(m1_inp) at balance. This drives inn_col of the upper module, preserving the differential:

> V(inp_upper) − vcm_upper = V(iout_lower) − vcm_iout

**Cascade gain in the untrained state**: With uniform weights (Vw = 0.75 V), upper modules operate at inp_cm ≈ 1.137 V. The tail transistor MN3 (Vw − Vth = 0.27 V overdrive) is pushed toward subthreshold at the KCL balance point, reducing I_tail and hence gm at layers 1–3. Measured 4-layer gains (untrained): mod0 = 1.43, mod1 = 0.45, mod2 = 0.70, mod3 = 0.54 V/V — signal propagates at all layers. In a trained chip, Hebbian learning raises Vw in upper layers, restoring the tail current and increasing gain to match mod0.

**Single-cell characterisation** (balanced, Vw = 0.75 V, MP1/MP2 L = 0.7 µm):
- V(iout) = 0.883 V ≈ Vcm; I_tail = 41 µA; gm = 204 µA/V
- Hebbian update: ΔVw = 8.2 mV per 10 µs pulse

---

## Additional capability: temporal layer reuse

The same MAC array can cycle through multiple virtual sub-layers by saving activations to SRAM and reloading through the DAC between passes. This is **an additional capability that complements the spatial stack** — not a replacement for it.

With temporal reuse the ADC→DAC reload resets the common-mode precisely to Vcm = 0.9 V at the start of each virtual layer, eliminating the cascade bias drift that occurs in the spatial stack's untrained state. Temporal reuse also multiplies effective weight capacity without additional silicon area.

| Configuration | Physical weights | Effective weights |
|---|---|---|
| Spatial only (4 physical layers) | **1,024** | **1,024** |
| + Temporal, N = 4 per layer (current 1 KB SRAM) | 1,024 | 4,096 |
| + Temporal, N = 25 per layer (25 KB SRAM) | 1,024 | 25,600 |
| + Temporal, N = 100 per layer (100 KB SRAM) | 1,024 | **102,400** |

---

## Silicon area

| Block | Area |
|---|---|
| MAC cell (target, under layout) | ≈ 600 µm² (≈ 10 × 8 µm) |
| 16 × 16 MAC array + csub + precision gates | ≈ 70,000 µm² per layer |
| **4-layer analog stack** (4 modules + 3 layer-links + bias) | **≈ 330,000 µm² = 0.33 mm²** |
| Digital controller (FSM, WB regs, ADC, DAC, RTL) | ≈ 25,000 µm² |
| SRAM macro (1 kbyte, OpenRAM — shared across all 4 layers) | ≈ 203,000 µm² |
| Digital total (P&R verified) | ≈ 570,000 µm² = 0.57 mm² |
| **Total chip estimate** | **≈ 0.90 mm²** |
| Caravel user area available | 10.3 mm² — chip uses ≈ **8.7%** |

Note: The 1 kbyte SRAM exactly fits all four layers' weights (4 × 256 cells × 1 byte = 1,024 bytes). Temporal reuse requires additional SRAM pages beyond this.

---

## Performance

| Metric | Value | Notes |
|---|---|---|
| KCL settling time (one forward pass) | ≈ 28 ns | R_err × C_KCL |
| Inference bandwidth | 5.7 MHz | invariant to array size |
| Throughput (4-layer, continuous) | 5.9 GOPS | 1,024 cells, 5.7 MHz |
| Weight reload time (all 4 layers) | ≈ 82 µs | 1,024 weights at 80 ns each |
| Digital clock | 50 MHz | |
| Digital setup WNS | +8.46 ns | TT corner, OpenLane verified |
| Off-chip weight memory bandwidth | **0** | weights are analog voltages on Cw |

---

## Power

| Configuration | Power |
|---|---|
| Single MAC cell (I_tail = 41 µA, VDD = 1.8 V) | ≈ 74 µW |
| One 16 × 16 layer, all active | ≈ 18.9 mW |
| **4-layer chip baseline** | **≈ 80 mW** |
| With 10% duty cycle + 50% row gating | **≈ 0.8 mW** |
| Digital block only | ≈ 36 µW (negligible) |

Power is I_tail-dominated and fully controllable. The design runs at ≈ 15-bit effective SNR; PCN inference needs 6–8 bits. Reducing I_tail from 41 µA to 1 µA cuts power 41× with no change to inference bandwidth (τ_KCL = R_err × C_KCL has no I_tail dependence).

Production power pathway (28 nm, 2 M weight chip):

| Strategy | Power | Cumulative reduction |
|---|---|---|
| Baseline (I_tail = 41 µA) | 90 W | — |
| I_tail → 1 µA (11-bit SNR) | 2.2 W | 41× |
| + VDD → 0.75 V | 1.5 W | 60× |
| + 10% duty cycle | 150 mW | 600× |
| + 50% row gating | **75 mW** | 1,200× |
| + 90% sparse activity | 15 mW | 6,000× |

---

## Digital controller

| Parameter | Value |
|---|---|
| Architecture | Wishbone peripheral in Efabless Caravel |
| Standard cells | 1,117 (Sky130 HD) |
| SRAM | 1 kbyte OpenRAM macro (shared across all 4 analog layers) |
| FSM states | 22 (weight load, temporal reuse, ADC sweep, GHA loop) |
| Wishbone registers | 0x00–0x30 (CTRL, STATUS, CELL_ADDR, WEIGHT_DATA, HEBB_ROW_MASK, …) |
| RTL tests | 13 / 13 passing |

---

## Scaling projections

| Process | Cell area | Cells / 10 mm² | 4-layer chip | With N = 100 temporal |
|---|---|---|---|---|
| **Sky130A (this chip)** | ≈ 600 µm² | ≈ 16,000 | **1,024 weights / 0.90 mm²** | ≈ 102,400 eff. weights |
| 28 nm | ≈ 60 µm² | ≈ 160,000 | ≈ 10,240 weights / mm² | ≈ 1.6 M eff. weights |
| 7 nm | ≈ 10 µm² | ≈ 1,000,000 | ≈ 64,000 weights / mm² | ≈ 100 M eff. weights |

Multi-chip scaling is **linear**: each additional chip adds weight capacity and inference throughput independently. The inter-chip interface is entirely digital (8-bit SPI activation pages + ierr_dig bits).

---

## Design status (as of 2026-06-14)

| Block | Status |
|---|---|
| MAC cell SPICE | ✅ All tests pass; gm=204µA/V; ΔVw=8.2mV/pulse |
| 2-layer spatial testbench | ✅ T1–T3 pass — ascending SF, descending prediction, Hebbian write |
| 4-layer spatial testbench | ✅ T1/T2/T3 pass — signal at all 4 layers; gains mod0=1.43 … mod3=0.54 |
| Dynamic routing | ✅ Designed and simulated; Hebbian LTD write verified in Sky130 |
| Temporal reuse | ✅ 3-VL testbench passes; gain 6.82 V/V; full ADC→DAC round-trip verified |
| Software / algorithmic validation | ✅ 484× prediction error reduction (GHA, 2-layer network) |
| Digital RTL | ✅ 13/13 tests pass; OpenLane P&R GDS produced; WNS +8.46 ns at 50 MHz |
| Xschem schematic (mac_cell) | ✅ Complete |
| Magic analog layout (mac_cell) | 🔄 In progress — blocked on Magic 8.3.411 (apt version 8.3.105 segfaults with PDK) |
| DRC / LVS / PEX | ⏳ Pending layout |
| arXiv paper (v2) | ✅ 1,289 lines; IEEEtran two-column; all simulation results included |

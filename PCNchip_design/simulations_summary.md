# PCN Chip — Simulations Summary

Record of all simulation work completed to date.  
Status as of 2026-06-16.  This document is for internal reference and does not
represent the finalised paper claims — those are in `paper/main_v3.tex`.

---

## 1. SPICE Simulations (ngspice, Sky130A TT 27 °C)

Key calibration and validation points extracted from circuit-level SPICE runs.
All values have been cross-validated by the circuit behavioural model (`sim/circuit_sim.py`).

| Result | Value | Testbench | Notes |
|---|---|---|---|
| Single-cell gain at Vcm | **6.82 V/V** | `tb_temporal_reuse.spice` | MN1/MN2 diff pair + MP1/MP2 mirror load; CODE_MID weight |
| Single-cell gain at Vinp=0.51V | ~0.0014 V/V | `tb_dvw_pulse.spice` | Subthreshold regime; below-VCM gain collapse |
| PMOS SF level shift | **+0.670 V** | `layer_link.spice` | V_out_bal=0.468V → V_inp_upper=1.138V |
| Spatial cascade — layer 0 gain | **1.43 V/V** | `tb_pcn_4layer.spice` | Untrained; Hebbian self-calibrates in use |
| Spatial cascade — layer 1 gain | **0.45 V/V** | `tb_pcn_4layer.spice` | Reduced: Vinp at VCM_UPPER hits MN3 subthreshold |
| Spatial cascade — layer 2 gain | **0.70 V/V** | `tb_pcn_4layer.spice` | Recovers after SF reset |
| Spatial cascade — layer 3 gain | **0.54 V/V** | `tb_pcn_4layer.spice` | Stable |
| Temporal reuse gain per VL | **6.68 V/V** | `tb_temporal_reuse.spice` | ADC→SRAM→DAC reset between VLs; consistent across 3 VLs |
| ADC/DAC round-trip error | **0.50 LSB** | `tb_temporal_full.spice` | 8-bit SAR + 8-bit R-2R; within spec |
| Hebbian pulse ΔVw | Characterised | `tb_dvw_pulse.spice` | Current width × I_hebb / Cw; firmware controls duration |

**Key finding:** Direct spatial cascade (layer-link only) causes operating-point collapse
after 1–2 layers because the PMOS SF shift pushes V_inp_cm to VCM_UPPER where MN3 enters
subthreshold.  Temporal reuse with ADC→DAC reset eliminates this: Vcm is restored to
0.9 V at each virtual layer, giving consistent 6.68 V/V throughout the stack.

---

## 2. Circuit Behavioural Model (sim/circuit_sim.py + run_circuit_sim.py)

Hardware-faithful Python model calibrated to SPICE (voltage-domain, not
normalised weight-space).  Seven validation experiments, each with a saved figure
in `sim/results/`.

| Exp | Title | Key result | Figure |
|---|---|---|---|
| C1 | Single-cell transfer curve | Weight codes 71–192 give linear ΔV_iout; gain 6.82 V/V at CODE_MID, VCM | `c1_cell_transfer.png` |
| C2 | KCL multi-cell summation | 4-cell and 16-cell rows sum linearly; output amplitude independent of N (current-mode property) | `c2_kcl_summation.png` |
| C3 | Spatial cascade (direct) | Vinp_cm collapses to ~0.51V after layer 0; gain drops to ~0.0014 V/V — confirms Path A failure mode | `c3_spatial_cascade.png` |
| C4 | Temporal cascade (ADC reset) | Vinp_cm held at VCM=0.9V at each VL; gain consistent at ~6.68 V/V across all 4 VLs | `c4_temporal_cascade.png` |
| C5 | C3 vs C4 side-by-side | Gain and Vinp_cm at each stage — temporal reuse clearly dominates; key paper comparison figure | `c5_spatial_vs_temporal.png` |
| C6 | Quantisation noise budget | 8-bit ADC + DAC round-trip ≤ 0.50 LSB error across full input range (Vinp 0.4–1.4V) | `c6_quant_noise.png` |
| C7 | KCL linearity sweep | 16-cell weighted sum vs expected dot product: R² > 0.9999 across CODE_MIN–CODE_MAX | `c7_linearity.png` |

---

## 3. Software Simulations — Algorithm Validation (sim/run_sim.py)

Four experiments using the normalised-weight PCNLayer model (`sim/pcn_core.py`).
These test the learning rule behaviour, not the circuit voltages.

| Exp | Title | Setup | Key result | Figure |
|---|---|---|---|---|
| E1 | Gaussian PCA — mode comparison | 8-dim input, 4 output rows, SNR=20dB; V1 / BCM / V2 learning modes | V2 (signed Hebbian) converges fastest and achieves highest PC alignment; V1 (LTP-only) converges but more slowly; BCM intermediate | `e1_gaussian_pca.png` |
| E2 | Template learning | 8 orthogonal templates in R¹⁶; V2 + k-WTA (k=1) | All 8 weight rows converge to distinct templates; selectivity (cos>0.7) reaches 1.00 | `e2_template_learning.png` |
| E3 | Hardware quantisation effect | Same as E1 but V2 float vs V2 8-bit | Minimal difference in PC alignment; 8-bit quantisation adds <5% penalty on 8-dim Gaussian task (weights well within CODE range at this dimension) | `e3_quantisation.png` |
| E4 | Temporal reuse — 4 VLs | PCNTemporalStack with 4 virtual layers; 8-bit ADC between layers | Each VL receives quantised activation from previous; learning progresses correctly through the stack | `e4_temporal_reuse.png` |

---

## 4. GHA Predictive Network (sim/pcn_predict.py)

Validates that the PCN hierarchy forms a generative model after GHA training.
Two-layer network, 16-dim input, 8 hidden rows, orthogonal training templates.

| Exp | Title | Key result |
|---|---|---|
| P1 | Inference convergence | After training, prediction error collapses from ‖x‖²/N ≈ 0.0625 to ~0 in **one** inference step (generative mode); novel inputs stay at 0.0625 |
| P2 | Prediction specificity | Reconstruction MSE ratio: **novel / trained = 484×** (1.00 selectivity score) |
| P3 | Training convergence | Recon MSE converges from ~0.06 to <0.001 over 12,000 steps with cosine LR decay |
| P4 | Template alignment | All 8 L0 rows converge to distinct training templates; mean max-cos = 0.97; full template coverage; L1 aligns in code space |

**Figure:** `p_predictive_network.png` (4-panel: inference convergence, specificity bar chart, training curve, L0+L1 alignment)

---

## 5. Digital RTL — Simulation and Synthesis

### 5.1 Icarus Verilog functional tests

| Testbench | Tests | Result |
|---|---|---|
| `rtl/tb_pcn_digital_top.v` | 13 | **13/13 PASS** |
| `rtl/tb_sar_adc.v` | 11 | **11/11 PASS** |

Covers: weight FSM 22-state sequence, temporal reuse control, Hebbian gating
(HEBB_ROW_MASK), Wishbone register map (13 registers), SAR ADC 10-cycle latency,
activation SRAM save/load, power FSM sleep/wake.

### 5.2 Synthesis (Yosys, sky130_fd_sc_hd)

| Metric | Value |
|---|---|
| Standard cells | 4,054 |
| Flip-flops | 758 |
| Logic area | 38,971 µm² (~197 × 197 µm) |
| SRAM macro | sky130_sram_1kbyte_1rw1r_8x128_8 (blackboxed, ~800 µm² extra) |
| Dominant module | hebb_ctrl: 80.6% of area (32 × 16-bit pulse-width counters) |

### 5.3 Place and route (OpenLane 2, Sky130A TT)

| Metric | Value |
|---|---|
| DRC violations | **0** |
| Timing slack @ 50 MHz | **+8.46 ns** (TT corner) |
| SS/FF corner | Not yet verified (TT margin is large; expected to close) |

---

## 6. MNIST Classification Demo (sim/pcn_mnist.py)

New experiment (2026-06-15) demonstrating the PCN multi-chip architecture on a real
image classification task.  All feature learning is unsupervised and hardware-faithful.

### 6.1 Hardware topology simulated

| Layer | Mapping | Chips | Cells |
|---|---|---|---|
| L0 — pixel projection (784→64) | 49 col tiles × 4 row tiles | **196** | 50,176 |
| L1 — feature abstraction (64→16) | 4 col tiles × 1 row tile | **4** | 1,024 |
| **Total** | | **200** | **51,200** |

- Chip geometry: 16×16 MAC cells (Sky130A)
- Weight storage: 10.24 nF on-chip (200 fF × 51,200 cells)
- Off-chip weight bandwidth: **0 bit/s**

### 6.2 Training protocol

| Stage | Algorithm | Epochs | Samples | LR schedule |
|---|---|---|---|---|
| L0 | GHA (Sanger 1989) | 12 | 60,000 | 0.01 → 0.0005 cosine |
| L1 | GHA on L0 features | 6 | 60,000 | 0.02 → 0.001 cosine |

- Preprocessing: pixel mean subtracted, per-sample L2-normalised
- L0 feature extraction: ReLU (V1 PMOS clamp — negative MAC outputs set to 0)
- L1 inputs: L0 features centred and L2-normalised before GHA
- Training is **entirely unsupervised** — digit labels are never seen during feature learning

### 6.3 Classification results

Off-chip host-processor classifier trained on L0 features (logistic regression, C=10):

| Weights | Test accuracy |
|---|---|
| Float (training precision) | 82.53% |
| **8-bit quantised (hardware-faithful)** | **83.34%** |

The 8-bit result being marginally better than float is a consistent finding across
both runs: coarse DAC quantisation (step ≈ 0.016 in weight units) acts as a mild
regulariser on the linear head, preventing overfitting to small feature-space noise.

### 6.4 Per-digit accuracy (8-bit hardware-faithful result)

| Digit | Accuracy | n |
|---|---|---|
| 0 | 90.0% | 980 |
| **1** | **97.5%** | 1135 |
| 2 | 75.8% | 1032 |
| 3 | 77.7% | 1010 |
| 4 | 84.3% | 982 |
| **5** | **72.6%** | 892 |
| 6 | 89.4% | 958 |
| 7 | 86.7% | 1028 |
| 8 | 81.4% | 974 |
| 9 | 75.5% | 1009 |

Digit 1 (97.5%) is easiest — unique thin vertical stroke in PCA feature space.
Digit 5 (72.6%) is hardest — structurally similar to 3, 6, and 8 in terms of curve
primitives captured by L0 filters.  The 2/3/9 cluster (75–78%) reflects shared curved
stroke features.

### 6.5 Accuracy gap analysis

| Component | Estimated cost |
|---|---|
| V1 PMOS clamp (ReLU discards negative MAC outputs) | ~4 pp |
| GHA partial convergence (rows not fully orthogonal) | ~2 pp |
| 8-bit weight quantisation at 784-input scale | slightly beneficial |
| **Gap from theoretical PCA+logistic (~91%)** | **~7–8 pp** |

The V1 PMOS clamp is the largest single factor.  A V2 silicon upgrade (Gilbert cell
replacing the PMOS clamp → signed MAC outputs) is the highest-leverage hardware change
for accuracy.

### 6.6 Output files

| File | Content |
|---|---|
| `sim/results/mnist_topology.txt` | Hardware chip-count summary |
| `sim/results/mnist_filters_l0.png` | 8×8 grid of 64 learned L0 filters (28×28 each) |
| `sim/results/mnist_filters_l1.png` | 16 L1 codes projected back to pixel space |
| `sim/results/mnist_training.png` | GHA reconstruction error + cosine LR schedule |
| `sim/results/mnist_confusion.png` | 10×10 normalised confusion matrix |

---

### 6.7 EMNIST letters extension (2026-06-16)

Same `sim/pcn_mnist.py` script, switched via `DATASET=emnist_letters`. Demonstrates
that the architecture generalises beyond 10-digit MNIST to a 26-class alphabetic
task with no structural changes — only the data loader, class count, and L0/L1
width differ.

| | MNIST (digits) | EMNIST letters |
|---|---|---|
| Classes | 10 | 26 (a–z, merged case) |
| Train / test samples | 60,000 / 10,000 | 124,800 / 20,800 |
| L0 → L1 | 64 → 16 | 96 → 32 |
| Chips | 200 (196 L0 + 4 L1) | 306 (294 L0 + 12 L1) |
| Weight cells | 51,200 | 78,336 |
| Best accuracy | 83.34% (8-bit) | 64.03% (8-bit) |
| 8-bit vs float | −0.81pp (better) | −3.77pp (better) |

Hardware-faithful pipeline unchanged: GHA unsupervised feature learning, ReLU
(V1 PMOS clamp), 8-bit weight quantisation, multi-chip KCL tiling. Same 12+6
epoch budget as MNIST despite ~2× more training samples; reconstruction MSE
was still slowly declining at the end of L0 training (recon_mse=14.90 final),
so more epochs would likely raise accuracy further.

Per-letter accuracy: easiest 'm' (86.2%), hardest 'g' (40.2%, confused mainly
with 'q' — shared descender/loop shape). The confusion matrix shows a clean
diagonal with intuitively sensible off-diagonal confusions (g/q, i/l) —
evidence the model is learning real stroke structure, not noise.

EMNIST dataset quirk: images ship transposed relative to the MNIST pixel
convention; corrected on load (confirmed by direct inspection — sample 0,
labelled 'w', only renders as a recognisable letter after a row/col
transpose). Labels are 1-indexed in the official 'letters' split (1=a…26=z);
remapped to 0-indexed to match the rest of the pipeline.

Output files: `sim/results/emnist_letters_{topology.txt, filters_l0.png,
filters_l1.png, training.png, confusion.png}` — same naming pattern as MNIST,
distinguished by the `emnist_letters_` prefix so both result sets coexist.

Dependency note: required installing `torchvision` (EMNIST loader), which
transitively upgraded `torch` 2.6.0+cu124 → 2.12.0+cu130. Verified GPU/CUDA
still functional after the upgrade (RTX 3060 detected, `torch.cuda.is_available()`
True) — no issues found, but flagging since it changed a shared environment
package beyond the immediate scope of this task.

---

## 7. Tunable Parameters (pcn_mnist.py)

Summary of what can be changed within the hardware-faithful model and what is fixed.

### Adjustable (maps to physical chip or operating parameters)

| Parameter | Current value | Effect | Hardware mapping |
|---|---|---|---|
| `DATASET` | mnist | `mnist` (10-class digits) or `emnist_letters` (26-class a-z); switches data loader and changes N_L0/N_L1 defaults (64/16 → 96/32, 200→306 chips) | Task/dataset selection — same chip architecture, different training data and output class count |
| `N_L0` | 64 (96 for letters) | Each +16 adds 49 L0 chips (196→245→…) | More MAC rows; more weight cells |
| `N_L1` | 16 (32 for letters) | Each +16 adds 4 L1 chips | More abstraction capacity |
| `N_EPOCHS_L0` | 12 | More epochs → better GHA convergence | Longer Hebbian exposure phase; no area cost |
| `N_EPOCHS_L1` | 6 | As above for L1 | As above |
| `LR_L0` / `LR_L0_MIN` | 0.01 → 0.0005 | Peak and floor of cosine LR schedule | I_hebb × t_pulse / Cw; adjustable in firmware |

### Fixed by Sky130A tape-out

| Parameter | Value | Reason fixed |
|---|---|---|
| `CHIP_ROWS` / `CHIP_COLS` | 16 × 16 | Physical MAC array dimensions |
| Weight DAC resolution | 8-bit, codes 71–192 | CMOS TG range (Vw = 0.50–1.35 V) |
| ReLU activation | V1 PMOS clamp | Negative outputs blocked by PMOS mirror |
| Weight storage capacitor | 200 fF | Cw — determines min ΔVw per Hebbian pulse |

### V2 upgrade path (next silicon revision)

Replacing the PMOS current mirror load with a Gilbert cell would give
four-quadrant (signed) MAC outputs, eliminating the ReLU constraint.
Estimated accuracy gain on MNIST: ~4 pp (83% → ~87%).

### Off-chip only (not on the PCN chip)

| Option | Notes |
|---|---|
| `CLASSIFIER=lstsq` | Numpy least-squares; no sklearn required; ~0.8 pp below logistic |
| `CLASSIFIER=logistic` | sklearn LogisticRegression C=10, L-BFGS; current default |

---

## 8. Pending Simulation Work

| Item | Status | Blocker |
|---|---|---|
| Magic analog layout (MAC cell) | In progress | Need Magic 8.3.411+ (current: 8.3.105 segfaults on Sky130A tech file) |
| SS/FF timing corner (digital RTL) | Not done | TT slack +8.46 ns is large; expected to close but unverified |
| 28 nm re-parameterisation (circuit_sim.py) | Not done | VCM=0.55V, VDD=1.1V, SF_PMOS≈0.41V, VCM_UPPER≈0.70V — C1–C7 re-run |
| MNIST with N_L0=128 | Not done | Expected ~86–88%; doubles L0 chip count (196→392) |
| MNIST without ReLU (V2 mode) | Not done | Remove `relu=True` in `extract_features`; shows V2 ceiling |
| Scalability demo (multi-chip SPI) | Not done | Software simulation of N-chip daisy-chain |

---

## 9. Runtime Reference

Approximate wall-clock times on the development machine (CPU only, no GPU).

| Simulation | Runtime |
|---|---|
| run_circuit_sim.py (C1–C7) | < 10 s |
| run_sim.py (E1–E4) | ~30 s |
| pcn_predict.py (P1–P4) | ~90 s |
| pcn_mnist.py (MNIST, 12+6 epochs, logistic) | ~411 s (~7 min) |
| pcn_mnist.py (EMNIST letters, 12+6 epochs, logistic) | ~1,230 s GHA (~21 min) + classification/plotting |
| Digital RTL tests (iverilog) | < 5 s |
| Yosys synthesis | ~30 s |

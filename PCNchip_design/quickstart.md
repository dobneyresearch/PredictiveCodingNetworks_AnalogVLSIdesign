# PCN Chip — Quick Start Guide

This guide shows how to connect, program, and run inference on the PCN chip.
It assumes you are familiar with neural networks but not with the chip itself.
For full technical detail see the design paper (`paper/main_v2.tex`) and the
design document (`pred_code_networks.md`).

---

## What the chip does

The PCN chip is an analog in-memory compute accelerator for Predictive Coding
Networks. Internally it contains a 16 × 16 grid of analog multiply-accumulate
(MAC) cells. Weights are stored as voltages on capacitors inside each cell —
no weight data moves off-chip during inference.

The same physical array is reused for multiple virtual layers via
a save-and-reload cycle controlled by the on-chip finite state machine.
You configure how many virtual layers (N_VL) to run; each forward pass
automatically cascades through all of them.

**What goes in:** 16 input activations (8-bit codes)  
**What comes out:** 16 output activations (8-bit codes), plus per-row error flags  
**Weights:** stored on-chip; loaded once, retained across many inferences  
**Learning:** optional Hebbian update after each inference, entirely on-chip

---

## System integration

```
  Sensors / upstream layer
          │  (8-bit activation codes)
          ▼
  ┌─────────────────────┐        SPI / Wishbone
  │    Host MCU / CPU   │◄──────────────────────┐
  │  (Python or C code) │                       │
  └──────────┬──────────┘                       │
             │ SPI (or Caravel UART)             │
             ▼                                  │
  ┌─────────────────────────────────────────────┴──┐
  │                  PCN Chip                       │
  │                                                 │
  │   inp_dac ──► 16×16 MAC array ──► SAR ADC      │
  │        Σ gm(Vw) × (inp − inn)     (8-bit out)  │
  │                                                 │
  │   ┌──────── SRAM shadow ────────────────────┐  │
  │   │  weights[N_VL][16][16]  activations[16] │  │
  │   └─────────────────────────────────────────┘  │
  │                                                 │
  │   22-state FSM  ◄──── Wishbone registers        │
  └─────────────────────────────────────────────────┘
             │
             ▼
  Output activations (8-bit, via ACT_SRAM_DATA register)
  to downstream layer / decision logic
```

**Single chip:** processes one 16-input × 16-output virtual network with up to
N_VL temporal layers.

**Multi-chip chain:** chain chips in series. Read ACT_SRAM from chip N, write to
INP_DAC_DATA on chip N+1. Send IERR_DIG flags backward (chip N+1 → chip N) over
a separate SPI wire. No synchronisation beyond SPI timing is required.

---

## Hardware connections

### Power

| Pin | Voltage | Notes |
|-----|---------|-------|
| VDD (analog) | 1.8 V | Quiet supply; 100 nF + 10 µF at each pad |
| VDD (digital) | 1.8 V | Can share with analog; keep filtered |
| VSS | 0 V | Common ground |

Use a low-noise LDO (e.g., TPS7A47) for the analog supply. Star ground from
the chip back to the decoupling capacitors.

### Digital interface

**If using a Caravel-wrapped MPW chip (Sky130A):**

The Management SoC on the Caravel harness is your host. Connect:
- UART TX/RX to a USB–serial adapter (115200 baud default)
- Flash the Management SoC firmware (see Caravel docs) to access Wishbone registers

Wishbone base address: `0x30000000`

**If using a standalone chip with SPI bridge:**

Use any SPI-capable MCU (Raspberry Pi, STM32, Arduino with 1.8V I/O or level
shifter). The chip's Wishbone interface needs a thin SPI bridge; add a simple
SPI-to-Wishbone bridge at the host side, or use a microcontroller with a
firmware shim.

| Signal | Direction | Notes |
|--------|-----------|-------|
| CLK | Host → chip | Up to 50 MHz |
| MOSI | Host → chip | SPI data in |
| MISO | Chip → host | SPI data out |
| CS# | Host → chip | Active low |
| RST_N | Host → chip | Active low reset; hold low ≥ 10 cycles on power-up |
| IRQ | Chip → host | Active high; fires when FSM completes a temporal run |

No external analog connections are required. Bias generation, the weight DAC,
input DAC, and SAR ADC are all internal.

---

## Register map summary

Base address `0x30000000` (Caravel). Offsets:

| Offset | Name | Access | Function |
|--------|------|--------|----------|
| 0x00 | WEIGHT_DATA | W | 8-bit weight value to load |
| 0x04 | CELL_ADDR | R/W | Target cell: `{VL[2:0], row[3:0], col[3:0]}` |
| 0x08 | CTRL | W | See control bits below |
| 0x0C | STATUS | R | `{sleep_ack, hebb_actv, busy, ready}` |
| 0x10 | HEBB_MASK | R/W | Static per-row Hebbian enable (1 bit per row) |
| 0x14 | HEBB_PW | R/W | Hebbian pulse width in clock cycles |
| 0x20 | N_VIRT_LAYERS | R/W | Number of temporal virtual layers (1–8) |
| 0x24 | HEBB_ROW_MASK | R/W | Dynamic k-WTA row mask (GHA loop) |
| 0x28 | IERR_DIG | R | Precision-gate error flags (1 bit per row) |
| 0x2C | INP_DAC_DATA | W | Direct input activation write at CELL_ADDR |
| 0x30 | ACT_SRAM_DATA | R/W | Activation SRAM read at CELL_ADDR |

**CTRL bits:**

| Bit | Name | Action |
|-----|------|--------|
| 0 | start_load | Load WEIGHT_DATA into cell at CELL_ADDR (single pulse) |
| 1 | load_all | Reload all weights from SRAM (used after power cycle) |
| 2 | hebb_en | Enable Hebbian update on next forward pass |
| 3 | sleep_req | Request low-power sleep (weights held in SRAM) |
| 4 | rst_weights | Reset all weights to mid-scale |
| 5 | start_temporal | Launch N_VL-layer temporal forward pass |
| 6 | start_adc_sweep | Standalone ADC sweep (GHA read mode) |

**STATUS bits:**

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | ready | FSM idle; chip is ready to accept a command |
| 1 | busy | FSM running; do not issue new commands |
| 2 | hebb_actv | Hebbian pulse currently in progress |
| 3 | sleep_ack | Sleep mode active |

---

## Software quickstart (Python)

The examples below use a thin helper that wraps your SPI/UART transport.
Replace `reg_write(offset, value)` and `reg_read(offset)` with whatever matches
your hardware interface.

```python
import time

BASE = 0x30000000  # Caravel Wishbone base; drop this for relative SPI addressing

def reg_write(offset, value):
    """Write 8-bit value to register at BASE + offset."""
    wb_write(BASE + offset, value & 0xFF)   # implement for your transport

def reg_read(offset):
    """Read 8-bit value from register at BASE + offset."""
    return wb_read(BASE + offset) & 0xFF    # implement for your transport

def wait_ready(timeout_ms=100):
    t0 = time.monotonic()
    while not (reg_read(0x0C) & 0x01):     # STATUS.ready
        if (time.monotonic() - t0) * 1000 > timeout_ms:
            raise TimeoutError("PCN chip not ready")
        time.sleep(0.001)
```

### Step 1 — Initialise

```python
# Assert and release reset
gpio_low(RST_N)
time.sleep(0.001)
gpio_high(RST_N)
time.sleep(0.001)

# Set number of virtual layers
N_VL = 4
reg_write(0x20, N_VL)

# Confirm ready
wait_ready()
print("Chip ready:", hex(reg_read(0x0C)))   # expect 0x01

# Enable all rows for Hebbian updates (16-row chip → bitmask 0xFFFF, 16 bits)
reg_write(0x10, 0xFF)   # lower 8 rows; write 0x1C for rows 9-16 if N_ROWS > 8
```

### Step 2 — Load weights

Weights are 8-bit codes: code 128 ≈ zero weight (no contribution), codes above 128 = positive,
codes below 128 = negative. The full range 0–255 maps to approximately −0.4 to +0.4 V/V gain.

`CELL_ADDR` encodes `{VL[2:0], row[3:0], col[3:0]}` in the lower 11 bits.

```python
def cell_addr(vl, row, col):
    return (vl << 7) | (row << 4) | col    # 3-bit VL, 4-bit row, 4-bit col

def load_weight(vl, row, col, code):
    """Load one weight. code 0–255; 128 = zero weight."""
    reg_write(0x04, cell_addr(vl, row, col) & 0xFF)    # CELL_ADDR low byte
    reg_write(0x05, cell_addr(vl, row, col) >> 8)      # CELL_ADDR high byte
    reg_write(0x00, code)                               # WEIGHT_DATA
    reg_write(0x08, 0x01)                               # CTRL: start_load
    wait_ready()

# Example: load a 16×16 identity-ish weight matrix into virtual layer 0
# (diagonal = high weight, off-diagonal = mid-scale/zero)
for row in range(16):
    for col in range(16):
        code = 200 if row == col else 128   # diagonal positive, rest zero
        load_weight(vl=0, row=row, col=col, code=code)

print("Weights loaded.")
```

### Step 3 — Load input activations

Before each forward pass, write 16 input values. Activations are 8-bit codes:
code 128 = V_CM (quiescent midpoint), 0 = minimum, 255 = maximum.

```python
def load_input(col, code):
    """Write one input activation column. col 0–15, code 0–255."""
    reg_write(0x04, col & 0xFF)     # CELL_ADDR (column only for inp_dac)
    reg_write(0x05, 0x00)
    reg_write(0x2C, code)           # INP_DAC_DATA — direct write, one cycle strobe

# Load an example input pattern (half-scale activations on columns 0–7)
for col in range(16):
    code = 192 if col < 8 else 128
    load_input(col, code)
```

### Step 4 — Run a forward pass

```python
reg_write(0x08, 0x20)   # CTRL: start_temporal (bit 5)

# Wait for IRQ or poll STATUS
wait_ready()
```

This triggers the FSM. It runs all N_VL temporal virtual layers:
for each layer it presents the activations via inp_dac, settles the analog array,
runs the SAR ADC on each column output, stores the result in act_sram, then
reloads the activations for the next virtual layer.

### Step 5 — Read output activations

After `wait_ready()`, read the 16 output activations from the final virtual layer.

```python
def read_output(col):
    reg_write(0x04, col & 0xFF)
    reg_write(0x05, 0x00)
    return reg_read(0x30)           # ACT_SRAM_DATA

outputs = [read_output(col) for col in range(16)]
print("Outputs:", [f"{v:3d}" for v in outputs])
# Interpret: 128 = no activation, >128 = positive, <128 = negative
```

### Step 6 — Read prediction errors

After a forward pass, the chip latches per-row precision-gate error flags.
A bit set in IERR_DIG means that row's output differed significantly from
the top-down prediction (or from zero if no prediction is provided).

```python
errors = reg_read(0x28)     # IERR_DIG: bit i = 1 → row i has high error
active_rows = [i for i in range(16) if errors & (1 << i)]
print("High-error rows:", active_rows)
```

### Step 7 — Apply Hebbian update (optional)

To enable online learning, trigger a Hebbian pulse after the forward pass.
Only rows with HEBB_MASK bit set will update. Use HEBB_ROW_MASK for GHA
(selective per-step masking).

```python
# Update only the highest-error rows (k-WTA: keep top 2)
k = 2
top_rows = sorted(active_rows, key=lambda r: -(errors >> r & 1))[:k]
mask = sum(1 << r for r in top_rows)
reg_write(0x24, mask & 0xFF)        # HEBB_ROW_MASK

# Set pulse width (default: 1000 cycles at 50 MHz = 20 µs; tune for ΔVw = 1 DAC LSB)
reg_write(0x14, 1000 & 0xFF)
reg_write(0x15, 1000 >> 8)

# Trigger: hebb_en (bit 2) + start_temporal (bit 5)
reg_write(0x08, 0x24)               # bits 2 and 5
wait_ready()
```

The weight voltage on the selected cells changes by approximately one DAC LSB
(~7 mV) per pulse in the default configuration. Run many training cycles;
the weights converge to minimise prediction error without any off-chip
gradient computation.

---

## Running multiple chips in series

For a deeper network, chain N chips. Each chip adds N_VL virtual layers.

```
Host MCU
   │ SPI bus (shared CLK, MOSI, MISO; separate CS# per chip)
   ├─── CS0 ──► Chip 0 (layers 0 .. N_VL-1)
   ├─── CS1 ──► Chip 1 (layers N_VL .. 2·N_VL-1)
   └─── CS2 ──► Chip 2 (layers 2·N_VL .. 3·N_VL-1)

IRQ0 ◄── Chip 0        IRQ1 ◄── Chip 1        IRQ2 ◄── Chip 2
IERR1 ──► Chip 0 0x28  IERR2 ──► Chip 1 0x28  (top chip: no feedback)
```

```python
def forward_chain(chips, inputs):
    """
    Run one forward pass across a chain of chips.
    chips  — list of chip objects, each with .load_input(), .run(), .read_output(), .read_errors()
    inputs — list of 16 input codes
    """
    activations = inputs
    for i, chip in enumerate(chips):
        # Load current activations as inputs to this chip
        for col, code in enumerate(activations):
            chip.load_input(col, code)
        chip.run()                          # start_temporal
        activations = chip.read_outputs()   # 16 output codes

        # Pass error flags backward for feedback learning
        if i > 0:
            chips[i - 1].write_ierr(chip.read_errors())

    return activations  # final network output
```

Activation pages are 16 bytes (8-bit codes) per layer boundary — transferred
over SPI in 16 byte transactions. At 50 MHz SPI this takes ~2.6 µs, negligible
compared to the ~150 µs inference time per chip.

---

## Minimal working example

```python
# Connect to chip (substitute your transport)
from pcn_transport import WishboneOverSPI   # your SPI bridge layer

chip = WishboneOverSPI(spi_device="/dev/spidev0.0", base=0x30000000)

# Boot
chip.reset()
chip.reg_write(0x20, 4)         # 4 virtual layers
chip.wait_ready()

# Load identity weights (diagonal) into all 4 VLs
for vl in range(4):
    for r in range(16):
        for c in range(16):
            chip.load_weight(vl, r, c, 200 if r == c else 128)

# Run inference on a test input
inputs = [192 if c < 8 else 64 for c in range(16)]
for c, v in enumerate(inputs):
    chip.load_input(c, v)

chip.reg_write(0x08, 0x20)      # start_temporal
chip.wait_ready()

outputs = [chip.read_output(c) for c in range(16)]
errors  = chip.reg_read(0x28)

print("Inputs :", inputs)
print("Outputs:", outputs)
print("Errors :", bin(errors))
```

---

## Common pitfalls

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| STATUS never shows ready | RST_N not deasserted; CLK not running | Check reset line and SPI clock |
| All outputs = 128 | Weights not loaded (default = mid-scale = zero gain) | Run load_weight() sequence |
| Outputs saturate to 255 or 0 | Input activations too large; V_row outside [0.4, 1.4V] | Scale inputs: codes should stay in 50–205 range |
| IERR_DIG always all-ones | hebb_en left active from previous run | Write CTRL=0x00 to clear between runs |
| Weights drift over time (minutes) | Weight capacitor leakage; no SRAM refresh | Issue CTRL[1] (load_all) periodically to restore from SRAM |
| IRQ never fires | Interrupt line not connected or N_VIRT_LAYERS = 0 | Check IRQ wiring; set N_VIRT_LAYERS ≥ 1 |

---

## Safe input range

The analog MAC array operates correctly when input activation codes stay
within roughly 50–205 (corresponding to ~0.4–1.4 V on the row bus).
Codes outside this range clip the output.

A safe normalisation step before loading inputs:

```python
import numpy as np

def normalise_to_codes(x, lo=60, hi=196):
    """Map float array x (any range) to 8-bit codes in [lo, hi]."""
    x = np.asarray(x, dtype=float)
    x = (x - x.min()) / (x.max() - x.min() + 1e-8)  # 0..1
    return np.round(lo + x * (hi - lo)).astype(int).tolist()
```

---

## Next steps

- **Full register detail:** see Table 3 in `paper/main_v2.tex`
- **Timing and settling:** see §67 in `pred_code_networks.md`
- **GHA training loop:** see §66 in `pred_code_networks.md`
- **Multi-chip weight sync:** see §9 (Scalability) in `paper/main_v2.tex`
- **Power management (sleep mode):** CTRL[3]=1 to request sleep;
  poll STATUS[3] for acknowledgement; CTRL[1]=1 to wake and restore weights

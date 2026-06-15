# MAC Cell Layout — Setup and Workflow

## Install tools (one-time)

```bash
sudo apt install magic xschem netgen
```

Magic 8.3.105, Xschem 3.4.4, Netgen 1.5 are all in Ubuntu apt.

## PDK path

```bash
export PDK_ROOT=/home/saul/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af
export MAGICRC=$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc
```

## Step 1 — Open mac_cell in Magic GUI

```bash
cd PCNchip_design/magic/
magic -rcfile $MAGICRC mac_cell
```

The seed file `mac_cell.mag` opens with: cell boundary (10×8 µm), port labels
(IOUT, INP, INN, VW, IWRITE, WE, VDD, VSS), rough diffusion/poly/nwell regions.

## Step 2 — Layout tasks (in GUI, in order)

### 2a. Diff pair ABBA interdigitation (MN1/MN2)
- Select the ndiff region for MN1/MN2 (x=40..240 µm, y=70..150 µm)
- Insert poly gates in ABBA order: MN1|MN2|MN2|MN1 finger sequence
- Use `s` to select, `a` to add paint, `:drc` to check after each change
- Connect shared source contacts (NTAIL) between fingers

### 2b. Tail transistor MN3 (W=10µm, 4 fingers)
- Already roughed in at x=250..370, y=130..150
- Connect all 4 gate fingers to VW net on li1
- Source contacts to VSS rail; drain contact to NTAIL

### 2c. PMOS mirror MP1/MP2
- pdiff at x=30..270, y=210..290 (in n-well above y=200)
- Gates: NMP1 net (MP1 gate=drain diode-connected; MP2 gate=NMP1)
- VDD source rail at top of pdiff

### 2d. CMOS TG MN4/MP4
- MN4 (nfet 0.5/0.5): x=310..370, y=130..150 area; gate=WE
- MP4 (pfet 1.0/0.35): x=310..370, y=220..270 area; gate=WE_N
- WE_N: add 2T minimum CMOS inverter (sky130_fd_sc_hd__inv_1 reference)
  OR route WE_N from digital controller (acceptable for initial LVS)

### 2e. Weight capacitor Cw = 200 fF
- Option A: nfet gate cap, W=4.5µm L=5.3µm (Cox×23.5µm² ≈ 200fF)
  Place at x=270..360, y=60..120
- Option B: MIM cap (requires special sky130 cap layers — more complex)
  Recommended only after basic LVS passes with Option A

### 2f. Well and substrate taps
- psubstrate tap already placed (bottom-left); ensure VSS contact present
- nwell tap already placed (top-right); ensure VDD contact present
- Add more taps if DRC reports substrate/well spacing violations

### 2g. Port pins (required for LVS)
- Place a port label on each external net at the cell boundary
- Use: `port make` command or `Edit → Port` in GUI
- Port names must match Xschem schematic exactly (case-sensitive):
  IOUT, INP, INN, VW, IWRITE, WE, VDD, VSS

## Step 3 — DRC

```
:drc check
:drc listall count
```

Target: 0 violations. Common first-round violations:
- poly.9: poly not extending 0.13µm beyond active (add poly extensions)
- difftap.2: contact enclosure by diffusion < 0.06µm
- nwell.4: nwell width < 0.84µm (check MP4 area)
- li.4: li contact enclosure

## Step 4 — Extract SPICE

```
:extract all
:ext2spice hierarchy on
:ext2spice format ngspice
:ext2spice mac_cell_extracted.spice
```

## Step 5 — Netgen LVS

```bash
cd magic/
netgen -batch lvs \
  "mac_cell_extracted.spice mac_cell" \
  "../xschem/mac_cell_schematic.spice mac_cell" \
  $PDK_ROOT/sky130A/libs.tech/netgen/sky130A_setup.tcl \
  lvs_mac_cell.out
cat lvs_mac_cell.out
```

Target: "Circuits match uniquely."

## Xschem netlist export (for LVS schematic side)

```bash
cd xschem/
xschem --no-x --tcl "xschem mac_cell.sch; netlist mac_cell_schematic.spice; quit"
```

Or open in Xschem GUI, Simulation → Netlist.

## Cell size target

| Dimension | Target | Notes |
|---|---|---|
| Width | 8–12 µm | Sets column pitch for 16-col array |
| Height | 6–10 µm | Sets row pitch |
| Area | 60–100 µm² | Consistent with memory in project_pcnchip_mac_layout.md |

For 16×16 array: 16 × pitch_x × 16 × pitch_y = array area.
At 10×8 µm/cell: array = 160 × 128 µm = 20,480 µm² ≈ 0.02 mm².

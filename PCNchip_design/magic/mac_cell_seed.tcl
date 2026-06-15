# mac_cell_seed.tcl — Magic TCL layout seed for PCN MAC cell
# Sky130A, VDD=1.8V, 1 internal unit = 0.005um = 5nm
#
# Run:
#   cd PCNchip_design/magic/
#   magic -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc \
#         -dnull -noconsole < mac_cell_seed.tcl
#
# Layer names (verified from sky130_fd_sc_hd__inv_1.mag):
#   ndiff    - N+ active diffusion (NFET source/drain)
#   pdiff    - P+ active diffusion (PFET source/drain)
#   poly     - Polysilicon gate
#   ndiffc   - N+ diffusion contact (to locali)
#   pdiffc   - P+ diffusion contact (to locali)
#   polycont - Poly contact (to locali)
#   locali   - Local interconnect metal
#   nwell    - N-well region
#   nsd      - N+ diffusion in n-well (well tap)
#   psd      - P+ diffusion in p-sub  (sub tap)
#
# Coordinate plan (all in 5nm units; 1um = 200 units):
#
#   Y regions:
#     0 -  20: VSS rail (locali)
#    20 - 100: p-sub tap
#   100 - 800: NMOS region (MN3 tail + MN1/MN2 diff pair)
#   800 - 900: NTAIL routing + Cw cap
#   900 -1050: CMOS TG (MN4 nfet + WE_N inverter)
#  1050 -1200: nwell boundary starts (PMOS)
#  1200 -2000: PMOS region (MP1/MP2 mirror)
#  2000 -2050: VDD rail (locali)
#
#   X regions (cell width ~2400 units = 12um):
#     0 - 400: VSS/VDD rail + taps
#   400 - 900: MN3 (W=10um => 4 fingers x 2.5um each)
#   900 -1000: Cw cap (200fF gate cap)
#  1000 -1200: MP1 (W=4um, nf=2)
#  1200 -1400: MP2 (W=4um, nf=2)
#  1400 -1600: MN1 (W=2um, nf=2, INP gate) \ ABBA
#  1600 -1800: MN2 (W=2um, nf=2, INN gate) / interdig
#  1800 -2000: MN4 + MP4 CMOS TG
#  2000 -2400: WE_N inverter
#
# NOTE: This seed places geometry for DRC inspection. ABBA interdigitation,
# gate contacts, and internal routing are done in the GUI after this seed.
# ─────────────────────────────────────────────────────────────────────────────

load mac_cell
tech unlock *

# Helper: paint a layer in a given box
proc paint_box {layer x1 y1 x2 y2} {
    box $x1 $y1 $x2 $y2
    paint $layer
}

# ─── N-well (covers PMOS region) ──────────────────────────────────────────────
paint_box nwell  900 1050 2400 2050

# ─── p-sub tap (VSS substrate contact, bottom-left) ──────────────────────────
paint_box psd    20  20  180  100
paint_box pdiffc 32  32  168   88
paint_box locali  0   0  200   20
paint_box locali 20  20  180  100

# ─── n-well tap (VDD n-well contact, top-right) ───────────────────────────────
paint_box nsd    2220 1960 2380 2040
paint_box ndiffc 2232 1972 2368 2028
paint_box locali 2200 2030 2400 2050

# ══════════════════════════════════════════════════════════════════════════════
# MN3 — Tail transistor  W=10um, L=0.35um, 4 fingers
# Orientation: poly gates in X, W in Y
# Each finger: W_f = 2.5um = 500 units, L = 70 units
# Source (VSS) and drain (NTAIL) alternate between fingers
#   Finger layout (x):
#     400..560 : drain (NTAIL)  [160 wide = 0.8um — room for 2 contacts]
#     560..630 : gate poly  (70 wide = L=0.35um)
#     630..790 : source (VSS)
#     790..860 : gate poly
#     860..1020: drain (NTAIL)
#     1020..1090: gate poly
#     1090..1250: source (VSS)
#     1250..1320: gate poly
#     1320..1480: drain (NTAIL)
#   Active runs y=100..600 (W=2.5um each finger, 4 shared = not quite right)
#   For simplicity: single wide active region, 4 poly stripes
# ══════════════════════════════════════════════════════════════════════════════

# MN3 active region (shared across all 4 fingers)
paint_box ndiff 400 100 1480 600

# 4 poly gate stripes for MN3 (VW gate bus)
foreach gx {560 790 1020 1250} {
    set gx2 [expr {$gx + 70}]
    paint_box poly $gx [expr {100 - 26}] $gx2 [expr {600 + 26}]
}

# MN3 source contacts (VSS) — columns between gates
foreach cx {630 1090} {
    # Two contacts vertically in each source column
    paint_box ndiffc [expr {$cx+24}] 148 [expr {$cx+58}] 182
    paint_box ndiffc [expr {$cx+24}] 418 [expr {$cx+58}] 452
    paint_box locali $cx 100 [expr {$cx+160}] 600
}

# MN3 drain contacts (NTAIL) — first and last S/D columns
foreach cx {400 860 1320} {
    paint_box ndiffc [expr {$cx+24}] 148 [expr {$cx+58}] 182
    paint_box ndiffc [expr {$cx+24}] 418 [expr {$cx+58}] 452
    paint_box locali $cx 100 [expr {$cx+160}] 600
}

# MN3 gate poly contact bus (VW) — horizontal locali bus connecting all 4 gates
# polycont on each gate stripe, connected by locali
foreach gx {560 790 1020 1250} {
    set gx2 [expr {$gx + 70}]
    paint_box polycont [expr {$gx+18}] 620 [expr {$gx+52}] 654
    paint_box locali $gx 600 $gx2 660
}
paint_box locali 560 640 1320 660

# ══════════════════════════════════════════════════════════════════════════════
# Cw — 200fF gate capacitor (nfet gate cap)
# W=4.5um=900, L=5um=1000 → Cox×area ≈ 8.5e-15 × 4500nm × 5000nm = 191fF ≈ 200fF
# Place at x=1480..2380, y=100..600 (same row as MN3)
# Gate (VW): poly over active; body (S/D) to VSS
# ══════════════════════════════════════════════════════════════════════════════

paint_box ndiff  1480 100 1580 800
paint_box poly   1480 [expr {100-26}] 1580 [expr {800+26}]
paint_box ndiffc 1492 148 1526 182
paint_box ndiffc 1492 718 1526 752
paint_box locali 1480 100 1580 800

# VW poly contact for Cw gate (shared with MN3 VW bus)
paint_box polycont 1492 820 1526 854
paint_box locali   1480 800 1580 860

# ══════════════════════════════════════════════════════════════════════════════
# MN1 / MN2 — Differential pair (ABBA interdigitation)
# W=2um each, L=0.35um, nf=2 each
# Total W_active = 2um = 400 units (per device, each finger = 1um = 200 units)
# ABBA gate order: INP | INN | INN | INP (MN1 | MN2 | MN2 | MN1)
#
# Layout (x from 1600 right):
#   1600..1760 : active col 0 (NTAIL, shared source)
#   1760..1830 : poly gate 0 (INP = MN1)
#   1830..1990 : active col 1 (NMP1, MN1 drain)
#   1990..2060 : poly gate 1 (INN = MN2)
#   2060..2220 : active col 2 (NTAIL, shared source)
#   2220..2290 : poly gate 2 (INN = MN2)
#   2290..2450 : active col 3 (NMP1, MN1 drain)  ← actually should be IOUT drain
#   2450..2520 : poly gate 3 (INP = MN1)          ← wait, ABBA = MN1,MN2,MN2,MN1
#   2520..2680 : active col 4 (NTAIL)
#
# Hmm, ABBA 4-gate:  INP INN INN INP
# Alternating nets: NTAIL, NMP1, NTAIL, IOUT, NTAIL
# That means: NMP1 and IOUT both appear as "drain" nodes between gate stripes
# Correction: ABBA order with drain assignment:
#   col0: NTAIL  | gate INP (A) | col1: NMP1  | gate INN (B) | col2: NTAIL
#                                                              | gate INN (B) | col3: IOUT
#                                                                              | gate INP (A) | col4: NTAIL
# ══════════════════════════════════════════════════════════════════════════════

# Active region: x=1600..2680, y=700..1100 (W=2um = 400 units each device)
paint_box ndiff 1600 700 2680 1100

# 4 poly gates (ABBA)
foreach gx {1760 1990 2220 2450} {
    set gx2 [expr {$gx + 70}]
    paint_box poly $gx [expr {700 - 26}] $gx2 [expr {1100 + 26}]
}

# Contacts in active columns 0,2,4 → NTAIL
foreach cx {1600 2060 2520} {
    paint_box ndiffc [expr {$cx+24}] 748 [expr {$cx+58}] 782
    paint_box ndiffc [expr {$cx+24}] 1018 [expr {$cx+58}] 1052
    paint_box locali $cx 700 [expr {$cx+160}] 1100
}

# Active col 1 → NMP1 (MN1 drain)
paint_box ndiffc [expr {1830+24}] 748 [expr {1830+58}] 782
paint_box ndiffc [expr {1830+24}] 1018 [expr {1830+58}] 1052
paint_box locali 1830 700 1990 1100

# Active col 3 → IOUT (MN2 drain)
paint_box ndiffc [expr {2290+24}] 748 [expr {2290+58}] 782
paint_box ndiffc [expr {2290+24}] 1018 [expr {2290+58}] 1052
paint_box locali 2290 700 2450 1100

# Gate contacts for MN1 (gates 0 and 3, INP)
foreach gx {1760 2450} {
    paint_box polycont [expr {$gx+18}] 1120 [expr {$gx+52}] 1154
    paint_box locali $gx 1100 [expr {$gx+70}] 1160
}
paint_box locali 1760 1140 2520 1160

# Gate contacts for MN2 (gates 1 and 2, INN)
foreach gx {1990 2220} {
    paint_box polycont [expr {$gx+18}] 660 [expr {$gx+52}] 694
    paint_box locali $gx 640 [expr {$gx+70}] 700
}
paint_box locali 1990 640 2290 660

# ══════════════════════════════════════════════════════════════════════════════
# CMOS TG — MN4 (W=0.5um, L=0.5um) + MP4 (W=1um, L=0.35um)
# MN4 gate=WE (NFET, in p-sub): x=2680..2900, y=700..900
# MP4 gate=WE_N (PFET, in nwell): x=2680..2900, y=1150..1350
# Shared IWRITE drain and VW source
# ══════════════════════════════════════════════════════════════════════════════

# MN4 active (W=0.5um=100 units in y, L=0.5um=100 units in x)
paint_box ndiff  2680 700 2900 800
paint_box poly   2700 [expr {700-26}] 2800 [expr {800+26}]   ;# L=100 wide
# MN4 VW source contact (left column)
paint_box ndiffc 2692 724 2726 758
paint_box locali 2680 700 2750 800
# MN4 IWRITE drain contact (right column)
paint_box ndiffc 2816 724 2850 758
paint_box locali 2790 700 2900 800
# MN4 WE gate contact
paint_box polycont 2712 820 2746 854
paint_box locali  2700 800 2800 860

# MP4 active in nwell (W=1um=200 units in y, L=0.35um=70 units in x)
paint_box pdiff  2680 1150 2900 1350
paint_box poly   2700 [expr {1150-26}] 2770 [expr {1350+26}]   ;# L=70 wide
# MP4 VW drain contact (right column, same net as MN4 source)
paint_box pdiffc 2816 1174 2850 1326
paint_box locali 2790 1150 2900 1350
# MP4 IWRITE source contact (left column)
paint_box pdiffc 2692 1174 2726 1326
paint_box locali 2680 1150 2750 1350
# MP4 WE_N gate contact
paint_box polycont 2712 1360 2746 1394
paint_box locali  2700 1350 2770 1400

# ══════════════════════════════════════════════════════════════════════════════
# WE_N inverter — minimum CMOS inverter for complementary WE
# NFET: x=2900..3100, y=700..900
# PFET: x=2900..3100, y=1150..1350 (in nwell)
# ══════════════════════════════════════════════════════════════════════════════

paint_box ndiff  2900 700 3100 800
paint_box poly   2950 [expr {700-26}] 3020 [expr {800+26}]
paint_box ndiffc 2912 724 2946 758
paint_box ndiffc 3036 724 3070 758
paint_box locali 2900 700 3100 800

paint_box pdiff  2900 1150 3100 1350
paint_box poly   2950 [expr {1150-26}] 3020 [expr {1350+26}]
paint_box pdiffc 2912 1174 2946 1326
paint_box pdiffc 3036 1174 3070 1326
paint_box locali 2900 1150 3100 1350

# Shared gate (WE input to inverter, WE_N output)
paint_box polycont 2962 820 2996 854
paint_box polycont 2962 1360 2996 1394
paint_box locali 2950 700 3020 1400

# ══════════════════════════════════════════════════════════════════════════════
# PMOS current mirror — MP1 (diode-connected) and MP2 (mirror out)
# W=4um each, L=0.35um, nf=2 each (each finger W_f=2um=400 units)
# In n-well; orientation: poly in X, W in Y (matching NMOS convention)
# MP1: x=200..800, y=1200..2000 (W total = 4um across 2 fingers)
# MP2: x=800..1400, y=1200..2000
# ══════════════════════════════════════════════════════════════════════════════

# MP1 active (2 fingers, total W=4um, each finger 2um=400 units in y)
paint_box pdiff 200 1200 800 2000

# MP1 gate poly (NMP1 net, diode-connected: gate = drain)
# Finger 1: gate at x=340..410, Finger 2: gate at x=590..660
foreach gx {340 590} {
    set gx2 [expr {$gx + 70}]
    paint_box poly $gx [expr {1200-26}] $gx2 [expr {2000+26}]
}

# MP1 VDD source contacts (left of finger 1, right of finger 2, between fingers)
foreach cx {200 660 750} {
    paint_box pdiffc [expr {$cx+12}] 1248 [expr {$cx+46}] 1282
    paint_box pdiffc [expr {$cx+12}] 1900 [expr {$cx+46}] 1934
    paint_box locali $cx 1200 [expr {$cx+140}] 2000
}

# MP1 NMP1 drain contacts (between gate 0 and gate 1, and far right)
# Drain col: x=410..590
paint_box pdiffc [expr {410+12}] 1248 [expr {410+46}] 1282
paint_box pdiffc [expr {410+12}] 1900 [expr {410+46}] 1934
paint_box locali 410 1200 590 2000

# MP1 gate contacts (NMP1 = gate and drain same net: diode-connected)
foreach gx {340 590} {
    paint_box polycont [expr {$gx+18}] 2020 [expr {$gx+52}] 2054
    paint_box locali   $gx 2000 [expr {$gx+70}] 2060
}
paint_box locali 340 2040 660 2060

# MP2 active (2 fingers, total W=4um)
paint_box pdiff 800 1200 1400 2000

# MP2 gate poly (NMP1 net — mirrors MP1 gate)
foreach gx {940 1190} {
    set gx2 [expr {$gx + 70}]
    paint_box poly $gx [expr {1200-26}] $gx2 [expr {2000+26}]
}

# MP2 VDD source contacts
foreach cx {800 1260 1350} {
    paint_box pdiffc [expr {$cx+12}] 1248 [expr {$cx+46}] 1282
    paint_box pdiffc [expr {$cx+12}] 1900 [expr {$cx+46}] 1934
    paint_box locali $cx 1200 [expr {$cx+140}] 2000
}

# MP2 IOUT drain contacts (between gate 0 and gate 1)
paint_box pdiffc [expr {1010+12}] 1248 [expr {1010+46}] 1282
paint_box pdiffc [expr {1010+12}] 1900 [expr {1010+46}] 1934
paint_box locali 1010 1200 1190 2000

# MP2 gate contacts (connected to NMP1 bus from MP1)
foreach gx {940 1190} {
    paint_box polycont [expr {$gx+18}] 2020 [expr {$gx+52}] 2054
    paint_box locali   $gx 2000 [expr {$gx+70}] 2060
}
paint_box locali 940 2040 1260 2060

# ─── VDD and VSS rails (locali) ───────────────────────────────────────────────
paint_box locali   0 2030 3200 2050   ;# VDD rail
paint_box locali   0    0 3200   20   ;# VSS rail

# ─── Cell boundary ────────────────────────────────────────────────────────────
box 0 0 3200 2050

# ─── Port labels ──────────────────────────────────────────────────────────────
label "VSS"    1600     0     1700    20
label "VDD"    1600  2030     1700  2050
label "IOUT"   1010  1600     1190  1700
label "INP"    1760  1140     1900  1160
label "INN"    1990   640     2200   660
label "VW"      560   640      660   660
label "IWRITE" 2790   740     2900   760
label "WE"     2950   820     3020   860

# ─── Save ─────────────────────────────────────────────────────────────────────
save mac_cell

puts ""
puts "mac_cell.mag saved."
puts "Cell bounding box: 0 0 3200 2050 (16um x 10.25um at 5nm/unit)"
puts ""
puts "NEXT STEPS:"
puts "  1. Open in GUI: magic -rcfile \$MAGICRC magic/mac_cell"
puts "  2. Run DRC: :drc check  — expect many violations on first pass"
puts "  3. Key fixes: poly end-caps (poly.4), contact enclosures (difftap.2),"
puts "                NMOS/PMOS in correct well, gate routing"
puts "  4. Route internal nets: NMP1, NTAIL, IWRITE, VW on locali"
puts "  5. After DRC clean: extract all; ext2spice; netgen LVS"
puts ""
quit

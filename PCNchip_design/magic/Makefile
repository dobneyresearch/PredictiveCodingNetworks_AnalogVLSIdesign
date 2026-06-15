# Makefile — MAC cell analog layout flow
# Targets: seed | drc | extract | lvs | clean
#
# Requires: magic (>=8.3), netgen (>=1.5), xschem, ngspice
# PDK: Sky130A via volare
#
# Usage:
#   make seed       — create mac_cell.mag from TCL seed script (first time only)
#   make drc        — run Magic DRC in batch, report violation count
#   make extract    — extract SPICE netlist from layout
#   make lvs        — run Netgen LVS: layout vs schematic
#   make netlist    — export netlist from Xschem schematic

PDK_ROOT ?= $(shell \
  for d in $(HOME)/.volare/volare/sky130/versions/*/; do \
    test -f "$$d/sky130A/libs.tech/ngspice/sky130.lib.spice" && echo $$d && break; \
  done)

MAGICRC  := $(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc
MAGIC    := magic -rcfile $(MAGICRC) -dnull -noconsole
NETGEN   := netgen -batch
XSCHEM   := xschem --no-x --tcl

CELL     := mac_cell
SCH      := ../xschem/$(CELL).sch
SCH_SPICE:= $(CELL)_schematic.spice
LAY_SPICE:= $(CELL)_extracted.spice

.PHONY: all seed drc extract lvs netlist clean

all: drc lvs

# ── Seed: create initial mac_cell.mag ────────────────────────────────────
seed:
	@echo "=== Creating $(CELL).mag from seed script ==="
	$(MAGIC) $(CELL)_seed.tcl
	@echo "Done. Open in GUI: magic -rcfile $(MAGICRC) $(CELL)"

# ── Netlist: export SPICE from Xschem schematic ───────────────────────────
$(SCH_SPICE): $(SCH)
	@echo "=== Exporting netlist from Xschem ==="
	$(XSCHEM) "xschem $(SCH); netlist $(SCH_SPICE); quit"

netlist: $(SCH_SPICE)

# ── DRC: batch Magic DRC ─────────────────────────────────────────────────
drc: $(CELL).mag
	@echo "=== Running Magic DRC on $(CELL) ==="
	$(MAGIC) - << 'EOF'
load $(CELL)
drc check
set n [drc list count total]
puts "DRC violation count: $$n"
if {$$n == 0} { puts "DRC CLEAN" } else { puts "DRC FAIL: $$n violations" }
quit
EOF

# ── Extract: layout → SPICE ──────────────────────────────────────────────
$(LAY_SPICE): $(CELL).mag
	@echo "=== Extracting SPICE from layout ==="
	$(MAGIC) - << 'EOF'
load $(CELL)
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice $(LAY_SPICE)
quit
EOF

extract: $(LAY_SPICE)

# ── LVS: Netgen layout vs schematic ──────────────────────────────────────
lvs: $(LAY_SPICE) $(SCH_SPICE)
	@echo "=== Running Netgen LVS ==="
	$(NETGEN) lvs \
	  "$(LAY_SPICE) $(CELL)" \
	  "$(SCH_SPICE) $(CELL)" \
	  $(PDK_ROOT)/sky130A/libs.tech/netgen/sky130A_setup.tcl \
	  lvs_$(CELL).out
	@echo "=== LVS report: lvs_$(CELL).out ==="
	@tail -5 lvs_$(CELL).out

# ── Clean ─────────────────────────────────────────────────────────────────
clean:
	rm -f *.ext *.sim *.nodes $(LAY_SPICE) $(SCH_SPICE) lvs_$(CELL).out

#!/usr/bin/env bash
# =============================================================================
# PCN MAC Cell — ngspice simulation runner
# Usage:  ./run_sim.sh [--pdk-root /path/to/pdk] [--corner tt|ss|ff]
#
# Runs all four analyses in pcn_tb_all.spice:
#   1. DC operating point
#   2. DC transfer curve
#   3. Transient input step
#   4. Hebbian weight write
#
# Output files are written to ./output/
# A summary of key metrics is printed at the end.
#
# Requirements:
#   ngspice 37+   apt install ngspice  /  brew install ngspice
#   Sky130A PDK   pip install volare && volare enable --pdk sky130 sky130A
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
CORNER="tt"
NETLIST="pcn_tb_all.spice"
OUTDIR="output"
TMPFILE="/tmp/pcn_run_$$.spice"   # $$ = PID, unique per invocation

# ── Colour codes (disabled automatically if not a terminal) ───────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────
info()  { echo -e "${CYAN}[info]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}  $*"; }
die()   { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pdk-root)   PDK_ROOT="$2"; shift 2 ;;
    --corner)     CORNER="$2";   shift 2 ;;
    --netlist)    NETLIST="$2";  shift 2 ;;
    --outdir)     OUTDIR="$2";   shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) die "Unknown argument: $1  (use --help for usage)" ;;
  esac
done

# ── Locate PDK_ROOT ───────────────────────────────────────────────────────
# Search order: --pdk-root arg → $PDK_ROOT env → common install paths
if [ -z "${PDK_ROOT:-}" ]; then
  for candidate in \
      "$HOME/.volare" \
      "/usr/share/pdk" \
      "/foss/pdks" \
      "/usr/local/share/pdk" \
      "$HOME/pdk"; do
    if [ -f "$candidate/sky130A/libs.tech/ngspice/sky130.lib.spice" ]; then
      PDK_ROOT="$candidate"
      break
    fi
  done
fi

PDK_LIB="${PDK_ROOT:-}/sky130A/libs.tech/ngspice/sky130.lib.spice"

# ── Pre-flight checks ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}PCN MAC Cell — SPICE Simulation${RESET}"
echo "──────────────────────────────────────────"

# ngspice
NGSPICE_BIN=$(command -v ngspice 2>/dev/null || true)
if [ -z "$NGSPICE_BIN" ]; then
  die "ngspice not found.\n  Install: apt install ngspice\n           brew install ngspice"
fi
NGSPICE_VER=$(ngspice --version 2>&1 | grep -oP 'ngspice[-_ ]\K[0-9]+' | head -1 || echo "unknown")
if [ "$NGSPICE_VER" != "unknown" ] && [ "$NGSPICE_VER" -lt 37 ]; then
  warn "ngspice $NGSPICE_VER detected; version 37+ recommended."
  warn "wrdata CSV export and alter @source[param] may not work."
fi
ok "ngspice ${NGSPICE_VER} at ${NGSPICE_BIN}"

# PDK
if [ ! -f "$PDK_LIB" ]; then
  die "Sky130A PDK not found.\n  Expected: $PDK_LIB\n  Install:  pip install volare && volare enable --pdk sky130 sky130A\n  Or pass:  --pdk-root /path/to/pdk"
fi
ok "PDK at ${PDK_ROOT}"

# Netlist
if [ ! -f "$NETLIST" ]; then
  die "Netlist not found: $NETLIST"
fi
if [ ! -f "pcn_mac_cell.spice" ]; then
  die "Cell library not found: pcn_mac_cell.spice"
fi
ok "Netlist: ${NETLIST}"
info "Corner:  ${CORNER}"

# ── Output directory ──────────────────────────────────────────────────────
mkdir -p "$OUTDIR"
info "Output:  ${OUTDIR}/"

# ── Substitute PDK_ROOT and corner into a temp copy of the netlist ────────
# The netlist contains literal "$PDK_ROOT" and the corner string "tt".
# We replace them here so ngspice receives concrete paths.
sed \
  -e "s|\\\$PDK_ROOT|${PDK_ROOT}|g" \
  -e "s|\.lib.*sky130\.lib\.spice\" tt|.lib \"${PDK_LIB}\" ${CORNER}|" \
  "$NETLIST" > "$TMPFILE"

# Ensure temp file is removed on exit (even on error)
trap 'rm -f "$TMPFILE"' EXIT

# ── Run ngspice ───────────────────────────────────────────────────────────
echo ""
info "Starting ngspice..."
LOGFILE="${OUTDIR}/sim.log"
START_TIME=$(date +%s)

# -b  batch mode (no GUI)
# -o  write stdout+stderr to log file
# -r  not used here (raw files written by .control block instead)
if ngspice -b -o "$LOGFILE" "$TMPFILE"; then
  END_TIME=$(date +%s)
  ELAPSED=$(( END_TIME - START_TIME ))
  ok "Simulation finished in ${ELAPSED}s"
else
  NGSPICE_EXIT=$?
  echo ""
  warn "ngspice exited with code ${NGSPICE_EXIT}."
  warn "Last 20 lines of log:"
  tail -20 "$LOGFILE" | sed 's/^/  /'
  die "Simulation failed. Full log: ${LOGFILE}"
fi

# ── Check expected output files ───────────────────────────────────────────
echo ""
info "Checking output files..."
MISSING=0
for f in \
    "${OUTDIR}/a1_op.raw" \
    "${OUTDIR}/a2_dc.raw" \
    "${OUTDIR}/a2_transfer.csv" \
    "${OUTDIR}/a3_step.raw" \
    "${OUTDIR}/a3_step.csv" \
    "${OUTDIR}/a4_write.raw" \
    "${OUTDIR}/a4_write.csv"; do
  if [ -f "$f" ]; then
    SIZE=$(wc -c < "$f")
    ok "$(printf '%-32s' "$(basename $f)") ${SIZE} bytes"
  else
    warn "Missing: $f"
    MISSING=$(( MISSING + 1 ))
  fi
done

if [ $MISSING -gt 0 ]; then
  warn "${MISSING} expected output file(s) not written."
  warn "Check ${LOGFILE} for ngspice errors."
fi

# ── Extract key metrics from log ──────────────────────────────────────────
echo ""
info "Key metrics from simulation log:"
# grep lines from the .control echo statements
grep -E "^\s+(gm at|I_out|Tail|Weight|Retention|ΔVw|V\(nvw\)|I\(MN3\)|Peak)" "$LOGFILE" \
  | sed 's/^/  /' || true

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────"
echo -e "${BOLD}Output files:${RESET}"
ls -lh "${OUTDIR}/"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  View raw files interactively:"
echo "    ngspice -r ${OUTDIR}/a2_dc.raw"
echo "    gaw ${OUTDIR}/a2_dc.raw              # if gaw installed"
echo ""
echo "  Plot CSVs (requires matplotlib):"
echo "    python3 plot_results.py"
echo ""
echo "  Full simulation log:"
echo "    cat ${LOGFILE}"
echo ""

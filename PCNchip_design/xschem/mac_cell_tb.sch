v {xschem version=3.4.5 file_version=1.2}
G {}
K {}
V {}
S {}
E {}

** ============================================================
** mac_cell_tb — DC operating-point + transfer-curve testbench
** Matches tb_temporal_full.spice operating conditions:
**   VDD=1.8V, Vcm=0.9V, Vw=0.9V (balanced weight)
**   INP swept ±50mV around Vcm; INN=Vcm
**   IWRITE=VSS, WE=VSS → weight hold
** ============================================================

** DUT
C {xschem/mac_cell.sym} 300 -300 0 0 {name=XDUT}

** Supplies
C {devices/vsource.sym}  -50 -300 0 0 {name=VVDD value=1.8 savecurrent=false}
C {devices/vsource.sym}  -50 -200 0 0 {name=VVSS value=0   savecurrent=false}
C {devices/vsource.sym}  100 -400 0 0 {name=VVCM value=0.9 savecurrent=false}
C {devices/vsource.sym}  100 -300 0 0 {name=VVW  value=0.9 savecurrent=false}

** INP: DC sweep source (±50mV around Vcm)
C {devices/vsource.sym}  100 -200 0 0 {name=VINP value="0.9" savecurrent=false}

** IWRITE=VSS, WE=VSS (hold mode)
C {devices/vsource.sym}  500 -300 0 0 {name=VIWRITE value=0 savecurrent=false}
C {devices/vsource.sym}  500 -200 0 0 {name=VWE     value=0 savecurrent=false}

** Load: 100kΩ from IOUT to VDD (single-cell reference load)
C {devices/res.sym} 450 -400 0 0 {name=RLOAD value=100k}

** Ports / net labels
C {devices/lab_wire.sym}  -50 -350 0 0 {name=lVDD lab=VDD}
C {devices/lab_wire.sym}  -50 -150 0 0 {name=lVSS lab=VSS}
C {devices/lab_wire.sym}  100 -450 0 0 {name=lVCM lab=VCM}
C {devices/lab_wire.sym}  100 -350 0 0 {name=lVW  lab=VW}
C {devices/lab_wire.sym}  100 -250 0 0 {name=lINP lab=INP}

** .dc and .op commands embedded as text
C {devices/code.sym} 0 -600 0 0 {name=SIMCMDS
only_toplevel=true
value="
.lib $PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice tt
.op
.dc VINP 0.85 0.95 0.001
.save V(IOUT) V(INP) V(VW) V(NTAIL)
"}

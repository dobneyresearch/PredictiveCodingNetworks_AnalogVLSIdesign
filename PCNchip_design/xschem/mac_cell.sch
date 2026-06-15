v {xschem version=3.4.5 file_version=1.2}
G {}
K {}
V {}
S {}
E {}

** ============================================================
** mac_cell — PCN single-weight multiply-accumulate cell
** Sky130A  VDD=1.8V  VSS=0V
**
** Ports: IOUT INP INN VW IWRITE WE VDD VSS
**
** Transistors:
**   MP1 (pfet W=4/L=0.35): diode-connected PMOS, current mirror ref
**   MP2 (pfet W=4/L=0.35): current mirror output → IOUT
**   MN1 (nfet W=2/L=0.35): diff pair +  (gate=INP)
**   MN2 (nfet W=2/L=0.35): diff pair -  (gate=INN)
**   MN3 (nfet W=10/L=0.35): tail transistor (gate=VW = weight)
**   MN4 (nfet W=0.5/L=0.5): CMOS TG NMOS  (gate=WE)
**   MP4 (pfet W=1.0/L=0.35): CMOS TG PMOS  (gate=WE_N = VDD-WE)
**   Cw  (200fF): weight storage capacitor VW→VSS
** ============================================================

** -- PMOS current mirror load --
** MP1: drain=NMP1, gate=NMP1 (diode-connected), source=VDD, bulk=VDD
C {sky130_fd_pr/pfet_01v8.sym} 170 -490 0 0 {name=MP1
W=4 L=0.35 nf=2 mult=1
model=sky130_fd_pr__pfet_01v8
spiceprefix=X}
** MP2: drain=IOUT, gate=NMP1, source=VDD, bulk=VDD
C {sky130_fd_pr/pfet_01v8.sym} 370 -490 0 0 {name=MP2
W=4 L=0.35 nf=2 mult=1
model=sky130_fd_pr__pfet_01v8
spiceprefix=X}

** -- NMOS differential pair --
** MN1: drain=NMP1, gate=INP, source=NTAIL, bulk=VSS
C {sky130_fd_pr/nfet_01v8.sym} 170 -310 0 0 {name=MN1
W=2 L=0.35 nf=2 mult=1
model=sky130_fd_pr__nfet_01v8
spiceprefix=X}
** MN2: drain=IOUT, gate=INN, source=NTAIL, bulk=VSS
C {sky130_fd_pr/nfet_01v8.sym} 370 -310 0 0 {name=MN2
W=2 L=0.35 nf=2 mult=1
model=sky130_fd_pr__nfet_01v8
spiceprefix=X}

** -- Tail current transistor (weight) --
** MN3: drain=NTAIL, gate=VW, source=VSS, bulk=VSS
C {sky130_fd_pr/nfet_01v8.sym} 270 -170 0 0 {name=MN3
W=10 L=0.35 nf=4 mult=1
model=sky130_fd_pr__nfet_01v8
spiceprefix=X}

** -- Weight storage capacitor --
** Cw: 200fF from VW to VSS
** Use nfet_g capacitor or explicit cap device in Sky130
C {sky130_fd_pr/nfet_01v8.sym} 530 -170 0 0 {name=Cw
W=5 L=0.5 nf=1 mult=1
model=sky130_fd_pr__nfet_01v8
spiceprefix=X
comment="MOS cap: gate=VW, drain/source=VSS, W×L≈200fF"}

** -- CMOS Transmission Gate (weight access) --
** MN4: NMOS TG: drain=IWRITE, gate=WE,   source=VW, bulk=VSS
C {sky130_fd_pr/nfet_01v8.sym} 530 -310 0 0 {name=MN4
W=0.5 L=0.5 nf=1 mult=1
model=sky130_fd_pr__nfet_01v8
spiceprefix=X}
** MP4: PMOS TG: source=IWRITE, gate=WE_N, drain=VW, bulk=VDD
C {sky130_fd_pr/pfet_01v8.sym} 530 -390 0 0 {name=MP4
W=1.0 L=0.35 nf=1 mult=1
model=sky130_fd_pr__pfet_01v8
spiceprefix=X}

** -- WE_N inverter (B-source in SPICE; invert WE for MP4 gate) --
** In layout/schematic: use a minimum-size sky130 inverter cell or a
** simple PMOS/NMOS pair tied to WE.  For LVS the gate net is WE_N.
C {sky130_fd_pr/nfet_01v8.sym} 670 -310 0 0 {name=MINVn
W=1 L=0.5 nf=1 mult=1
model=sky130_fd_pr__nfet_01v8
spiceprefix=X
comment="WE inverter NMOS: drain=WE_N, gate=WE, source=VSS"}
C {sky130_fd_pr/pfet_01v8.sym} 670 -390 0 0 {name=MINVp
W=2 L=0.5 nf=1 mult=1
model=sky130_fd_pr__pfet_01v8
spiceprefix=X
comment="WE inverter PMOS: drain=WE_N, gate=WE, source=VDD"}

** ── Ports ────────────────────────────────────────────────────────────────────
C {devices/iopin.sym}  -30 -490 0 0 {name=PVDD   lab=VDD}
C {devices/iopin.sym}  -30 -100 0 0 {name=PVSS   lab=VSS}
C {devices/opin.sym}   470 -490 0 0 {name=PIOUT  lab=IOUT}
C {devices/ipin.sym}    70 -310 0 0 {name=PINP   lab=INP}
C {devices/ipin.sym}   470 -310 0 0 {name=PINN   lab=INN}
C {devices/iopin.sym}  530 -100 0 0 {name=PVW    lab=VW}
C {devices/ipin.sym}   620 -350 0 0 {name=PIWRITE lab=IWRITE}
C {devices/ipin.sym}   760 -350 0 0 {name=PWE    lab=WE}

** ── Internal nets (wires) ──────────────────────────────────────────────────
** NMP1 — connects MP1 drain/gate, MN1 drain
N 170 -450 170 -350 {}
N 170 -450 370 -450 {}
N 170 -450 170 -350 {}

** VDD rail — MP1 source, MP2 source, MINVp source
N  -30 -490 170 -490 {}
N  170 -490 370 -490 {}
N  370 -490 670 -490 {}

** IOUT — MP2 drain, MN2 drain
N 370 -450 370 -350 {}
N 370 -450 470 -450 {}

** NTAIL — MN1 source, MN2 source, MN3 drain
N 170 -270 270 -270 {}
N 270 -270 370 -270 {}
N 270 -270 270 -210 {}

** VSS rail — MN3 source, Cw gate-body, MINVn source, MN4 bulk
N -30 -100 270 -100 {}
N 270 -100 530 -100 {}
N 530 -100 670 -100 {}
N 270 -130 270 -100 {}

** VW — MN3 gate, Cw gate, MN4 source, MP4 drain
N 530 -210 530 -170 {}
N 530 -270 530 -350 {}

** IWRITE — MN4 drain, MP4 source
N 530 -350 530 -330 {}

** WE_N — MP4 gate, MINVn/MINVp drains
N 670 -350 630 -350 {}

** WE — MN4 gate, MINVn/MINVp gates
N 760 -350 670 -350 {}

** ── Labels on key internal nodes ─────────────────────────────────────────────
C {devices/lab_wire.sym} 200 -450 0 0 {name=lNMP1  lab=NMP1}
C {devices/lab_wire.sym} 270 -260 0 0 {name=lNTAIL lab=NTAIL}
C {devices/lab_wire.sym} 540 -230 0 0 {name=lVW2   lab=VW}
C {devices/lab_wire.sym} 680 -345 0 0 {name=lWEN   lab=WE_N}

# FeFET and Weight Storage at Sub-28nm Geometries

*Written 2026-06-15 as a companion to §73 of pred_code_networks.md and the Scalability sections of main_v2.tex.*

---

## The core problem: why capacitors fail as nodes shrink

The PCN weight is a voltage stored on a capacitor (Cw). The transistor MN3 reads that voltage as a gate bias, which sets the tail current, which sets the gain. The whole computation depends on that voltage being stable.

The voltage drifts because charge leaks off the capacitor. There are two leak paths, and they get worse in different ways as the node shrinks:

**Junction leakage** (through the reverse-biased transistor drain/source to bulk) scales roughly as junction area. Since the transistor physically shrinks, junction leakage actually improves slightly. This isn't the main problem.

**Gate tunnelling leakage** is the killer. This is quantum mechanical — electrons tunnel directly through the gate oxide from the channel into the gate metal (or vice versa), even though there's no classical mechanism to do so. The probability depends exponentially on oxide thickness: halve the thickness and leakage goes up by roughly 10,000×.

At 130nm, the gate oxide is about 6nm thick. Tunnelling is essentially zero — you'd wait years to lose one LSB. At 28nm, the oxide is ~2.5nm. Leakage is now 100–10,000× higher; you lose an 8-bit LSB in about 4 seconds. That's manageable — the SRAM shadow refreshes every second, problem solved. At 7nm, the equivalent oxide thickness is ~1.5nm, and tunnelling is now ~10,000× the 130nm value. You lose a weight bit in under a millisecond. No refresh mechanism is fast enough; the fundamental storage mechanism has broken.

---

## Why MIM capacitors only push the problem, not solve it

The MIM (metal-insulator-metal) capacitor sits in the metal interconnect stack above the transistors. Its insulator is deposited by atomic layer deposition — usually aluminium oxide (Al₂O₃) or hafnium oxide (HfO₂) — rather than grown thermally. This matters because ALD films have much lower tunnelling leakage than thermal oxides at the same thickness. The same field that drives 1 pA/µm² through a 1.5nm thermal oxide drives only about 10 fA/µm² through an ALD HfO₂ film — roughly 10,000× lower.

So MIM capacitors genuinely fix the leakage problem at 7nm. A 20 fF MIM cap in ~2 µm² at 7nm drifts at about 0.5 mV/s — a 4-second hold-time for 8-bit precision. With 1-second SRAM refresh, that works.

The issue is area. At 7nm, a 20 fF MIM cap takes ~2 µm². The entire MAC cell target is ~5 µm². The capacitor alone is already 40% of the cell. There's no room left to scale the cell further. You've effectively hit a floor: the cap won't get meaningfully smaller because you can't reduce Cw without proportionally reducing the Hebbian charge (Ihebb × tpulse), and at some point the Hebbian current pulses become too small to control reliably against thermal noise and transistor matching variation.

So MIM caps work at 7nm but they stop the area scaling. Below 7nm, you're stuck.

---

## What a FeFET actually is

A standard MOSFET has: gate metal → silicon dioxide (dielectric) → silicon channel. The oxide is a passive insulator — it does nothing except prevent current from flowing gate-to-channel.

A FeFET replaces the gate dielectric (or adds a layer adjacent to it) with a **ferroelectric** material. HfO₂ doped with zirconium (HfZrO₂, or HZO) is the commercially practical version, used in GlobalFoundries' 22FDX-FE process.

Ferroelectric materials have a property that regular dielectrics don't: the dipoles inside the crystal can be permanently aligned by an applied electric field, and they stay aligned when the field is removed. More specifically, the polarisation can sit in one of two stable states — call them "up" (positive polarisation pointing toward the gate) and "down". Applying a voltage pulse above the coercive field flips the polarisation. Remove the voltage; the polarisation remains. This is the same principle as ferroelectric RAM (FeRAM), which has been around for decades.

The polarisation state shifts the transistor's threshold voltage. If polarisation is "up", it lowers Vth (easier to turn on). If "down", it raises Vth (harder to turn on). The shift ΔVth is typically 0.3–0.6V in HZO films at 22nm.

A FeFET is therefore a transistor whose threshold voltage can be set non-volatilely by electrical pulses. No capacitor. No leakage path. The polarisation is a crystallographic state, not an electrostatic charge — it doesn't leak away.

---

## How this would work in the PCN chip

There are two architecturally distinct ways to use FeFET here:

**Option A — FeFET replaces the storage cap**

Keep the 5T MAC cell exactly as designed. MN3 gate currently connects to Cw (the floating storage capacitor). Replace Cw with a FeFET: a dedicated storage transistor whose threshold voltage is set by ferroelectric polarisation, and whose source-follower output drives MN3's gate. The FeFET holds a voltage non-volatilely; MN3 "reads" that voltage the same way it reads Vw today. The MAC computation is unchanged. The Hebbian write path now applies voltage pulses to the FeFET gate instead of current pulses into Cw.

This is the drop-in approach. It requires the FeFET to produce a well-defined analogue output voltage (acting as a voltage reference), which adds some complexity.

**Option B — MN3 itself becomes a FeFET**

Replace MN3's gate oxide with a ferroelectric stack. MN3's threshold voltage is now the weight. The tail current I_tail = f(Vgs_eff) where Vgs_eff = Vbias_n − Vth_ferro. Changing Vth by applying a polarisation pulse directly changes the gain. No separate storage node at all.

This is more elegant — the weight storage and the weight readout happen in the same physical device. But it means MN3's gate is no longer a passive node: you need to apply programming pulses to it while the circuit is operating.

Option B is architecturally cleaner but more complex to design. Option A is a safer first implementation.

In both cases, the SRAM shadow becomes redundant for retention — the FeFET state survives power cycles. The shadow could still be kept for rapid in-training access (see hybrid architecture below).

---

## The real challenges

### 1. Endurance — the biggest problem

Every time the ferroelectric is switched, it fatigues slightly. The domain walls that flip back and forth gradually become pinned by defects introduced during switching. After enough cycles, the ΔVth window collapses — the material can no longer be fully polarised in either direction, and eventually becomes paraelectric (no stable polarisation at all).

Current HfO₂-based FeFETs: endurance is typically 10⁴ to 10⁶ write cycles before ΔVth degrades significantly. Some optimised processes reach 10⁸–10⁹ cycles, but this is not yet standard.

Consider the PCN chip in online learning mode. If inference runs at 5,000 inputs/second (plausible with N=100 temporal VLs at 150 µs each), and every weight updates every training step, that's 5,000 FeFET write cycles per second per cell:

| Endurance | Time to failure |
|-----------|----------------|
| 10⁴ cycles | 2 seconds |
| 10⁶ cycles | 3 minutes |
| 10⁸ cycles | 5.5 hours |
| 10⁹ cycles | 55 hours |

None of these are acceptable for a chip designed to learn continuously.

### 2. Analogue precision

For 8-bit weight resolution, we need to reliably program 256 distinct threshold voltage states. With ΔVth = 0.4V, that's 256 steps of 1.5 mV each.

The problem: ferroelectric domain switching is stochastic. The HZO film consists of many nanoscale domains (~10–50 nm diameter), each of which flips independently when the coercive field is locally exceeded. For a small programming pulse, a random subset of domains switches. The resulting ΔVth is the statistical mean of the switched fraction — but the standard deviation depends on device area and film uniformity.

At 7nm cell dimensions, the FeFET gate area might be only 200 nm², containing 10–50 domains. The domain-by-domain stochastic switching of such a small population gives enormous cell-to-cell variation. The best experimentally demonstrated precision from a single FeFET device is **3–4 bits** — not 8 bits. Getting to 6 bits requires either larger device area (which defeats the purpose) or extensive per-cell calibration.

This is a fundamental physics constraint, not just a current-technology gap.

### 3. Retention under temperature and time

Ferroelectric retention is excellent for digital (binary) storage — the two fully polarised states are stable for 10+ years at room temperature. But for analogue multi-level storage, the intermediate states are less stable.

At elevated temperature (60–85°C junction temperature, typical in a data centre), ferroelectric domains undergo thermally activated back-switching. Partial polarisation states drift back toward the preferred (lowest-energy) state. Over 10 years at 85°C, a device programmed to an intermediate state may drift by 20–30 mV — representing 10–20 steps at 1.5 mV/step, which is significant for 8-bit precision.

For training scenarios (weights update frequently anyway), this is mostly irrelevant — the Hebbian rule will re-correct. For inference-only deployment where weights are programmed once and left, this is a real concern.

### 4. Other challenges (secondary)

- **Write disturb**: unselected FeFETs in the same row/column can be partially switched by write pulses. Manageable with individually addressed cells and careful pulse voltage design.
- **Temperature-dependent coercive voltage**: the switching threshold varies with temperature → write voltage calibration may need temperature compensation, or fixed safe-margin pulses slightly above Vc.
- **Read disturb**: at GF 22FDX-FE with Vc ≈ 0.8–1.0V and VDD = 0.8V, the natural read voltage is well below Vc, so read disturb is limited. VG_read should be kept below 50% of Vc.
- **Process maturity**: GF 22FDX-FE is a real commercial process, but analogue FeFET device models are less mature than standard CMOS. More simulation uncertainty than TSMC 28nm.

---

## The solution: hybrid two-tier weight storage

Rather than making FeFET do everything, the right approach splits weight storage into two tiers matched to their use case.

**Tier 1 — Fast online learning: analogue capacitor + SRAM (existing design)**

The Cw + SRAM architecture stays exactly as designed. All Hebbian updates happen here. Weights can be updated thousands of times per second with no endurance concern. At smaller nodes, Cw shrinks to 20–50 fF MIM cap; at 7nm this still fits in the BEOL stack.

**Tier 2 — Non-volatile long-term storage: FeFET**

After training converges (or periodically, say every 1,000 steps), the chip commits the current weight state to FeFET. This is a verify-and-write process: read Cw (via the existing SRAM/DAC path), write the FeFET to match.

With periodic commit at every 1,000 steps running at 5,000 steps/second: 5 FeFET writes/second.

| Endurance | Lifetime |
|-----------|---------|
| 10⁶ cycles | 55 hours |
| 10⁸ cycles | 5.5 years |
| 10⁹ cycles | 55 years — effectively unlimited |

On power-up: restore Cw from FeFET. No host memory needed. True non-volatile analogue weight persistence without the endurance problem.

**For precision**: the 4-bit FeFET constraint doesn't matter because FeFET is only used for coarse weight initialisation at boot. Fine-grained learning runs on Cw. The effective precision is 8 bits (from Cw); the FeFET just needs 4–5 bits to restore the correct region so that training converges quickly after power-on rather than from scratch.

This maps onto how biological memory works: fast synaptic potentiation (Cw) for moment-to-moment plasticity, slow structural consolidation (FeFET) for long-term retention. The architecture already has the right separation — the SRAM shadow that currently provides persistence gets replaced by a more compact FeFET layer.

New FSM states would be needed for the commit and restore paths, and per-cell pulse calibration circuitry would be required, but nothing fundamentally novel.

---

## Robustness assessment

| Challenge | Solvable? | How | Residual risk |
|-----------|-----------|-----|---------------|
| Leakage at sub-7nm | **Yes, definitively** | FeFET crystallographic state has no leakage mechanism | Very low |
| Endurance with online learning | **Yes, with hybrid architecture** | Commit infrequently (~5 writes/sec); FeFET endurance is no longer the constraint | Low with proper design |
| 8-bit precision from single FeFET | **No, not yet** | Accept 4–5 bits per FeFET; use Cw for fine weight during training | Moderate — requires Hebbian to re-converge after each power cycle |
| Retention of multi-level analogue state | **Moderate** | Use coarse precision (4–5 bits) where thermal drift is tolerable | Moderate at high temperature |
| Process maturity (GF 22FDX-FE) | **Moderate risk** | Real commercial process, but analogue models less mature | Higher than TSMC 28nm — more simulation uncertainty |
| Write disturb | **Yes** | Individually addressed cells; half-select manageable | Low |
| Temperature-dependent coercive voltage | **Yes** | Temperature compensation in pulse generator, or safe-margin fixed pulses | Low |

**The only genuinely hard problem** is analogue multi-level precision from a single FeFET device (3–4 bits currently vs 8 bits needed). This is a physics constraint. The hybrid architecture sidesteps it: FeFET provides coarse non-volatile checkpointing; Cw provides precision during operation.

**Scenario where this is hardest**: an inference-only chip where weights are programmed at manufacture and must hold 8-bit precision for 10 years at 85°C with no online learning to re-correct drift. The PCN chip — which learns continuously — does not need to meet this requirement.

**The PCN architecture's self-correcting Hebbian rule is a key mitigating factor** that pure digital networks don't have: even if individual weights drift slightly during retention or are restored with 4-bit precision, the learning rule continuously corrects toward the error-minimising state. A digital CNN with fixed weights has no such recovery mechanism.

---

## Summary

FeFET is a real solution to a real problem, commercially available at GF 22FDX-FE, and robustly applicable to the PCN architecture **if** the hybrid two-tier approach is used:

- Binary/coarse FeFET for non-volatile weight persistence across power cycles: **ROBUST**
- Analogue Cw (MIM cap at 7nm) + SRAM for precision online learning: **ACHIEVABLE, already architected**
- 8-bit precision from a single FeFET alone: **NOT YET RELIABLE** — research phase

The physics of non-volatile ferroelectric storage is solid and well-demonstrated. The engineering challenges (endurance, precision, calibration) are significant but tractable with the hybrid architecture. The main risk is process maturity at the analogue level — fewer published analogue design examples at GF 22FDX-FE than at TSMC 28nm, so more characterisation work would be needed before tape-out.

---

## Alternatives to FeFET

### PCM — Phase Change Memory

Stores state as the resistance of a chalcogenide alloy (typically Ge₂Sb₂Te₅), switched between amorphous (high resistance) and crystalline (low resistance) phases by Joule heating. Currently the best multi-level NVM technology available: IBM has demonstrated 3–4 reliable bits per cell, and endurance is 10⁶–10⁹ cycles — significantly better than FeFET. The precision advantage comes from partial crystallisation giving intermediate resistance values that are more controllable than ferroelectric domain switching.

Downsides: write energy is high (~pJ per write — you need to locally heat the material to ~700°C); the amorphous state degrades above ~150°C, so elevated junction temperature in a data centre erodes retention. IBM Research uses PCM in their analogue in-memory computing demos; it is the most mature option for analogue NVM neural networks. For the PCN chip the write energy is a concern — the Hebbian pulse is a small current and would need buffering or a separate write amplifier.

### RRAM — Resistive RAM / Memristor

Stores state as the resistance of a metal-oxide film (HfOx, TaOx) by forming or dissolving a conductive filament. Cell area is tiny — crossbar arrays achieve 4F² per cell, smaller than any transistor-based approach. Endurance varies widely: HfOx achieves 10⁴–10⁵ cycles; TaOx can reach 10⁹. TSMC offers RRAM as a back-end option at some nodes, making it the most accessible option for a foundry-standard flow.

The problem for the PCN is precision. Filament formation is stochastic at the atomic level — the filament diameter varies randomly, giving high cycle-to-cycle resistance variation. Reliably achieving 3 bits per cell in a real circuit (not just statistical measurement) requires calibration overhead.

### MRAM — Magnetic RAM

Stores state in the magnetisation direction of a magnetic tunnel junction (MTJ). The free magnetic layer sits parallel or antiparallel to a reference layer, giving two resistance states. Endurance is essentially unlimited (10¹² cycles), write energy is very low (~50 fJ/bit), and TSMC 22nm eMRAM and GF 22nm eMRAM are both production technologies — the most mature embedded NVM available.

The issue for the PCN is that MRAM is inherently binary. Multi-level MRAM requires multiple magnetic layers with very tight control and remains research-level. For the PCN you would need 8 MRAM cells per weight plus a local DAC — effectively digital weight storage that happens to be non-volatile. This works but adds significant area and loses the "weight is a voltage" property of the current design. MRAM is the right answer if you are willing to commit to fully digital weights with per-cell DACs.

### Embedded Flash / SONOS

Charge stored on a floating gate or charge-trap layer. Very well understood, used in MCUs for decades. High precision is achievable (8+ bits with careful analogue programming). Problems: low endurance (10³–10⁵ program/erase cycles), high programming voltage (10–15V charge pump required), and poor foundry support below 28nm — embedded Flash integration becomes very difficult at smaller nodes because the thin tunnel oxides interfere with the same ALD processes used for transistors. With the PCN committing at ~5 writes/second, 10³ cycles means Flash cells last only 200 seconds. Endurance is a hard constraint.

### Comparison

| Technology | Bits/cell (reliable) | Endurance | Retention | CMOS integration | Write energy |
|------------|---------------------|-----------|-----------|-----------------|--------------|
| FeFET (HZO) | 3–4 | 10⁶–10⁹ | Years (binary), hours–days (analogue) | GF 22FDX-FE | Very low (~fJ) |
| PCM (GST) | 3–4 | 10⁶–10⁹ | Years; degrades >150°C | BEOL, several foundries | High (~pJ) |
| RRAM (HfOx) | 2–3 | 10⁴–10⁹ | Variable | BEOL TSMC option | Medium |
| MRAM (STT) | 1 (binary) | >10¹² | 10+ years | TSMC/GF 22nm production | Very low |
| eFlash | 6–8 | 10³–10⁵ | 10+ years | >28nm only | High (charge pump) |

PCM is the strongest alternative to FeFET for analogue multi-level storage: similar precision and endurance but more controlled intermediate states. The higher write energy is manageable if committing infrequently. MRAM is the right choice if the design moves to fully digital weights. RRAM is attractive for density in a crossbar configuration (see below).

### In-memory crossbar (radical alternative)

Rather than the OTA-based MAC cell, replace the whole structure with an RRAM or PCM crossbar array where weights are resistance values and matrix-vector multiplication happens via Ohm's law and Kirchhoff's current law. IBM's NeuRRAM chip and Mythic's analogue matrix processor use this approach. It achieves very high density and low energy but is a fundamentally different architecture — the 5T OTA MAC cell, self-calibrating Hebbian update, and most of the current design would not transfer. Worth knowing as a direction; it is a fork rather than an extension.

---

## Wafer-Scale Integration

### Why the PCN architecture suits WSI unusually well

Most reasons WSI is difficult for conventional deep learning do not apply here.

**Communication pattern**: Backprop-based networks require global gradient synchronisation — every weight update depends on error signals from the output layer, which must be broadcast backwards across all chips. The PCN's Hebbian updates are purely local — each cell updates its own weight from signals it can observe without any chip-crossing communication. At WSI scale, inter-tile communication is only activation handoff at layer boundaries.

**Power density**: The PCN at 7nm on a 25 mm² die consumes ~50 mW, giving a power density of ~2 mW/mm². Cerebras WSE-3 runs at ~500 mW/mm². A PCN wafer-scale design would have power density 250× lower — cooling is easy, power delivery is simple, and the entire wafer draws only 100–120W.

**Regular array structure**: WSI works well for regular tile-based architectures because failed tiles can be routed around during wafer initialisation. The PCN is a completely regular 16×16 grid — exactly the repeating structure that makes redundancy-based defect tolerance effective.

**Parameter capacity**: At 7nm with 200M effective weights per 25 mm² die, a 300mm wafer gives ~57,000 mm² usable area (≈2,280 chip equivalents) → ~456 billion effective weights at **114W total**. That approaches GPT-4-class parameter count at a power level a standard server power supply handles.

### Intermediate steps before WSI

**Chiplet-based MCM**: 4–16 PCN dies on a silicon interposer with die-to-die interconnect (TSMC CoWoS, TSMC SoIC, or Intel EMIB). Gives 10× parameter scale-up with substantially better inter-die bandwidth than SPI, in a well-understood packaging technology. This is the right step after a validated 28nm single chip.

**3D stacking**: The PCN's layer-by-layer spatial architecture maps naturally to stacked dies — each physical silicon layer implements one or more PCN spatial layers, with through-silicon via (TSV) connections between them. Short vertical connections rather than long horizontal wires.

---

## Strategic direction: scale by size, not geometry

### The asymmetry in geometry scaling

Digital compute benefits dramatically from geometry scaling — billions of switches at femtojoule cost. Analogue compute hits physics walls that do not exist for digital: reduced headroom (lower VDD compresses the differential pair's operating window), worse transistor matching (line-edge roughness dominates at small W), and the capacitor storage problem detailed above. The entire FeFET/PCM/RRAM discussion is a consequence of pursuing geometry reduction for an analogue architecture.

The PCN's strength — weight computation via analogue gm, zero off-chip bandwidth, local Hebbian learning — is precisely what makes it hard to scale by geometry. The properties that make it powerful are the same properties that resist miniaturisation.

### The alternative: scale by adding silicon

The PCN architecture is locally connected. Each MAC cell interacts only with its spatial neighbours and within its layer. There is no global all-to-all computation. This means the architecture tiles arbitrarily:

- Double the die area → double the cells → double the effective weights
- Add another chip to the chain → linear parameter increase → independent of geometry
- Scale to a whole wafer → parameter count approaches transformer scale at modest power

This is a fundamentally different scaling law from Moore's Law. It does not require process advancement. A 28nm die that is 4× larger gives 4× the parameters at 4× the power — straightforward engineering, no new physics to fight.

**28nm is probably the practical sweet spot** for this reason. It is the deepest node that still uses planar CMOS transistors (not FinFET), which preserves the analogue circuit properties — continuous W sizing, predictable matching, adequate VDD headroom (1.1V is tight but workable for the 5T OTA). Below 28nm, FinFET quantised widths and sub-1V supply fight the analogue design at every step. Above 28nm (40nm, 65nm), cell area is larger but the physics is more forgiving, manufacturing is cheaper, and process maturity is excellent.

### Edge nodes and datacenter brains

The modular, connected topology opens a two-tier system architecture:

**Edge nodes**: Small PCN chips at 28nm or even Sky130A — low power (tens of milliwatts), cheap enough to embed in sensors, cameras, or IoT devices. They learn local patterns from their immediate environment via Hebbian adaptation. The chip is self-contained: no host processor required for inference, no cloud connection needed for learning.

**Datacenter brains**: Large PCN systems — wafer-scale or large MCM — with billions of effective weights, trained on aggregated patterns from many edge nodes. The dynamic routing mechanism (routing weights) means the datacenter system can self-organise its topology to reflect the structure of the inputs it receives.

The connection between them is not backprop — it is activation passing through the existing SPI/chain interface. Edge nodes forward compressed representations upward; the datacenter returns top-down predictions downward. This is architecturally identical to the predictive coding hierarchy already implemented in the chip, extended across a physical network. The biological analogy is exact: the retina and peripheral nervous system (edge) feeding the visual cortex and prefrontal cortex (datacenter brain), with top-down predictions flowing back.

This is not a theoretical possibility — it is a direct extension of the multi-chip chain already designed. The routing weight mechanism (§6 of the paper) already provides the topology self-organisation needed for the inter-tier connections to adapt.

### Commercialisation paths

The proof-of-concept nature of the Sky130A chip is an asset rather than a limitation here. It demonstrates the principle on accessible open silicon. The architecture can then be positioned to:

**Cerebras**: Their WSE-3 runs backprop — which requires a global error broadcast across the wafer. This is the hard part of their design: managing the dataflow of gradient signals across 46,000 mm² of silicon. The PCN's Hebbian rule eliminates this entirely — each cell updates locally. A PCN wafer-scale design would be simpler to implement at wafer scale than Cerebras's current architecture, not harder. The pitch: same wafer-scale ambition, but the learning rule is architecturally compatible with the physical substrate in a way backprop is not.

**TSMC**: TSMC has a design centre and offers IP licensing. A validated PCN cell layout at 28HPC+ could be licensed as a hard macro for customers wanting analogue in-memory compute. TSMC is also motivated to find workloads that use large areas of proven nodes (28nm, 40nm are high-volume, high-margin fabs) rather than requiring their most advanced process.

**Samsung**: Samsung Foundry has both process and its own AI chip program. The PCN architecture's compatibility with MRAM (for digital weights at 22nm eMRAM) and with FeFET-style work being done in their research division makes it a natural conversation.

The positioning in each case is the same: **connected modularity with local learning, where scale comes from silicon area rather than geometry reduction**. This is a genuinely different scaling proposition from everything else in the AI hardware space, which is uniformly chasing smaller nodes. The PCN turns that on its head — get more parameters by building bigger, not smaller.

---

## Summary

FeFET is a real solution to a real problem, commercially available at GF 22FDX-FE, and robustly applicable to the PCN architecture **if** the hybrid two-tier approach is used:

- Binary/coarse FeFET for non-volatile weight persistence across power cycles: **ROBUST**
- Analogue Cw (MIM cap at 7nm) + SRAM for precision online learning: **ACHIEVABLE, already architected**
- 8-bit precision from a single FeFET alone: **NOT YET RELIABLE** — research phase

PCM is the strongest alternative to FeFET; MRAM is the right choice if the design moves to digital weights. The deeper strategic question is whether geometry scaling is the right direction at all for an analogue architecture. The PCN's modular, locally-connected structure makes it unusually well-suited to area scaling — larger dies, chiplet MCMs, and eventually wafer-scale — rather than geometry reduction. This reframes the commercialisation opportunity: not "we need 7nm to compete" but "we scale by building bigger, which is cheaper, more manufacturable, and avoids the analogue physics problems entirely."

The physics of non-volatile ferroelectric storage is solid and well-demonstrated. The engineering challenges (endurance, precision, calibration) are significant but tractable with the hybrid architecture. The main risk is process maturity at the analogue level — fewer published analogue design examples at GF 22FDX-FE than at TSMC 28nm, so more characterisation work would be needed before tape-out.

---

## Optical Computing and Photonic Approaches

Optical technology intersects the PCN at three distinct levels, only the first of which is about connections.

### Level 1: Optical interconnects

Silicon photonics — optical waveguides, modulators, and photodetectors in a CMOS-compatible back-end process — is production-ready for chip-to-chip data links. The PCN's current inter-chip traffic (a few kilobits of activation data per inference step over SPI) does not justify optical interconnects at present. They become relevant at large multi-chip scales for one specific reason: **wavelength-division multiplexing (WDM)**. A single waveguide can carry many simultaneous data streams at different wavelengths. If each element of a 256-element activation vector is placed on a separate wavelength, the entire vector can be broadcast from one chip to many recipients simultaneously through a single waveguide, replacing the current serial chain topology with a broadcast topology. This is architecturally significant at thousands of chips; it is unnecessary at current scale.

### Level 2: Optical matrix-vector multiplication

The core neural network operation y = Wx can be implemented optically using a Mach-Zehnder interferometer (MZI) mesh — a grid of optical beam splitters with programmable phase shifts. The phase settings implement the matrix weights; light propagates through the mesh and the output intensities encode the result. The "multiply-accumulate" happens at the speed of light propagation through the waveguide, with no transistor switching, no clock, and extremely low energy per operation for large matrices.

LightMatter's Mars chip is a commercial example; research demonstrations have reached 64×64 matrices. The fundamental constraints are:

- Pure MZI meshes implement only *unitary* matrices (norm-preserving). Arbitrary weight matrices require a singular-value decomposition into three stages (U, Σ, V†), adding hardware and loss.
- Photons do not interact with each other in linear media. Nonlinear activations (ReLU, sigmoid) cannot be done optically with practical efficiency — they must be computed electronically. Photonic neural networks are therefore optoelectronic hybrids: optical linear algebra, electronic nonlinearity.
- The energy advantage over electronic MAC only materialises at large N (>100–1000 inputs per layer). At the PCN's current 16×16=256-element scale, the laser + modulator + detector overhead dominates. At 28nm multi-chip scale with thousands of cells per effective layer, the crossover occurs.

A related concept is **diffractive deep neural networks (D²NN)**: physical diffraction gratings or spatial light modulators that implement a fixed linear transformation via wave interference. Once fabricated, inference is entirely passive — light passes through at c, zero electrical energy for computation. The trade-off is that weights are baked into the physical structure; retraining requires manufacturing new optics. This is complementary rather than competing with the PCN's continuous Hebbian adaptation.

### Level 3: Optical weight storage (photonic PCM)

The most surprising intersection with the PCN's scaling problem. The Oxford/IBM photonic in-memory computing work integrates GST phase-change material (the same chalcogenide used in electronic PCM) directly into silicon photonic waveguides. The GST cell sits in the evanescent field of the waveguide; its optical transmission changes by orders of magnitude between amorphous and crystalline phases. Weights are programmed by laser pulses (precise local heating to switch the GST state) and read by a lower-power probe beam.

This addresses the weight storage problem from an entirely different angle: **the weight is in a BEOL optical layer, not in the transistor gate stack**. Gate oxide tunnelling leakage — the problem that drives the entire FeFET discussion — simply does not apply. The GST state is crystallographic and has no leakage mechanism; it is geometry-independent and adds no constraints to transistor scaling. Optical PCM write endurance is also higher than electronic PCM because laser heating is more spatially controlled than resistive Joule heating, reducing fatigue per cycle.

For the PCN hybrid architecture, optical PCM maps cleanly onto the two-tier model: fast Hebbian updates run on the analogue Cw capacitor and SRAM; periodic commits go to the optical PCM layer. The optical write/read path is separate from the analogue signal path and does not interfere with MAC operation. This is a 5–10 year horizon technology — currently demonstrated in research but not integrated into a commercial foundry PDK — but it represents a path that sidesteps the FeFET precision and endurance problems entirely.

### Optical reservoir computing as PCN front-end

Optical reservoir computing uses a passive optical medium (typically a nonlinear delay-line cavity with a single optical modulator providing the nonlinearity) as a fixed random recurrent network. Because the reservoir is not trained — only the linear readout layer is — the architecture suits optics well: the reservoir's fixed weights are implemented by the physical structure, and the training problem reduces to a simple linear regression on the reservoir states.

Optical reservoirs can process signals at GHz–THz bandwidths far exceeding what analogue silicon circuits can handle. They are a natural front-end for the PCN in RF, radar, communications, and broadband sensor applications: the optical reservoir extracts temporal features from wideband signals at optical speed; the PCN chip learns the mapping from those features to predictions via Hebbian adaptation. This is architecturally clean because the boundary is well-defined — the optical reservoir produces a fixed-dimensional feature vector, which the PCN processes as a standard activation input.

### Maturity assessment

| Optical approach | Status | Relevance to PCN |
|---|---|---|
| Chip-to-chip optical links | Production (data centres) | Useful at large multi-chip scale; WDM activation broadcast |
| MZI photonic MVM | Early commercial (LightMatter) | Competitive at N>1000 cells/layer; overkill at current scale |
| Diffractive D²NN | Research demonstrations | Fixed-weight inference only; complementary to Hebbian PCN |
| Optical PCM weight storage | Research (Oxford/IBM) | Directly solves sub-7nm leakage; 5–10 year horizon |
| Optical reservoir + PCN | Theoretically sound | Broadband signal front-end; enables RF/radar/comms applications |

The short summary: optics is most immediately useful as interconnect infrastructure for large-scale PCN arrays; most potentially transformative as optical PCM weight storage, which eliminates the gate-oxide leakage constraint by moving weight persistence to a geometry-independent BEOL layer; and most immediately actionable as a reservoir computing front-end for applications requiring signal bandwidths beyond silicon analogue reach.

---

*See also:*
- *§73 of pred_code_networks.md — foundry scaling numbers (cell area, parameter capacity, TOPS/W)*
- *§ Weight Storage Below 28nm in main_v2.tex — MOS tunnelling equation, MIM cap Hebbian precision constraint, FeFET overview*
- *quickstart.md — chip integration and register map*

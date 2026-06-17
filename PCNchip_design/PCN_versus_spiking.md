# Predictive Coding Networks versus Spiking Neural Networks: Separating Communication from Computation

*Draft note: written as a standalone analysis for potential inclusion in the main paper pending external feedback.*

---

## Abstract

Spiking neural networks (SNNs) dominate neuromorphic hardware research, motivated by their claimed biological fidelity. We argue that this conflates two orthogonal questions: *what computation the brain performs* and *how that computation is communicated between neurons*. Spiking is a solution to a biological communication constraint — reliable signal transmission over long, noisy axons — not a defining feature of the brain's computational algorithm. Predictive coding networks (PCNs) address the computational question directly. In silicon, where the communication constraint does not apply, an analog continuous-valued MAC cell implements the PCN computation more efficiently than a spiking equivalent, while remaining agnostic to the communication protocol at its boundaries. The spike encoder/decoder is a separable, interchangeable boundary component, not a property of the prediction engine itself.

---

## 1. Why Biological Neurons Spike

The action potential — the canonical neural spike — is a stereotyped all-or-nothing voltage pulse, approximately 100mV in amplitude and 1ms in duration. Information is not encoded in the spike's shape (it is invariant) but in its timing and rate of occurrence.

The biophysical reason for this is a wire problem. Cortical axons range from 0.1µm to 20µm in diameter and can exceed 1 metre in length (corticospinal tract). Passive analog signal propagation over a resistive, capacitive biological cable of this length causes exponential attenuation and severe low-pass filtering — a continuous voltage signal would be unrecognisable at the far end. The action potential solves this by being actively regenerated at each node of Ranvier: voltage-gated sodium channels sense the approaching depolarisation and re-fire a full-amplitude pulse. The spike is, in engineering terms, a **regenerative digital repeater** distributed along the axon.

Spike timing and rate encode the information because those properties survive the regeneration process — amplitude does not.

This is a physical constraint of wet biology. It is not a constraint of silicon.

---

## 2. What Predictive Coding Computes

Predictive coding [1, 2] is a theory of *what* the cortex computes, independent of *how* that computation is communicated. In its canonical form, each layer of the hierarchy maintains a generative model of its input. The layer's output is not the raw signal but the **prediction error** — the residual after subtracting the top-down prediction from the bottom-up input. Only errors propagate upward; the top-down predictions propagate downward.

This framework accounts for a wide range of cortical phenomena: end-stopping, extra-classical receptive field suppression, repetition suppression, and the asymmetry between feedforward and feedback connections. Its appeal is as a normative account of hierarchical inference under a generative model, formalised as free-energy minimisation [3].

Crucially, the predictive coding framework says nothing about whether the residual errors are transmitted as analog voltages, 8-bit codes, or spike trains. The computation — form a prediction, subtract it, pass the error — is defined at the algorithmic level (Marr's level 2), not the implementation level (Marr's level 3) [6].

---

## 3. The Conflation in SNN Research

Much neuromorphic SNN work [9] is motivated by the observation that biological neurons spike, and therefore silicon neurons should spike too. This is an implementation-level argument: replicate the mechanism observed in biology.

The result is a large body of work on spike-timing-dependent plasticity (STDP) [7, 8], leaky integrate-and-fire (LIF) circuits, and rate-coded spike trains — all of which replicate the *communication protocol* of biological neurons with considerable fidelity. What is less often addressed is whether the underlying *computation* being performed corresponds to any normative algorithmic theory of what the brain does [5].

SNNs performing classification, for example, typically use a rate-coded output read over a fixed time window — which is equivalent to a noisy, slow, discretised version of a rate-coded analog network. The spikes in this case are neither biologically motivated (no long axons) nor computationally necessary (the rate code could be represented directly as a voltage). They are a carry-over of the biological implementation detail into a substrate where that detail is no longer required.

---

## 4. Reservoir Computing: A Bridge Concept

Reservoir computing [14, 15] is a computational framework widely used to deploy SNN hardware practically, and understanding it clarifies both what the PCN chip does and why GHA represents a specific improvement over the standard approach.

### The basic structure

A reservoir computer consists of a large, randomly connected recurrent network — the reservoir — with fixed, untrained weights, and a small trained linear readout:

```
Input → [fixed random reservoir] → linear readout → output
              (not trained)            (trained)
```

The reservoir projects the input into a high-dimensional nonlinear space. The linear readout then finds the hyperplane that separates classes in that space. Only the readout weights are trained — by simple linear regression, not backpropagation.

An intuitive picture: imagine a bagatelle machine with fixed pegs. Dropping a ball at a given position always produces the same pattern of contacts — the path is fully deterministic. The pattern of pegs hit is far higher-dimensional than the single drop coordinate, and similar inputs produce similar patterns. The readout watches which pegs were activated and learns to associate patterns with classes.

What makes this useful rather than merely complicated is the **echo state property** [14]: the network's internal state is determined entirely by its input history, not by arbitrary initial conditions. The same input always produces the same reservoir state. Because the reservoir is recurrent, its state at any moment also carries a fading memory of recent inputs — making it naturally suited to time-series and sensor data where history matters.

### Why it is popular for SNN hardware

Training a spiking network end-to-end requires differentiating through spike events, which are non-differentiable. Reservoir computing sidesteps this: the spiking network serves as the reservoir (in this context called a liquid state machine [15]), with random fixed weights, and only the linear readout is trained in software. No on-chip learning rule is needed in the reservoir itself. This makes hardware deployment practical — you fabricate the spiking circuit, fix the weights, and train only the readout layer.

### GHA as an optimising reservoir

The functional structure of the PCN chip is closely parallel to reservoir computing:

| Property | Classical reservoir | PCN / GHA chip |
|---|---|---|
| Feature extraction | Fixed random recurrent network | Learned feedforward GHA (principal components) |
| Dimensionality | Random expansion | Structured, variance-maximising expansion |
| Readout | Trained linear layer | Logistic regression on GHA features |
| Training | Readout only | GHA (Hebbian, unsupervised) + linear readout |
| Temporal memory | Built into recurrent connections | None (feedforward only) |

One way to understand GHA in this context is as an **optimising reservoir** — a reservoir that learns its own connections rather than accepting random ones. Where a classical reservoir expands the input into an arbitrary high-dimensional space and hopes that the classes separate, GHA explicitly organises that expansion around the principal axes of variance in the input distribution. The result is a more informative representation per neuron: fewer units are needed to achieve the same linear separability at the readout.

Returning to the bagatelle picture: a classical reservoir is a machine with randomly positioned pegs; GHA repositions those pegs during an unsupervised training phase so that the most important variations in the input produce the most spread-out, separable patterns — a machine tuned to the statistics of the data it will encounter.

### The recurrent connection gap — an area for further study

The substantive architectural difference between the two approaches is the absence of recurrent connections in the current PCN design. The classical reservoir's recurrence provides temporal memory: the network state at time T encodes a fading trace of recent inputs, making it capable of processing sequences without any additional mechanism. The PCN chip as currently designed is feedforward — each inference pass treats its input as a static pattern.

Adding recurrent connections within or between PCN layers would extend the approach to temporal signal processing while retaining the advantage of learned, structured weights over random ones. Whether on-chip recurrence would require modification to the GHA learning rule, and how it would interact with the temporal reuse architecture, are open questions that warrant investigation.

---

## 5. The PCN Chip's Position

The chip described in this paper implements the *computation* of predictive coding — GHA [4] unsupervised Hebbian learning with a deflation step corresponding to the PC residual pathway — in a 5-transistor OTA MAC cell. The computation is:

```
V_out = Σ (w_i × V_in_i)     [weighted sum, analog, instantaneous]
```

followed by a V1 PMOS clamp (ReLU nonlinearity, corresponding to the PC rectified-error unit). Weights are updated by the on-chip Hebbian rule. The output of each layer is an analog voltage representing the activation magnitude — a continuous-valued rate code, readable instantly, with no integration window.

This is a direct analog implementation of the PCN algorithm, with no spike encoding in the signal path. The cell is simpler (5T versus ~20–50T for a LIF neuron), faster (no integration time), and directly composable: the output of one layer feeds the input of the next as a voltage with no conversion.

---

## 6. Spikes as a Separable Boundary Component

Nothing in the PCN MAC cell's interface contract requires the input to be an analog voltage from another PCN cell. The cell requires only that its input pins carry a voltage. Where that voltage comes from — another OTA, an 8-bit DAC, a spike rate decoder, a photodiode — is irrelevant to the prediction computation.

This gives the architecture a natural modularity:

```
[Source domain] ──► [Boundary converter] ──► [PCN tile] ──► [Boundary converter] ──► [Sink domain]
```

The boundary converter is a **separable, swappable component**:

| Interface needed | Converter |
|---|---|
| PCN tile → PCN tile (same chip) | Direct analog wire, no conversion |
| PCN tile → PCN tile (inter-chip) | 8-bit SAR ADC / DAC, or PWM |
| PCN tile → SNN chip | Spike rate encoder (1-bit ADC running over time) |
| SNN chip → PCN tile | Spike rate decoder (integrate-and-hold, DAC) |
| Sensor (photodiode array) → PCN tile | Direct analog coupling, no conversion |
| PCN tile → SRAM | 8-bit SAR ADC |
| SRAM → PCN tile | 8-bit DAC (current steering or resistor string) |

The spike encoder in this framing is the cheapest possible ADC — a 1-bit converter that runs asynchronously over time. It is appropriate at boundaries where noise immunity or SNN ecosystem compatibility is required. It is unnecessary and costly (integration latency, count noise) in the interior of the computation where direct analog links are available.

The ADC/DAC cost that is often cited as the primary obstacle to analog neuromorphic computing is therefore **a boundary cost, not a compute cost**. Designs that force unnecessary domain crossings (e.g., reading out every row of an analog crossbar array with a column ADC at every step) pay this cost repeatedly. The temporal-reuse architecture of this chip amortises it: a single ADC instance converts once per computation pass, not once per cell per step.

---

## 7. Where Spiking Genuinely Wins

This analysis is not an argument that spiking is wrong. There are scenarios where spike encoding is the correct engineering choice:

**Sparse event-driven input**: a silicon retina emits spikes only when pixel intensity changes. Processing these with a spiking network is naturally power-proportional to scene activity. An always-on analog MAC cell draws I_tail regardless of whether there is signal. For a static scene, the spiking approach wins on power by a large margin.

**Very long on-chip or off-chip routing**: if signals must travel across a noisy PCB or through long global routing on a large die, spike encoding provides the same noise immunity that motivated biological axons. An 8-bit analog voltage degrades; a binary pulse does not.

**Temporal sequence processing**: spike timing can encode temporal structure (ISI patterns, phase relationships) that a rate-coded analog network cannot represent without explicit delay lines. Tasks requiring precise temporal discrimination may benefit from native spike-timing representations.

**Compatibility with existing SNN infrastructure**: Intel Loihi [11], IBM TrueNorth [10], and BrainScaleS [12] have established ecosystems. A spike-interface boundary tile on a PCN chip enables interoperability without modifying either system.

---

## 8. The Complementary View: Hybrid Systems

The canonical cortical circuit proposed by Payvand and Indiveri [13] is instructive precisely because it attempts to implement cortical-computation-style processing *using* spiking neurons. This validates the two-dimensional view: the computation (PC-like hierarchical inference) and the communication (spikes) are independently choosable, and research groups are exploring both axes.

The PCN chip occupies the quadrant: **PC computation, analog communication**. A natural extension — attaching spike boundary tiles — would reach **PC computation, spike communication** without modifying the prediction engine. This hybrid is a credible direction for interfacing with the established SNN ecosystem or for deployment in sparse event-driven sensory pipelines.

---

## 9. Summary

| Property | SNN approach | PCN analog approach |
|---|---|---|
| Computational algorithm | Varies (often rate-code approximation of ANN) | Predictive coding / GHA (explicit algorithmic grounding) |
| Communication within chip | Spike trains | Direct analog voltage |
| Communication across boundaries | Native spikes | 8-bit digital or optional spike encoder |
| Neuron circuit complexity | ~20–50T (LIF + reset) | 5T OTA MAC |
| Learning rule | STDP (timing-dependent, can be unstable) | Hebbian GHA (provably convergent) |
| Readout latency | Rate integration window (ms–100ms) | Instantaneous |
| Power model | Event-driven, sparse-proportional | Always-on I_tail; reducible by duty cycling |
| ADC/DAC cost | At every spike encoder/decoder boundary | At domain boundaries only; amortised by temporal reuse |
| Biological motivation | Implementation fidelity (spikes) | Algorithmic fidelity (PC computation) |

The central claim is that the large body of SNN hardware research and the PCN approach are not competing alternatives but answers to different questions. SNNs ask: how do we replicate biological communication in silicon? PCNs ask: how do we implement the brain's computational algorithm in silicon? Both questions are legitimate. Conflating them — assuming that biological communication fidelity entails computational algorithm fidelity — is the error that the field has not yet fully confronted.

The spike encoder is a component you can add at the edge. The prediction is the engine.

---

*Cross-reference: pred_code_networks.md §74–§75 (simulation results); simulations_summary.md §6–§7 (MNIST/EMNIST accuracy); paper/main_v3.tex (on hold pending feedback).*

---

## References

### Predictive Coding Theory

[1] Rao, R. P. N. & Ballard, D. H. (1999). Predictive coding in the visual cortex: a functional interpretation of some extra-classical receptive-field effects. *Nature Neuroscience*, 2(1), 79–87. https://doi.org/10.1038/4580

[2] Friston, K. (2005). A theory of cortical responses. *Philosophical Transactions of the Royal Society B*, 360(1456), 815–836. https://doi.org/10.1098/rstb.2005.1622

[3] Friston, K. (2010). The free-energy principle: a unified brain theory? *Nature Reviews Neuroscience*, 11(2), 127–138. https://doi.org/10.1038/nrn2787

### Unsupervised Hebbian Learning

[4] Sanger, T. D. (1989). Optimal unsupervised learning in a single-layer linear feedforward neural network. *Neural Networks*, 2(6), 459–473. https://doi.org/10.1016/0893-6080(89)90044-0

### Predictive Coding Reviews / Hardware Gap

[5] Millidge, B., Seth, A. & Buckley, C. L. (2022). Predictive coding: a theoretical and experimental review. *arXiv*:2107.12979.

### Levels of Analysis

[6] Marr, D. (1982). *Vision: A Computational Investigation into the Human Representation and Processing of Visual Information*. W. H. Freeman.

### Spike-Timing Dependent Plasticity

[7] Bi, G. Q. & Poo, M. M. (1998). Synaptic modifications in cultured hippocampal neurons: dependence on spike timing, synaptic strength, and postsynaptic cell type. *Journal of Neuroscience*, 18(24), 10464–10472. https://doi.org/10.1523/JNEUROSCI.18-24-10464.1998

[8] Markram, H., Lübke, J., Frotscher, M. & Sakmann, B. (1997). Regulation of synaptic efficacy by coincidence of postsynaptic APs and EPSPs. *Science*, 275(5297), 213–215. https://doi.org/10.1126/science.275.5297.213

### Neuromorphic Hardware Origins

[9] Mead, C. (1990). Neuromorphic electronic systems. *Proceedings of the IEEE*, 78(10), 1629–1636. https://doi.org/10.1109/5.58356

### SNN Hardware Platforms

[10] Merolla, P. A. et al. (2014). A million spiking-neuron integrated circuit with a scalable communication network and interface. *Science*, 345(6197), 668–673. https://doi.org/10.1126/science.1254642

[11] Davies, M. et al. (2018). Loihi: a neuromorphic manycore processor with on-chip learning. *IEEE Micro*, 38(1), 82–99. https://doi.org/10.1109/MM.2018.112130359

[12] Schemmel, J. et al. (2010). A wafer-scale neuromorphic hardware system for large-scale neural modeling. *Proceedings of ISCAS 2010*, 1947–1950. https://doi.org/10.1109/iscas.2010.5536970

### Reservoir Computing

[14] Jaeger, H. (2001). The 'echo state' approach to analysing and training recurrent neural networks. German National Research Center for Information Technology, Tech. Rep. GMD Report 148.

[15] Maass, W., Natschläger, T. & Markram, H. (2002). Real-time computing without stable states: a new framework for neural computation based on perturbations. *Neural Computation*, 14(11), 2531–2560. https://doi.org/10.1162/089976602760407955

### Analog CMOS Predictive Coding / Hybrid Approaches

[13] Maryada et al. [incl. Payvand, M. & Indiveri, G.] (2025). A canonical cortical electronic circuit for neuromorphic intelligence. *bioRxiv*. https://doi.org/10.1101/2025.03.28.646019

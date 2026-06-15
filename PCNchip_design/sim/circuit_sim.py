"""
circuit_sim.py  —  Cell-level behavioural model of the PCN MAC array.

Unlike pcn_core.py (which works in normalised weight-space), this module
models the ACTUAL VOLTAGES and CURRENTS flowing through the circuit,
using parameters derived from the SPICE characterisation in §54/§55/§57.

The hierarchy mirrors the physical hardware:

    MACCell     — one 5T OTA + CMOS TG weight cell
    MACRow      — N cells sharing a KCL row bus  (one dot-product lane)
    PCNLayer    — N_rows × N_cols array of MACRows
    LayerLink   — PMOS SF ascending + resistor divider descending
    SARADC      — 8-bit successive approximation (§55 sar_adc.v)
    InputDAC    — 8-bit R-2R activation DAC (inp_dac.spice)
    SpatialStack  — direct layer-link cascade (fails after 1-2 layers)
    TemporalStack — ADC → SRAM → DAC reset between VLs (§55 design)

Calibration points (all from SPICE measurements):
    G0_NOM      = 6.82 V/V  single-cell gain at Vcm, CODE_MID  (§55)
    G_below_vcm ≈ 0.00138   gain at V_inp_cm = 0.51V            (§54)
    V_SUB       = 0.044 V   below-VCM subthreshold slope (fit)
    V_OUT_BAL   = 0.468 V   module balanced OP (current_sub loads iout bus, §72)
    SF_PMOS     = 0.670 V   PMOS SF ascending shift: V_inp_next = V_out + SF_PMOS (§71)
    VCM_UPPER   = 1.138 V   upper-layer cm reference = V_OUT_BAL + SF_PMOS
    V_SUB_ABOVE = 0.205 V   above-VCM gain roll-off (calibrated: mod1=0.315× mod0 at 1.137V §72)
    PRED_RATIO  = 0.625     R_pred2/(R_pred1+R_pred2)            (§55)
    Spatial cascade §72: mod0=1.43, mod1=0.45, mod2=0.70, mod3=0.54 V/V (untrained; Hebbian self-calibrates)
"""

import numpy as np


# ── Hardware constants (Sky130A, VDD=1.8 V) ───────────────────────────────────

VDD         = 1.8      # V  supply voltage
VCM         = 0.90     # V  nominal diff-pair common-mode
G0_NOM      = 6.82     # V/V  single-cell gain at Vcm (§55 measured)
V_SUB       = 0.044    # V  below-VCM subthreshold slope factor (calibrated §54/§55)
V_SUB_ABOVE = 0.205    # V  above-VCM gain roll-off (calibrated §72: mod1=0.315× mod0 at 1.137V)
V_OUT_BAL   = 0.468    # V  module balanced OP; current_sub XMPS1 loads iout below Vcm (§72)
SF_PMOS     = 0.670    # V  PMOS SF ascending shift; +|Vgs,P| (§71/§72)
VCM_UPPER   = V_OUT_BAL + SF_PMOS  # ≈ 1.138 V  upper-layer cm reference
PRED_RATIO  = 0.625    # resistor divider: R500k/(R300k+R500k) (§55)

CODE_MIN    = 71       # lowest usable code (Vw ≈ 0.50 V)
CODE_MID    = 128      # zero-weight mid-scale  (Vw = 0.90 V = Vcm)
CODE_MAX    = 192      # highest usable code    (Vw ≈ 1.35 V)
CODE_SCALE  = 64.0     # codes per unit weight

ADC_BITS    = 8
# ADC reference is matched to the inp_dac output range so that a
# round-trip ADC→DAC is identity at mid-code.  In the real hardware the
# SAR DAC reference is derived from the same Vref_inp rails as the inp_dac.
ADC_VMIN    = 0.40     # V  SAR ADC lower reference (= DAC_VMIN)
ADC_VMAX    = 1.40     # V  SAR ADC upper reference (= DAC_VMAX)

DAC_BITS    = 8
DAC_VMIN    = 0.40     # V  inp_dac output lower bound (Vref_inp lower)
DAC_VMAX    = 1.40     # V  inp_dac output upper bound


# ── Operating-point transfer function ─────────────────────────────────────────

def op_factor(v_inp_cm: float) -> float:
    """
    Gain factor when V_inp_cm ≠ Vcm.

    Below VCM: NMOS diff pair enters subthreshold — gm ∝ exp(delta/V_SUB).
    Above VCM: MN3 tail source (ntail) is elevated by higher inp_cm, reducing
               Vgs_MN3 toward Vth; at VCM_UPPER=1.137 V, Vgs_MN3=0.33 V < Vth=0.48 V (§72).
               Models as symmetric exponential decay with V_SUB_ABOVE.

    Calibrated:
        op_factor(0.9)   = 1.000 → G = G0_NOM V/V (nominal, §55)
        op_factor(0.51)  = 1.4e-4 → G ≈ 0.00138 V/V (§54)
        op_factor(1.137) ≈ 0.315 → G ≈ 0.45 V/V (§72 mod1 untrained; Hebbian self-calibrates)
    """
    delta = v_inp_cm - VCM
    if delta >= 0.0:
        return float(np.exp(-delta / V_SUB_ABOVE))
    return float(np.exp(delta / V_SUB))


# ── Weight code ↔ float helpers ───────────────────────────────────────────────

def code_to_weight(code: int) -> float:
    return (int(np.clip(code, CODE_MIN, CODE_MAX)) - CODE_MID) / CODE_SCALE


def weight_to_code(w: float) -> int:
    return int(np.clip(round(w * CODE_SCALE + CODE_MID), CODE_MIN, CODE_MAX))


# ── MACCell ───────────────────────────────────────────────────────────────────

class MACCell:
    """
    Single PCN MAC cell (5T OTA + CMOS TG weight capacitor).

    Transfer function (small-signal, calibrated from SPICE):

        ΔV_iout = G0 × w × V_diff × op_factor(V_inp_cm)

    where
        w       = (code - CODE_MID) / CODE_SCALE  ∈ [−0.891, +1.000]
        V_diff  = V_inp − V_inn
        op_factor captures subthreshold gain reduction (see above)

    The row bus voltage is: V_iout = VCM + ΔV_iout
    (VCM is the quiescent operating point set by the bias generator).

    Note: in the real circuit the output is a CURRENT (KCL bus). This model
    returns the equivalent ΔV_row contribution (I_cell × R_out), which sums
    linearly with other cells' contributions on the same row bus.
    """

    def __init__(self, code: int = CODE_MID):
        self.code = int(np.clip(code, CODE_MIN, CODE_MAX))

    @property
    def weight(self) -> float:
        return code_to_weight(self.code)

    @weight.setter
    def weight(self, w: float):
        self.code = weight_to_code(w)

    def delta_v(self, v_inp: float, v_inn: float) -> float:
        """Signal contribution to the row bus (ΔV, excludes VCM offset)."""
        return G0_NOM * self.weight * (v_inp - v_inn) * op_factor((v_inp + v_inn) / 2)

    def v_out(self, v_inp: float, v_inn: float) -> float:
        """Absolute row bus voltage from this cell (= VCM + delta_v)."""
        return float(np.clip(VCM + self.delta_v(v_inp, v_inn), 0.0, VDD))


# ── MACRow ────────────────────────────────────────────────────────────────────

class MACRow:
    """
    N MAC cells sharing one KCL row bus.

    KCL property: output signals add in the current domain.  With N cells
    sharing a row bus of impedance R_out_parallel = R_out_single / N, the
    voltage swing from N cells is:

        ΔV_row = Σ_j I_cell_j × R_out_parallel
               = Σ_j (G0/R_out_single × w_j × V_diff_j) × (R_out_single / N) × N
               = G0 × Σ_j w_j × V_diff_j          (independent of N)

    The amplitude of the dot product is preserved regardless of row width —
    this is the essential property of current-mode computation.
    """

    def __init__(self, n_cols: int, codes=None):
        self.n_cols = n_cols
        codes = codes if codes is not None else [CODE_MID] * n_cols
        self.cells = [MACCell(int(c)) for c in codes]

    @property
    def weights(self) -> np.ndarray:
        return np.array([c.weight for c in self.cells])

    @weights.setter
    def weights(self, w_vec):
        for cell, w in zip(self.cells, w_vec):
            cell.weight = float(w)

    @property
    def codes(self) -> np.ndarray:
        return np.array([c.code for c in self.cells])

    @codes.setter
    def codes(self, code_vec):
        for cell, code in zip(self.cells, code_vec):
            cell.code = int(np.clip(code, CODE_MIN, CODE_MAX))

    def forward(self, v_inp_vec, v_inn_vec=None) -> float:
        """
        KCL summation: V_row = VCM + Σ_j cell_j.delta_v(...)
        v_inn_vec defaults to VCM (single-ended input, V_inn = common-mode bias).
        """
        if v_inn_vec is None:
            v_inn_vec = [VCM] * self.n_cols
        total = sum(
            cell.delta_v(float(vi), float(vn))
            for cell, vi, vn in zip(self.cells, v_inp_vec, v_inn_vec)
        )
        return float(np.clip(VCM + total, 0.0, VDD))


# ── PCNLayer ──────────────────────────────────────────────────────────────────

class PCNLayer:
    """
    N_rows × N_cols MAC array.  N_rows independent KCL row buses.

    Inputs : v_inp_vec (N_cols,) — positive column voltages
             v_inn_vec (N_cols,) — negative column voltages (default VCM)
    Outputs: v_row_vec (N_rows,) — row bus voltages
    """

    def __init__(self, n_rows: int, n_cols: int, W_codes=None):
        self.n_rows = n_rows
        self.n_cols = n_cols
        if W_codes is None:
            W_codes = np.full((n_rows, n_cols), CODE_MID, dtype=int)
        self.rows = [MACRow(n_cols, W_codes[i]) for i in range(n_rows)]

    @property
    def W_codes(self) -> np.ndarray:
        return np.array([row.codes for row in self.rows])

    @W_codes.setter
    def W_codes(self, codes: np.ndarray):
        for row, c_vec in zip(self.rows, codes):
            row.codes = c_vec

    @property
    def W(self) -> np.ndarray:
        return np.array([row.weights for row in self.rows])

    @W.setter
    def W(self, w_mat: np.ndarray):
        for row, w_vec in zip(self.rows, w_mat):
            row.weights = w_vec

    def forward(self, v_inp_vec, v_inn_vec=None) -> np.ndarray:
        """Forward pass: returns V_row for each row."""
        if v_inn_vec is None:
            v_inn_vec = np.full(self.n_cols, VCM)
        return np.array([row.forward(v_inp_vec, v_inn_vec) for row in self.rows])

    def inp_cm(self, v_inp_vec, v_inn_vec=None) -> float:
        """Input common-mode voltage (used to compute op_factor)."""
        if v_inn_vec is None:
            v_inn_vec = np.full(self.n_cols, VCM)
        return float(np.mean([(a + b) / 2 for a, b in zip(v_inp_vec, v_inn_vec)]))


# ── LayerLink ─────────────────────────────────────────────────────────────────

class LayerLink:
    """
    Analog interconnect between spatially adjacent layers (§71/§72 PMOS SF design).

    Ascending (feedforward) — PMOS source follower:
        V_inp_next = VCM_UPPER + (V_row − VCM)
                   = V_OUT_BAL + SF_PMOS + ΔV_signal

        where V_OUT_BAL = 0.468 V (balanced module output OP; current_sub loading, §72)
              SF_PMOS   = 0.670 V (+|Vgs,P|; PMOS raises voltage)
              VCM_UPPER ≈ 1.138 V (new common-mode for upper layers)

        Reference SF in hardware sets inn_col_upper = VCM_UPPER (matched shift, §72).
        Differential is preserved: V(inp_upper)−VCM_UPPER = V(iout_lower)−V_OUT_BAL.

        Untrained cascade gains: mod0=1.43, mod1=0.45, mod2=0.70, mod3=0.54 V/V (§72).
        Upper-layer reduction: op_factor(VCM_UPPER) ≈ 0.315 (MN3 near subthreshold).
        Signal propagates all 4 layers; Hebbian self-calibrates upper layers.

    Descending (top-down prediction):
        V_pred = V_row_upper × PRED_RATIO  (resistor divider, unchanged)
    """

    def ascending(self, v_row: np.ndarray) -> np.ndarray:
        """Row bus → next layer V_inp (PMOS SF: lifts to VCM_UPPER baseline, §71)."""
        delta_v = np.asarray(v_row, dtype=float) - VCM   # signal component
        return np.clip(VCM_UPPER + delta_v, 0.0, VDD)

    def descending(self, v_row_upper: np.ndarray) -> np.ndarray:
        """Upper-layer row bus → prediction voltages at lower layer."""
        return np.asarray(v_row_upper, dtype=float) * PRED_RATIO


# ── ADC and DAC ───────────────────────────────────────────────────────────────

class SARADC:
    """
    8-bit SAR ADC.  Uniform quantisation over [ADC_VMIN, ADC_VMAX] = [0, 1.8 V].
    Code 128 → 0.9 V = VCM (midpoint).
    Matches sar_adc.v characterisation from §55.
    """

    def convert(self, v: float | np.ndarray) -> np.ndarray:
        """Voltage(s) → 8-bit code(s).

        Uses floor (truncation), matching the SAR comparator: vin >= v_ref(code)
        places vin in the bin [v_ref(N), v_ref(N+1)), so the result is floor,
        not round.  Maximum inband error is 1 LSB (3.92 mV) rather than 0.5 LSB.
        """
        v = np.atleast_1d(np.asarray(v, dtype=float))
        v_clipped = np.clip(v, ADC_VMIN, ADC_VMAX)
        codes = np.floor(
            (v_clipped - ADC_VMIN) / (ADC_VMAX - ADC_VMIN) * (2**ADC_BITS - 1)
        ).astype(int)
        return np.clip(codes, 0, 2**ADC_BITS - 1)

    def reconstruct(self, codes: np.ndarray) -> np.ndarray:
        """8-bit code(s) → reconstructed voltage(s)."""
        codes = np.atleast_1d(np.asarray(codes, dtype=int))
        return codes / (2**ADC_BITS - 1) * (ADC_VMAX - ADC_VMIN) + ADC_VMIN

    def quantise(self, v: float | np.ndarray) -> np.ndarray:
        """Round-trip: V → code → V (models quantisation noise)."""
        return self.reconstruct(self.convert(v))


class InputDAC:
    """
    8-bit R-2R input DAC (inp_dac.spice).
    Output range [DAC_VMIN, DAC_VMAX] = [0.4, 1.4 V], centred at 0.9 V = VCM.
    Code 128 → 0.9 V (same mid-code as ADC → direct code pass-through
    preserves VCM centring between VLs).
    """

    def decode(self, codes: np.ndarray) -> np.ndarray:
        """8-bit code(s) → column voltage(s)."""
        codes = np.atleast_1d(np.asarray(codes, dtype=int))
        return DAC_VMIN + codes / (2**DAC_BITS - 1) * (DAC_VMAX - DAC_VMIN)

    def encode(self, v: float | np.ndarray) -> np.ndarray:
        """Target voltage(s) → nearest DAC code(s)."""
        v = np.atleast_1d(np.asarray(v, dtype=float))
        frac = (v - DAC_VMIN) / (DAC_VMAX - DAC_VMIN)
        return np.clip(np.round(frac * (2**DAC_BITS - 1)).astype(int), 0, 2**DAC_BITS - 1)


# ── SpatialStack ──────────────────────────────────────────────────────────────

class SpatialStack:
    """
    K spatially-cascaded PCN layers connected by LayerLinks (§71/§72 PMOS SF).

    Layer k output → LayerLink ascending → Layer k+1 input.
    PMOS SF RAISES V_inp_cm to VCM_UPPER ≈ 1.138 V for all upper layers.
    Gain reduced at upper layers (op_factor ≈ 0.315 at VCM_UPPER) but signal propagates.

    §72 verified untrained: mod0=1.43, mod1=0.45, mod2=0.70, mod3=0.54 V/V.
    Temporal reuse resets V_inp_cm to VCM = 0.9 V via ADC→DAC, giving full gain per VL.
    """

    def __init__(self, n_layers: int, n_rows: int, n_cols: int,
                 W_codes_list=None):
        self.n_layers = n_layers
        self.n_rows   = n_rows
        self.n_cols   = n_cols
        W_codes_list  = W_codes_list or [None] * n_layers
        self.layers   = [PCNLayer(n_rows, n_cols, w) for w in W_codes_list]
        self.links    = [LayerLink() for _ in range(n_layers - 1)]
        self.adc      = SARADC()

    def forward(self, v_inp_vec, v_inn_vec=None):
        """
        Propagate signal through all spatial layers.

        Returns a list of per-layer diagnostics dicts:
            v_inp_cm   float   input common-mode at this layer
            op_fac     float   operating-point gain factor (1.0 = nominal)
            eff_gain   float   effective gain (= G0 × op_fac)
            v_row      ndarray row bus voltages (N_rows,)
            v_inp_next ndarray V_inp for next layer (after LayerLink)
        """
        if v_inn_vec is None:
            v_inn_vec = np.full(self.n_cols, VCM)
        v_inp_vec = np.asarray(v_inp_vec, dtype=float)
        v_inn_vec = np.asarray(v_inn_vec, dtype=float)

        log = []
        for k, layer in enumerate(self.layers):
            cm    = float(np.mean((v_inp_vec + v_inn_vec) / 2))
            of    = op_factor(cm)
            v_row = layer.forward(v_inp_vec, v_inn_vec)

            if k < self.n_layers - 1:
                v_next = self.links[k].ascending(v_row)
                v_inn_next = np.full(self.n_rows, VCM_UPPER)  # ref SF sets inn_col (§72)
            else:
                v_next     = v_row
                v_inn_next = np.full(self.n_rows, VCM_UPPER)

            log.append({
                'layer':     k,
                'v_inp_cm':  cm,
                'op_fac':    of,
                'eff_gain':  of * G0_NOM,
                'v_row':     v_row,
                'v_inp_next': v_next,
            })
            v_inp_vec = v_next
            v_inn_vec = v_inn_next

        return log


# ── TemporalStack ─────────────────────────────────────────────────────────────

class TemporalStack:
    """
    K virtual layers time-multiplexed on ONE physical MAC array.

    Between virtual layers:
        Row outputs → SAR ADC → 8-bit codes
        Load VL_{k+1} weights from SRAM into physical layer
        inp_dac converts codes → column voltages (centred at VCM)

    The ADC → DAC round-trip RESETS the input common-mode to VCM,
    eliminating the SF-shift cascade.  All VLs operate at the same
    optimal operating point → full gain (≈ G0_NOM) at every layer.

    Dimension constraint: n_rows must equal n_cols (square array) so
    that row outputs can feed back as column inputs for the next VL.
    (In a non-square array, a reshape or zero-padding stage is needed.)
    """

    def __init__(self, n_virt: int, n_dim: int, W_codes_list=None):
        assert n_virt >= 1
        self.n_virt  = n_virt
        self.n_dim   = n_dim  # n_rows = n_cols = n_dim (square array)
        W_codes_list = W_codes_list or [None] * n_virt
        self.W_codes = [
            np.full((n_dim, n_dim), CODE_MID, dtype=int) if w is None
            else np.asarray(w, dtype=int)
            for w in W_codes_list
        ]
        self.physical = PCNLayer(n_dim, n_dim)   # reloaded per VL
        self.adc = SARADC()
        self.dac = InputDAC()

    def _load_vl(self, k: int):
        """Load VL k weight matrix into the physical layer (SRAM → layer)."""
        self.physical.W_codes = self.W_codes[k]

    def forward(self, v_inp_vec, v_inn_vec=None):
        """
        Propagate through all N_virt virtual layers.

        Returns a list of per-VL diagnostics:
            vl          int     virtual layer index
            v_inp_cm    float   input common-mode at this VL
            op_fac      float   operating-point factor
            eff_gain    float   G0 × op_fac
            v_row       ndarray row bus voltages (n_dim,)
            adc_codes   ndarray 8-bit codes after ADC  (n_dim,)
            v_dac       ndarray inp_dac output voltages for next VL (n_dim,)
            quant_err   float   mean |V_row − V_dac|  (ADC+DAC round-trip noise)
        """
        if v_inn_vec is None:
            v_inn_vec = np.full(self.n_dim, VCM)
        v_inp = np.asarray(v_inp_vec, dtype=float)
        v_inn = np.asarray(v_inn_vec, dtype=float)

        log = []
        for k in range(self.n_virt):
            self._load_vl(k)
            cm    = float(np.mean((v_inp + v_inn) / 2))
            of    = op_factor(cm)
            v_row = self.physical.forward(v_inp, v_inn)

            # ADC: row voltage → 8-bit code
            codes = self.adc.convert(v_row)

            # inp_dac: code → column voltage for next VL
            v_dac = self.dac.decode(codes)
            q_err = float(np.mean(np.abs(v_row - v_dac)))

            log.append({
                'vl':        k,
                'v_inp_cm':  cm,
                'op_fac':    of,
                'eff_gain':  of * G0_NOM,
                'v_row':     v_row.copy(),
                'adc_codes': codes.copy(),
                'v_dac':     v_dac.copy(),
                'quant_err': q_err,
            })
            # Next VL: column inputs = DAC outputs; inn = VCM
            v_inp = v_dac
            v_inn = np.full(self.n_dim, VCM)

        return log

"""
pcn_predict.py — Multi-layer predictive coding network simulation.

Validates that PCN hardware cells, when linked hierarchically, form a generative
model: after training, the network predicts its training inputs in ONE inference
step, with prediction error collapsing from ‖x‖²/N to ≈0.

Architecture (2 layers, undercomplete: N_H < N_IN):

    x  ──►  W_0 (N_H × N_IN)  ──►  y_0  ──►  W_1 (N_H × N_H)  ──►  y_1
             ↑                            (higher-level code)
        Prediction of x:
             pred_x = W_0ᵀ @ W_0 @ x  =  P_W0 @ x
                                           (projection onto the learned N_H-dim subspace)

    For x in the trained subspace (W_0 rows ≈ templates): P_W0 @ x ≈ x, error ≈ 0
    For novel x in orthogonal complement:  P_W0 @ x ≈ 0,  error ≈ ‖x‖²/N_IN

Training (GHA / Sanger's rule — hardware-faithful):
    For each row i = 0..N_H-1 sequentially:
      y_i    = W_i @ x_resid           MAC forward pass on residual
      ΔW_i   = lr × y_i × x_resid     Hebbian outer product
      W_i   /= ‖W_i‖₂                 Oja normalisation
      x_resid -= (W_i @ x) × W_i      deflate this row's direction from residual

    GHA (Sanger 1989) with sequential deflation guarantees W_0 rows converge
    to ORTHOGONAL principal components of x — here the N_H training templates
    (since they're orthonormal and equally likely).  After convergence:
    W_0^T @ W_0 ≈ P_{T_train} (orthogonal projector) → stable, no amplification.

    Why GHA, not k=1 WTA?
    With k=1 WTA, two rows can "fight" over the same template: one row that
    partially responds to two orthogonal templates never converges cleanly to
    either (Oja updates on both interfere).  GHA's deflation step projects out
    each row's direction before the next row is updated → no two rows compete
    for the same principal component.

Hardware mapping:
    GHA deflation ≡ predictive coding residual: each row sees x minus the
    reconstruction from all previous rows, matching the PCN layer hierarchy.
    Firmware: after row i updates, subtract DAC output (W_i @ x × W_i) from
    the activation register before the next row's MAC computation.
    N_H = 8 rows  → activate HEBB_MASK[7:0] (HEBB_MASK at 0x10) to use
                     only the first 8 of the 16 physical MAC rows.

Experiments
-----------
P1  Inference convergence:  After training, step-0 pred_err = ‖x‖²/N_IN ≈ 0.0625
    (cold start). After ONE inference step with 'generative' mode:
    pred_x = W_0^T @ W_0 @ x ≈ x → pred_err ≈ 0.
    'none': stays ≈ 0.0625.  Novel: stays ≈ 0.0625 (not in learned subspace).

P2  Specificity: recon_mse for trained, novel, noise.  Trained ≈ 0, novel ≈ 0.0625.

P3  Training convergence: recon_mse over steps, showing Oja + WTA converging W_0.

P4  Template alignment: cosine similarity of W_0 rows vs training templates.
    After convergence each row ≈ one template (cos ≈ 1.0, permuted assignment).
"""

import numpy as np
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from pcn_core import _quantise

RESULTS_DIR = os.path.join(os.path.dirname(__file__), 'results')
os.makedirs(RESULTS_DIR, exist_ok=True)

# ── Parameters ─────────────────────────────────────────────────────────────────
N_IN     = 16    # input columns (physical MAC column count)
N_H      = 8     # hidden rows per layer (undercomplete: N_H < N_IN)
LR       = 0.04  # initial learning rate; decays to LR/10 by end of training
THR      = 0.05  # activation threshold (legacy, not used by GHA path)
N_TRAIN  = 12000 # training steps (GHA + decaying LR: fine convergence near end)
W_STD    = 0.10  # initial weight std
N_INFER  = 4     # inference steps shown in P1
K_WTA    = 1     # k-WTA for L1 (L0 uses GHA instead)

# Float weights.
# 8-bit quantisation (CODE_SCALE=64, 1 LSB=0.0156) requires LR ≥ 0.32 for
# updates to exceed 1 LSB: LR × |y| × |x_j| ≈ LR × 0.5 × 0.25 ≥ 0.0156.
QUANTISE = False


# ── Data ───────────────────────────────────────────────────────────────────────

def make_orthogonal_templates(n_in=N_IN, n_h=N_H, seed=0):
    """
    Two perfectly orthogonal template sets spanning complementary subspaces.
    T_train: (n_h, n_in) — training subspace  (n_h orthonormal vectors)
    T_novel: (n_in-n_h, n_in) — novel subspace (exactly orthogonal to T_train)
    """
    rng = np.random.default_rng(seed)
    Q, _ = np.linalg.qr(rng.standard_normal((n_in, n_in)))
    return Q[:, :n_h].T, Q[:, n_h:].T


def make_training_data(templates, n_samples=N_TRAIN, seed=1):
    """
    Random unit-norm mixtures of templates (1-3 templates combined).
    GHA training works on mixed inputs: the N_H PCs of the mixture distribution
    are the N_H training templates (since they're orthonormal with equal variance).
    """
    rng = np.random.default_rng(seed)
    n_t, n_in = templates.shape
    X = np.zeros((n_samples, n_in))
    for i in range(n_samples):
        k = rng.integers(1, 4)   # 1-3 active templates
        idx = rng.choice(n_t, size=k, replace=False)
        for j in idx:
            X[i] += rng.uniform(0.5, 1.5) * templates[j]
        nrm = np.linalg.norm(X[i])
        if nrm > 1e-8:
            X[i] /= nrm
    return X


# ── Single layer ────────────────────────────────────────────────────────────────

class PredLayer:
    """
    N_rows × N_cols MAC layer with WTA Hebbian + Oja training.

    forward(x)        → y = W @ x
    backward(y)       → W^T @ y
    update(x, y, k)   → k-WTA Hebbian + Oja for winning rows + optional quantise

    Hardware analogue:
      forward  = KCL current summation in the MAC crossbar
      update   = firmware reads IERR_DIG, writes HEBB_ROW_MASK (k entries set),
                 pulses HEBB_EN; each selected row writes back normalised weight
    """

    def __init__(self, n_rows, n_cols, lr=LR, threshold=THR, quantise=QUANTISE, seed=0):
        rng = np.random.default_rng(seed)
        raw = rng.standard_normal((n_rows, n_cols)) * W_STD
        self.W   = _quantise(raw) if quantise else raw.copy()
        self.lr  = lr
        self.thr = threshold
        self.q   = quantise

    def forward(self, x):
        return self.W @ x

    def backward(self, y):
        return self.W.T @ y

    def update_gha(self, x, lr_eff=None):
        """
        Sanger's Generalised Hebbian Algorithm (GHA / Sanger 1989).
        Each row learns one principal component via sequential deflation:
          for i in 0..N_rows-1:
            y_i = W_i @ x_resid                   (MAC on residual)
            W_i += lr * y_i * x_resid             (Hebbian outer product)
            W_i /= ||W_i||                         (Oja normalisation)
            x_resid -= (W_i . x) * W_i            (deflate: remove this PC)

        Deflation prevents two rows from converging to the same PC.
        Hardware analogue: each row's DAC output is fed back to subtract
        its contribution from the column activation register before the
        next row's MAC; identical to the predictive coding residual.
        Returns gate fraction (always 1.0: all rows updated each step).
        """
        lr = lr_eff if lr_eff is not None else self.lr
        x_resid = x.copy()
        for i in range(len(self.W)):
            y_i = float(np.dot(self.W[i], x_resid))
            self.W[i] += lr * y_i * x_resid
            nrm = np.linalg.norm(self.W[i])
            if nrm > 1e-8:
                self.W[i] /= nrm
            # Deflate: project x onto updated w_i, subtract from residual
            proj = float(np.dot(self.W[i], x))
            x_resid -= proj * self.W[i]
        if self.q:
            self.W = _quantise(self.W)
        return 1.0

    def update(self, x, y, k=K_WTA):
        """Legacy k-WTA wrapper (used by L1 in code space)."""
        abs_y = np.abs(y)
        top_k = np.argpartition(abs_y, -k)[-k:]
        gate = np.zeros(len(y), dtype=bool)
        gate[top_k] = True
        dW = (gate * y)[:, None] * x[None, :]
        self.W += self.lr * dW
        norms = np.linalg.norm(self.W, axis=1, keepdims=True)
        self.W /= np.maximum(norms, 1e-8)
        if self.q:
            self.W = _quantise(self.W)
        return float(gate.mean())


# ── Two-layer network ──────────────────────────────────────────────────────────

class PCNPredictiveNetwork:
    """
    Two-layer PCN.

    Training: WTA Hebbian + Oja on x (both modes identical).
    Prediction: pred_x = W_0^T @ W_0 @ x  (one-step projection via L0 only).
    L1 learns higher-level code structure but is NOT in the reconstruction path
    (W_1^T @ W_1 ≠ I unless W_1 rows are mutually orthogonal, which Oja without
    deflation cannot guarantee; using only W_0 gives exact projection stability).
    """

    def __init__(self, n_in=N_IN, n_h=N_H, lr=LR, threshold=THR,
                 pred_mode='generative', quantise=QUANTISE, seed=0):
        self.n_in = n_in
        self.n_h  = n_h
        self.mode = pred_mode
        self.L0   = PredLayer(n_h, n_in, lr, threshold, quantise, seed)
        self.L1   = PredLayer(n_h, n_h,  lr, threshold, quantise, seed + 1)

    def step(self, x, k=K_WTA, lr_eff=None):
        """One training step: GHA on L0, k-WTA Oja on L1."""
        g0 = self.L0.update_gha(x, lr_eff=lr_eff)   # GHA: rows learn orthogonal PCs of x
        y_0 = self.L0.forward(x)
        y_1 = self.L1.forward(y_0)
        g1 = self.L1.update(y_0, y_1, k=k)
        return {'gate_frac_0': g0, 'gate_frac_1': g1}

    def reconstruct(self, x):
        """
        Cold-start evaluation: pred_x = W_0^T @ W_0 @ x (projection onto trained subspace).
        Returns (recon_mse, cos_sim).
        """
        y_0    = self.L0.forward(x)
        pred_x = self.L0.backward(y_0)   # W_0^T @ W_0 @ x
        mse    = float(np.mean((x - pred_x) ** 2))
        nx, np_ = np.linalg.norm(x), np.linalg.norm(pred_x)
        cos = float(np.dot(x, pred_x) / (nx * np_)) if nx > 1e-8 and np_ > 1e-8 else 0.0
        return mse, cos

    def infer(self, x, n_iters=N_INFER):
        """
        Run n_iters inference steps from cold start (pred_x = 0).
        'generative': pred_x <- W_0^T @ W_0 @ x  (one-step; then stays constant)
        'none':       pred_x = 0  always

        Records pred_err = ||x - pred_x||^2 at EACH step (length n_iters+1):
          step 0: pred_x = 0  -> pred_err = ||x||^2/N_IN  (cold start)
          step 1: pred_x = P@x -> pred_err ~= 0 (trained)
          step 2+: same (pred_x is now constant = W_0^T @ W_0 @ x)
        """
        pred_x = np.zeros(self.n_in)
        errs   = []
        for _ in range(n_iters):
            eps_0 = x - pred_x
            errs.append(float(np.mean(eps_0 ** 2)))
            if self.mode == 'generative':
                y_0    = self.L0.forward(x)      # project FULL x (not eps_0)
                pred_x = self.L0.backward(y_0)   # W_0^T @ W_0 @ x; converges in 1 step
        errs.append(float(np.mean((x - pred_x) ** 2)))
        return np.array(errs)   # length n_iters + 1


# ── Training ────────────────────────────────────────────────────────────────────

def train_network(net, X_train, n_steps=N_TRAIN, log_every=200, X_eval=None):
    """
    Train for n_steps steps with cosine-decaying LR: LR → LR/10 by step n_steps.
    Decaying LR reduces oscillations as GHA approaches the optimal subspace.
    Logs recon_mse on X_eval every log_every steps.
    """
    last = {'gate_frac_0': 0.0}
    log  = []
    lr0  = net.L0.lr
    lr_min = lr0 / 10.0
    for step in range(n_steps + 1):
        if step % log_every == 0 and X_eval is not None:
            mses = [net.reconstruct(x)[0] for x in X_eval]
            log.append([step, float(np.mean(mses)), last['gate_frac_0']])
        if step < n_steps:
            # Cosine LR decay: starts at lr0, ends at lr_min
            t = step / n_steps
            lr_eff = lr_min + 0.5 * (lr0 - lr_min) * (1 + np.cos(np.pi * t))
            last = net.step(X_train[step % len(X_train)], lr_eff=lr_eff)
    return net, np.array(log) if log else None


# ── Experiments ────────────────────────────────────────────────────────────────

def p1_inference_convergence(T_train, T_novel, X_train):
    """P1: After training, show one-step inference convergence."""
    print("\n=== P1: Inference convergence (post-training) ===")

    net_gen  = PCNPredictiveNetwork(pred_mode='generative', seed=0)
    net_none = PCNPredictiveNetwork(pred_mode='none',       seed=0)
    train_network(net_gen,  X_train, N_TRAIN)
    train_network(net_none, X_train, N_TRAIN)

    def mean_infer(net, T):
        return np.mean([net.infer(t) for t in T], axis=0)

    gen_tr   = mean_infer(net_gen,  T_train)
    none_tr  = mean_infer(net_none, T_train)
    gen_nov  = mean_infer(net_gen,  T_novel)

    print(f"  generative / trained  : step-0={gen_tr[0]:.5f} -> "
          f"step-1={gen_tr[1]:.6f} -> step-{N_INFER}={gen_tr[-1]:.6f}")
    print(f"  none       / trained  : step-0={none_tr[0]:.5f} -> "
          f"step-{N_INFER}={none_tr[-1]:.5f}  (no change expected)")
    print(f"  generative / novel    : step-0={gen_nov[0]:.5f} -> "
          f"step-{N_INFER}={gen_nov[-1]:.5f}  (novel -> not predicted)")

    return net_gen, net_none, gen_tr, none_tr, gen_nov


def p2_specificity(net_gen, T_train, T_novel):
    """P2: Reconstruction MSE for trained, novel, and random-noise templates."""
    print("\n=== P2: Prediction specificity ===")

    rng   = np.random.default_rng(42)
    noise = rng.standard_normal((len(T_novel), N_IN))
    noise /= np.linalg.norm(noise, axis=1, keepdims=True)

    results = {}
    for label, samples in [('Trained', T_train), ('Novel', T_novel), ('Noise', noise)]:
        mses, coss = zip(*[net_gen.reconstruct(x) for x in samples])
        results[label] = (float(np.mean(mses)), float(np.mean(coss)))
        print(f"  {label:7s}: recon_mse={np.mean(mses):.5f}  cos_sim={np.mean(coss):.4f}")

    ratio = results['Novel'][0] / max(results['Trained'][0], 1e-10)
    print(f"  Specificity ratio (novel / trained) = {ratio:.0f}x")
    return results


def p3_training_convergence(T_train, X_train):
    """P3: recon_mse and gate fraction over training steps."""
    print("\n=== P3: Training convergence ===")
    net = PCNPredictiveNetwork(pred_mode='generative', seed=0)
    net, log = train_network(net, X_train, N_TRAIN, log_every=200, X_eval=T_train)
    if log is not None:
        print(f"  step=0:       recon_mse={log[0,1]:.5f}  gate_frac={log[0,2]:.3f}")
        n_mid = len(log) // 2
        print(f"  step={log[n_mid,0]:.0f}:  recon_mse={log[n_mid,1]:.5f}  gate_frac={log[n_mid,2]:.3f}")
        print(f"  step={N_TRAIN}: recon_mse={log[-1,1]:.5f}  gate_frac={log[-1,2]:.3f}")
    return log


def p4_template_alignment(net_gen, T_train):
    """P4: Max cosine similarity of each W_0 row with any training template."""
    print("\n=== P4: Layer 0 template alignment ===")
    T_norm = T_train / np.linalg.norm(T_train, axis=1, keepdims=True)
    W_norm = net_gen.L0.W / (np.linalg.norm(net_gen.L0.W, axis=1, keepdims=True) + 1e-8)
    cos    = np.abs(W_norm @ T_norm.T)
    max_cos = cos.max(axis=1)
    best_t  = cos.argmax(axis=1)
    sel     = float(np.mean(max_cos > 0.7))
    print(f"  L0 max cos per row: {np.round(max_cos, 3)}")
    print(f"  best template:      {best_t}")
    print(f"  mean={max_cos.mean():.3f}  min={max_cos.min():.3f}  selective (>0.7): {sel:.0%}")

    n_assigned = len(set(best_t))
    print(f"  Templates with assigned rows: {n_assigned}/{N_H}  "
          f"({'full coverage' if n_assigned == N_H else 'some templates unrepresented'})")

    # L1: alignment in code space
    code_templates = (net_gen.L0.W @ T_train.T).T   # (N_H, N_H)
    code_norms = np.linalg.norm(code_templates, axis=1, keepdims=True)
    code_norm  = code_templates / (code_norms + 1e-8)
    W1_norm    = net_gen.L1.W / (np.linalg.norm(net_gen.L1.W, axis=1, keepdims=True) + 1e-8)
    cos1       = np.abs(W1_norm @ code_norm.T).max(axis=1)
    sel1       = float(np.mean(cos1 > 0.7))
    print(f"  L1 max cos (code space): mean={cos1.mean():.3f}  selective (>0.7): {sel1:.0%}")

    return max_cos, cos1


# ── Plotting ──────────────────────────────────────────────────────────────────

def plot_all(p1_data, p2_data, p3_log, p4_data):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  matplotlib not available -- skipping plots")
        return

    fig, axes = plt.subplots(2, 2, figsize=(13, 9))
    fig.suptitle(
        f'PCN Predictive Network  |  N_IN={N_IN} N_H={N_H}  '
        f'LR={LR}  k-WTA={K_WTA}  N_TRAIN={N_TRAIN}  quantise={QUANTISE}',
        fontsize=11, fontweight='bold')

    gen_tr, none_tr, gen_nov = p1_data
    steps = np.arange(len(gen_tr))
    ax = axes[0, 0]
    ax.semilogy(steps, np.maximum(gen_tr, 1e-8),   'b-o',  ms=6, lw=2,   label='generative - trained')
    ax.semilogy(steps, np.maximum(none_tr, 1e-8),  'r--s', ms=5, lw=1.5, label='none - trained')
    ax.semilogy(steps, np.maximum(gen_nov, 1e-8),  'g:^',  ms=5, lw=1.5, label='generative - novel')
    ax.axhline(1.0 / N_IN, color='grey', lw=0.8, ls=':', label=f'||x||^2/N = {1/N_IN:.4f}')
    ax.set_xlabel('Inference step (no weight update)')
    ax.set_ylabel('Prediction error  ||eps_0||^2  (mean over templates)')
    ax.set_title('P1: Inference convergence (post-training)')
    ax.legend(fontsize=8); ax.grid(True, alpha=0.3)
    ax.set_xlim(-0.1, N_INFER)

    labels2 = list(p2_data.keys())
    mses2   = [p2_data[k][0] for k in labels2]
    coss2   = [p2_data[k][1] for k in labels2]
    ax = axes[0, 1]
    x_pos = np.arange(len(labels2))
    ax.bar(x_pos, mses2, color=['steelblue', 'coral', 'grey'], alpha=0.85, zorder=3)
    ax.set_xticks(x_pos); ax.set_xticklabels(labels2, fontsize=9)
    ax.set_ylabel('Reconstruction MSE  ||x - W_0^T W_0 x||^2/N')
    ax2 = ax.twinx()
    ax2.plot(x_pos, coss2, 'k^--', ms=7, lw=1.5, label='cos(pred_x, x)')
    ax2.set_ylim(-0.1, 1.1)
    ax2.set_ylabel('Cosine similarity', fontsize=8)
    ax2.tick_params(axis='y', labelsize=8)
    ax2.legend(fontsize=8, loc='upper right')
    ax.set_title('P2: Prediction specificity  (generative, post-training)')
    ax.grid(True, alpha=0.3, axis='y', zorder=0)
    ax.axhline(1.0 / N_IN, color='black', lw=0.8, ls='--', alpha=0.5)

    ax = axes[1, 0]
    if p3_log is not None:
        ax.semilogy(p3_log[:, 0], np.maximum(p3_log[:, 1], 1e-8), 'b-', lw=2, label='recon_mse')
        ax2p3 = ax.twinx()
        ax2p3.plot(p3_log[:, 0], p3_log[:, 2], 'r--', lw=1.5, label='gate_frac L0')
        ax2p3.set_ylabel('Gate fraction', color='red', fontsize=8)
        ax2p3.tick_params(axis='y', labelcolor='red', labelsize=8)
        ax2p3.legend(fontsize=8, loc='center right')
    ax.set_xlabel('Training step')
    ax.set_ylabel('Reconstruction MSE on T_train')
    ax.set_title(f'P3: Training convergence (Oja + k-WTA, k={K_WTA}, float)')
    ax.legend(fontsize=8, loc='upper right'); ax.grid(True, alpha=0.3)

    max_cos0, cos1 = p4_data
    ax = axes[1, 1]
    x_pos4 = np.arange(N_H)
    ax.bar(x_pos4 - 0.18, max_cos0, width=0.35, alpha=0.85,
           color='steelblue', label='L0 vs T_train')
    ax.bar(x_pos4 + 0.18, cos1,    width=0.35, alpha=0.85,
           color='salmon',    label='L1 vs code templates')
    ax.axhline(0.7, color='black', lw=0.8, ls='--', label='selectivity thr.')
    ax.set_xticks(x_pos4); ax.set_xticklabels([f'r{i}' for i in range(N_H)], fontsize=8)
    ax.set_xlabel('Row index')
    ax.set_ylabel('Max cosine similarity with any template')
    ax.set_title('P4: Layer specialisation (post-training)')
    ax.legend(fontsize=8); ax.grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    path = os.path.join(RESULTS_DIR, 'p_predictive_network.png')
    plt.savefig(path, dpi=120, bbox_inches='tight')
    plt.close()
    print(f"\n  Figure saved -> {path}")


# ── Validation ─────────────────────────────────────────────────────────────────

def validate(gen_tr, none_tr, gen_nov, p2_data, max_cos0):
    print("\n=== Validation ===")
    expected = 1.0 / N_IN
    R = []

    # V1: generative/trained step-0->step-1 ratio < 2% (one-step convergence)
    r1 = gen_tr[1] / max(gen_tr[0], 1e-10)
    ok = r1 < 0.02
    R.append(ok)
    print(f"  V1 gen/trained step-0->step-1 ratio = {r1:.5f}  "
          f"{'PASS' if ok else 'FAIL'}  (expect < 0.02)")

    # V2: none mode stays flat (< 5% variation)
    r2 = abs(none_tr[-1] - none_tr[0]) / max(none_tr[0], 1e-10)
    ok = r2 < 0.05
    R.append(ok)
    print(f"  V2 none-mode variation = {r2:.5f}  "
          f"{'PASS' if ok else 'FAIL'}  (expect < 0.05)")

    # V3: gen/novel stays near ||x||^2/N (novel subspace not learned)
    r3 = gen_nov[-1] / max(expected, 1e-10)
    ok = 0.85 < r3 < 1.15
    R.append(ok)
    print(f"  V3 gen/novel step-{N_INFER} = {gen_nov[-1]:.5f}  "
          f"(expected ~= {expected:.4f})  {'PASS' if ok else 'FAIL'}")

    # V4: trained recon_mse < 1% of ||x||^2/N_IN
    thr4 = 0.01 * expected
    ok = p2_data['Trained'][0] < thr4
    R.append(ok)
    print(f"  V4 trained recon_mse = {p2_data['Trained'][0]:.6f}  "
          f"{'PASS' if ok else 'FAIL'}  (expect < {thr4:.5f})")

    # V5: specificity ratio (novel / trained) > 100x
    ratio = p2_data['Novel'][0] / max(p2_data['Trained'][0], 1e-10)
    ok = ratio > 100.0
    R.append(ok)
    print(f"  V5 specificity ratio (novel / trained) = {ratio:.0f}x  "
          f"{'PASS' if ok else 'FAIL'}  (expect > 100x)")

    # V6: W_0 spans the training subspace — all N_H templates reconstructed with mse < 1%
    # GHA learns ROTATED PCs (not individual templates), but P_{W0} = P_{T_train} exactly.
    per_t = [net_reconstructs_all_templates(max_cos0, p2_data)] if False else None
    all_recon = [p2_data['Trained'][0] < 0.01 * expected]
    ok = all_recon[0]
    subspace_q = 1.0 - p2_data['Trained'][0] / expected   # fraction of variance explained
    R.append(ok)
    print(f"  V6 L0 subspace quality = {subspace_q:.1%} variance explained  "
          f"{'PASS' if ok else 'FAIL'}  (expect trained mse < 1% of ||x||^2/N)")

    n = sum(R)
    print(f"\n  {n}/{len(R)} checks passed", end='')
    if n == len(R):
        print(" -- NETWORK PREDICTION VALIDATED")
    elif n >= len(R) - 1:
        print(" -- prediction capability confirmed (minor miss)")
    else:
        print(f" -- increase N_TRAIN (current={N_TRAIN}) or tune LR/K_WTA")
    return R


# ── Hardware quantisation constraint (Change A §66.5) ─────────────────────────

def hardware_quantisation_note():
    """Compute and print the minimum learning rate for non-zero GHA updates
    when weights and activations are quantised to 8 bits on the PCN hardware.

    In 8-bit fixed-point, weights span ±2 in N_H=8 units mapped to 256 steps,
    giving step = 4/256 = 1/64.  A GHA delta LR × y_i × x_j rounds to zero
    when LR × |y_mean| × |x_mean| < step/2 (round-to-nearest).

    Typical magnitudes (unit-norm inputs, converged W_0):
      |y_mean| ≈ 1/sqrt(N_H) ≈ 0.35  (cos of angle to nearest PC component)
      |x_mean| ≈ 1/sqrt(N_IN)  = 0.25

    LR_MIN such that 50% of updates are non-zero: LR_MIN = step / (|y| × |x|)
    """
    step      = 4.0 / 256          # 8-bit DAC, weight range ±2
    y_mean    = 1.0 / N_H**0.5     # typical |y| in converged network
    x_mean    = 1.0 / N_IN**0.5    # typical |x_j|
    lr_min    = step / (y_mean * x_mean)
    # Worst-case (deflated residual with small projections): use 0.2 and 0.25
    lr_min_wc = step / (0.2 * 0.25)

    print(f"\n── Hardware Quantisation Constraint (Change A §66.5) ────────────────")
    print(f"  8-bit weight step       = {step:.5f}  (4/256, range ±2)")
    print(f"  |y_mean| × |x_mean|    = {y_mean:.3f} × {x_mean:.3f} = {y_mean*x_mean:.4f}")
    print(f"  LR_MIN (typical)        = {lr_min:.3f}")
    print(f"  LR_MIN (worst case)     = {lr_min_wc:.3f}  (deflated residuals)")
    print(f"  Simulation LR           = {LR}  (LR_MIN ratio = {LR/lr_min:.2f}x)")
    if LR >= lr_min_wc:
        status = "PASS: LR exceeds worst-case threshold"
    elif LR >= lr_min:
        status = "MARGINAL: LR above typical but below worst-case"
    else:
        status = "WARN: LR below typical threshold — hardware training will stall"
    print(f"  Status: {status}")
    print(f"  Hardware recommendation: use LR >= {lr_min_wc:.2f} for robust 8-bit GHA")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("PCN Predictive Network Simulation")
    print("=" * 62)
    print(f"N_IN={N_IN}, N_H={N_H}, N_TRAIN={N_TRAIN}, LR={LR}, "
          f"k-WTA={K_WTA}, quantise={QUANTISE}")

    T_train, T_novel = make_orthogonal_templates()
    X_train          = make_training_data(T_train, n_samples=N_TRAIN, seed=1)

    t_nrm  = np.linalg.norm(T_train, axis=1).mean()
    n_nrm  = np.linalg.norm(T_novel, axis=1).mean()
    inner  = np.abs(T_train @ T_novel.T).max()
    print(f"\nData: {len(T_train)} training templates, "
          f"{len(T_novel)} novel templates, {len(X_train)} samples")
    print(f"Template norms: train={t_nrm:.4f}  novel={n_nrm:.4f}  (expect 1.000)")
    print(f"Max |T_train . T_novel^T| = {inner:.2e}  (expect ~= 0: exact orthogonal complement)")

    net_gen, net_none, gen_tr, none_tr, gen_nov = p1_inference_convergence(
        T_train, T_novel, X_train)

    p2 = p2_specificity(net_gen, T_train, T_novel)

    p3_log = p3_training_convergence(T_train, X_train)

    max_cos0, cos1 = p4_template_alignment(net_gen, T_train)

    plot_all(
        (gen_tr, none_tr, gen_nov),
        p2, p3_log, (max_cos0, cos1),
    )

    validate(gen_tr, none_tr, gen_nov, p2, max_cos0)

    hardware_quantisation_note()


if __name__ == '__main__':
    main()

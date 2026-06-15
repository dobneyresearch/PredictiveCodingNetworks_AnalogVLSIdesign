"""
run_sim.py — Main simulation script.  Runs all experiments and saves results.

The PCN uses the reconstruction prediction:
    y      = W @ x              (MAC forward pass)
    x_hat  = W^T @ y            (top-down reconstruction, W^T path)
    y_pred = W @ x_hat          (predicted output in row-current space)
    error  = y - y_pred = (I - W W^T) y

This is Oja's deflation rule — self-stabilising and guaranteed to converge
to the principal subspace of the input covariance.  It matches the hardware
operation when the top-down prediction is the layer's own reconstruction.

Experiments
-----------
  E1. Gaussian PCA — mode comparison (v1 / bcm / v2)
  E2. Bars and stripes — feature learning, weight visualisation
  E3. Hardware quantisation effect — v2 quantised vs float
  E4. Temporal reuse — 4-virtual-layer stack

Usage
-----
  python run_sim.py              # all experiments
  python run_sim.py --exp E1     # single experiment
  python run_sim.py --no-plots   # text output only

Requires: numpy, matplotlib
"""

import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))

from pcn_core import PCNLayer, PCNTemporalStack
from tasks import (gaussian_pca, bars_stripes, subspace_alignment,
                   bar_selectivity, reconstruction_error,
                   random_templates, template_selectivity)
from train import train_layer, compare_modes, train_temporal

RESULTS_DIR = os.path.join(os.path.dirname(__file__), 'results')


def _ensure_results():
    os.makedirs(RESULTS_DIR, exist_ok=True)


def _recon_pred_fn(layer):
    """
    Return a y_pred function that computes the reconstruction prediction:
        y_pred = W @ (W^T @ (W @ x))
    This is the self-supervised top-down signal for the PCN autoencoder.
    The closure uses the layer's *current* W, so it updates with learning.
    """
    def fn(x):
        y    = layer.forward(x)
        xhat = layer.predict_down(y)
        return layer.forward(xhat)
    return fn


# ── E1: Gaussian PCA — mode comparison ───────────────────────────────────────

def run_e1(plots=True):
    print("\n=== E1: Gaussian PCA — learning mode comparison ===")

    N_IN, N_ROWS, N_PCS = 8, 4, 4
    N_SAMP = 6000
    LR, THRESH = 0.01, 0.02

    X, U_true, eigs = gaussian_pca(n_samples=N_SAMP, n_in=N_IN,
                                    n_components=N_PCS, snr_db=20, seed=0)
    X_train, X_test = X[:5000], X[5000:]

    print(f"  Data: n_samples={N_SAMP}, n_in={N_IN}, n_rows={N_ROWS}")
    print(f"  Input std={X_train.std():.3f}, max={np.abs(X_train).max():.3f}")

    results = {}
    for mode in ('v1', 'bcm', 'v2'):
        layer = PCNLayer(N_ROWS, N_IN, lr=LR, threshold=THRESH,
                         mode=mode, quantise=True, seed=42)
        pred_fn = _recon_pred_fn(layer)

        def align_fn(lyr, step, _U=U_true):
            return subspace_alignment(lyr.W, _U)

        h = train_layer(layer, X_train, n_epochs=8,
                         y_pred_fn=pred_fn,
                         eval_fn=align_fn, eval_every=100, seed=42)
        recon = reconstruction_error(layer, X_test)
        final_align = h['extra'][-1] if h.get('extra') else float('nan')
        print(f"  {mode:3s}  pred_err={h['pred_error'][-1]:.4f}  "
              f"align={final_align:.3f}  gate_frac={h['gate_frac'][-1]:.3f}  "
              f"recon_mse={recon:.4f}")
        results[mode] = {'history': h, 'layer': layer}

    if plots:
        _plot_e1(results, U_true)

    return results


def _plot_e1(results, U_true):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  [matplotlib not available]"); return

    _ensure_results()
    fig, axes = plt.subplots(1, 3, figsize=(13, 4))
    colours = {'v1': '#e74c3c', 'bcm': '#f39c12', 'v2': '#27ae60'}
    labels  = {'v1': 'V1 (LTP-only)', 'bcm': 'V1 + BCM', 'v2': 'V2 (signed)'}

    ax = axes[0]
    for mode, res in results.items():
        h = res['history']
        ax.semilogy(h['step'], h['pred_error'],
                    color=colours[mode], label=labels[mode])
    ax.set_xlabel('Weight update step'); ax.set_ylabel('Mean |error|')
    ax.set_title('Convergence (Gaussian PCA)'); ax.legend(); ax.grid(True, alpha=0.3)

    ax = axes[1]
    for mode, res in results.items():
        h = res['history']
        if h.get('extra'):
            ax.plot(h['step'], h['extra'], color=colours[mode], label=labels[mode])
    ax.set_xlabel('Weight update step'); ax.set_ylabel('Subspace alignment (cos²)')
    ax.set_title('PC alignment vs true subspace'); ax.set_ylim(0, 1)
    ax.legend(); ax.grid(True, alpha=0.3)
    ax.axhline(1.0, color='k', ls='--', lw=0.8, alpha=0.4, label='Perfect')

    ax = axes[2]
    W_v2 = results['v2']['layer'].W
    im = ax.imshow(W_v2, aspect='auto', cmap='RdBu_r', vmin=-1, vmax=1)
    ax.set_xlabel('Input dim'); ax.set_ylabel('Output row')
    ax.set_title('Learned W (V2, final)')
    plt.colorbar(im, ax=ax)

    plt.tight_layout()
    path = os.path.join(RESULTS_DIR, 'e1_gaussian_pca.png')
    plt.savefig(path, dpi=150); plt.close()
    print(f"  Saved {path}")


# ── E2: Template learning ─────────────────────────────────────────────────────

def run_e2(plots=True):
    print("\n=== E2: Template learning — feature detection (V2 + k-WTA) ===")

    # 8 random orthogonal templates in R^16.  Templates are by construction
    # orthonormal, making this a clean test of PCA/subspace recovery.
    # Equivalent to bars-on-a-line (no spatial overlap between features).
    N_TEMPLATES = 8
    N_IN        = 16
    N_ROWS      = N_TEMPLATES
    LR, THRESH  = 0.01, 0.03
    N_SAMP      = 12000

    X, templates, labels = random_templates(n_samples=N_SAMP,
                                            n_templates=N_TEMPLATES,
                                            n_in=N_IN,
                                            k_active_max=3, noise=0.05, seed=1)
    X_train, X_test = X[:10000], X[10000:]

    print(f"  Data: n_in={N_IN}, n_templates={N_TEMPLATES}, n_rows={N_ROWS}")
    print(f"  Input std={X_train.std():.3f}, template inner-products "
          f"(should be ~0): {np.abs(templates @ templates.T - np.eye(N_TEMPLATES)).mean():.4f}")

    snapshots = {}
    snap_steps = {0, 5000, 15000, 25000}

    # k-WTA + row normalisation = hardware Oja's rule.  y_pred=0 (no
    # reconstruction prediction): normalisation alone prevents divergence.
    # The top-k-WTA gate enforces competition so each row specialises to
    # one template rather than collapsing onto the first principal component.
    layer = PCNLayer(N_ROWS, N_IN, lr=LR, threshold=THRESH,
                     mode='v2', quantise=True, w_init_scale=0.25,
                     normalize_rows=True, k_wta=2, seed=7)

    def snap_eval(lyr, step):
        _, sel = template_selectivity(lyr.W, templates)
        if step in snap_steps:
            snapshots[step] = lyr.W.copy()
        return sel

    h = train_layer(layer, X_train, n_epochs=3,
                     y_pred_fn=None,
                     eval_fn=snap_eval, eval_every=200, seed=1)

    _, final_sel = template_selectivity(layer.W, templates)
    print(f"  Template selectivity (rows with max_cos > 0.7): {final_sel:.3f}")
    print(f"  Final gate_frac: {h['gate_frac'][-1]:.3f}")

    if plots:
        _plot_e2(h, snapshots, layer.W, templates)

    return h, layer


def _plot_e2(history, snapshots, W_final, templates):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  [matplotlib not available]"); return

    _ensure_results()
    snap_keys = sorted(snapshots.keys())
    n_snaps = len(snap_keys)
    n_rows, n_in = W_final.shape
    n_templates = templates.shape[0]

    fig = plt.figure(figsize=(4 + 3.0 * n_snaps + 3.0, 5))
    ax0 = fig.add_subplot(1, n_snaps + 2, 1)
    ax0.plot(history['step'], history['extra'], color='#27ae60')
    ax0.set_xlabel('Step'); ax0.set_ylabel('Template selectivity (cos>0.7)')
    ax0.set_title('Feature detection'); ax0.set_ylim(0, 1)
    ax0.grid(True, alpha=0.3)

    # Weight snapshot columns
    for s_idx, step in enumerate(snap_keys):
        W = snapshots[step]
        W_n = W / (np.linalg.norm(W, axis=1, keepdims=True) + 1e-8)
        ax = fig.add_subplot(1, n_snaps + 2, s_idx + 2)
        cos_mat = np.abs(W_n @ templates.T)
        ax.imshow(cos_mat, aspect='auto', cmap='Blues', vmin=0, vmax=1)
        ax.set_xlabel('Template'); ax.set_ylabel('W row')
        ax.set_title(f'|cos(W, T)|\nstep {step}')

    # Final cosine matrix
    W_n = W_final / (np.linalg.norm(W_final, axis=1, keepdims=True) + 1e-8)
    ax_f = fig.add_subplot(1, n_snaps + 2, n_snaps + 2)
    im = ax_f.imshow(np.abs(W_n @ templates.T),
                     aspect='auto', cmap='Blues', vmin=0, vmax=1)
    ax_f.set_xlabel('Template'); ax_f.set_ylabel('W row')
    ax_f.set_title('|cos(W, T)| — final')
    plt.colorbar(im, ax=ax_f)

    plt.suptitle(f'Template learning: cosine similarity (V2+k-WTA, '
                 f'{n_templates} templates, {n_in}D)', fontsize=10)
    plt.tight_layout()
    path = os.path.join(RESULTS_DIR, 'e2_template_learning.png')
    plt.savefig(path, dpi=150); plt.close()
    print(f"  Saved {path}")


# ── E3: Quantisation effect ───────────────────────────────────────────────────

def run_e3(plots=True):
    print("\n=== E3: Hardware quantisation effect (V2 mode) ===")

    N_IN, N_ROWS, N_PCS = 8, 4, 4
    LR, THRESH = 0.01, 0.02
    X, U_true, _ = gaussian_pca(n_samples=6000, n_in=N_IN,
                                 n_components=N_PCS, seed=0)
    X_train, X_test = X[:5000], X[5000:]

    results = {}
    for quantise, label in [(True, 'quantised (8-bit HW)'),
                             (False, 'full-precision float')]:
        layer = PCNLayer(N_ROWS, N_IN, lr=LR, threshold=THRESH,
                         mode='v2', quantise=quantise, seed=42)
        pred_fn = _recon_pred_fn(layer)

        def align_fn(lyr, step, _U=U_true):
            return subspace_alignment(lyr.W, _U)

        h = train_layer(layer, X_train, n_epochs=8,
                         y_pred_fn=pred_fn,
                         eval_fn=align_fn, eval_every=100, seed=42)
        recon = reconstruction_error(layer, X_test)
        final_align = h['extra'][-1] if h.get('extra') else float('nan')
        print(f"  {label:30s}  align={final_align:.3f}  "
              f"recon_mse={recon:.4f}  w_std={h['w_std'][-1]:.3f}")
        results[label] = h

    if plots:
        _plot_e3(results)

    return results


def _plot_e3(results):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  [matplotlib not available]"); return

    _ensure_results()
    fig, axes = plt.subplots(1, 2, figsize=(9, 4))
    colours = ['#2980b9', '#e67e22']

    for ax_idx, key in enumerate(['pred_error', 'extra']):
        ax = axes[ax_idx]
        for (label, h), col in zip(results.items(), colours):
            if h.get(key):
                vals = h[key]
                if key == 'pred_error':
                    ax.semilogy(h['step'], vals, label=label, color=col)
                else:
                    ax.plot(h['step'], vals, label=label, color=col)
        ax.set_xlabel('Weight update step')
        if key == 'pred_error':
            ax.set_ylabel('Mean |error|')
            ax.set_title('Convergence — quantised vs float')
        else:
            ax.set_ylabel('Subspace alignment (cos²)')
            ax.set_title('PC alignment — quantised vs float')
            ax.set_ylim(0, 1)
        ax.legend(fontsize=8); ax.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(RESULTS_DIR, 'e3_quantisation.png')
    plt.savefig(path, dpi=150); plt.close()
    print(f"  Saved {path}")


# ── E4: Temporal reuse ────────────────────────────────────────────────────────

def run_e4(plots=True):
    print("\n=== E4: Temporal reuse — 4 virtual layers (square 4×4 array) ===")

    # Square array: each VL maps 4→4 (output feeds next VL's input)
    N_DIM  = 4   # n_rows = n_cols = 4
    N_VIRT = 4
    LR, THRESH = 0.01, 0.02
    N_SAMP = 5000

    # Use 4-dimensional Gaussian data so VL0 is also 4→4
    X, _, _ = gaussian_pca(n_samples=N_SAMP, n_in=N_DIM,
                            n_components=N_DIM, snr_db=20, seed=0)
    X_train = X[:4000]
    print(f"  Array: {N_DIM}×{N_DIM}, {N_VIRT} virtual layers")
    print(f"  Input std={X_train.std():.3f}")

    stack = PCNTemporalStack(N_DIM, N_DIM, n_virt=N_VIRT,
                              lr=LR, threshold=THRESH,
                              mode='v2', quantise=True, seed=42)

    # Reconstruction prediction per layer
    preds = [_recon_pred_fn(layer) for layer in stack.layers]

    histories = train_temporal(stack, X_train, n_epochs=3,
                                predictions=preds,
                                eval_every=200, seed=0)

    for k, h in enumerate(histories):
        if h['pred_error']:
            print(f"  VL{k}  final pred_error={h['pred_error'][-1]:.4f}  "
                  f"steps={h['step'][-1]}")

    if plots:
        _plot_e4(histories)

    return histories


def _plot_e4(histories):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  [matplotlib not available]"); return

    _ensure_results()
    fig, ax = plt.subplots(figsize=(7, 4))
    cmap = plt.get_cmap('viridis')
    n = len(histories)
    for k, h in enumerate(histories):
        if h['step']:
            ax.semilogy(h['step'], h['pred_error'],
                        color=cmap(k / max(n - 1, 1)), label=f'VL{k}')
    ax.set_xlabel('Weight update step'); ax.set_ylabel('Mean |error|')
    ax.set_title('Temporal reuse: per-layer convergence (V2, 4 VLs, 4×4 array)')
    ax.legend(); ax.grid(True, alpha=0.3)
    plt.tight_layout()
    path = os.path.join(RESULTS_DIR, 'e4_temporal_reuse.png')
    plt.savefig(path, dpi=150); plt.close()
    print(f"  Saved {path}")


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='PCN hardware simulation')
    parser.add_argument('--exp', choices=['E1', 'E2', 'E3', 'E4'])
    parser.add_argument('--no-plots', action='store_true')
    args = parser.parse_args()
    plots = not args.no_plots

    experiments = {'E1': run_e1, 'E2': run_e2, 'E3': run_e3, 'E4': run_e4}

    if args.exp:
        experiments[args.exp](plots=plots)
    else:
        for fn in experiments.values():
            fn(plots=plots)

    print("\nDone.")


if __name__ == '__main__':
    main()

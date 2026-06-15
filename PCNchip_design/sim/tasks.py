"""
tasks.py — Datasets for PCN simulation.

Three tasks, in increasing difficulty:

  gaussian_pca  — Random Gaussian data with a known low-rank structure.
                  The PCN should learn the top n_rows principal components.
                  Ground truth is analytically computable.

  bars_stripes  — Classic sparse coding benchmark: binary images with
                  randomly placed horizontal or vertical bars.
                  A correct PCN should learn one detector per bar.

  mnist_subset  — Greyscale MNIST digits (requires sklearn or torchvision).
                  Demonstrates scaling to real data.
"""

import numpy as np


# ── Gaussian PCA task ─────────────────────────────────────────────────────────

def gaussian_pca(n_samples=5000, n_in=8, n_components=3, snr_db=20, seed=0):
    """
    Generate data from a low-rank Gaussian model.

    x = U s + noise,  s ~ N(0, diag(eigenvalues)),  noise ~ N(0, σ² I)

    where U is an orthonormal basis (n_in × n_components) and eigenvalues
    are spaced logarithmically so the top components are clearly dominant.

    Returns
    -------
    X        : (n_samples, n_in) data matrix, zero-mean, unit-max normalised.
    U_true   : (n_in, n_components) true principal directions (for evaluation).
    eigs     : (n_components,) eigenvalues in descending order.
    """
    rng = np.random.default_rng(seed)

    # True low-rank structure
    U_raw = rng.standard_normal((n_in, n_components))
    U_true, _ = np.linalg.qr(U_raw)           # orthonormalise
    U_true = U_true[:, :n_components]

    eigs = np.logspace(1, 0, n_components)     # e.g. [10, 3.16, 1.0]

    # Signal
    s = rng.standard_normal((n_samples, n_components)) * np.sqrt(eigs)
    X_signal = s @ U_true.T                   # (n_samples, n_in)

    # Noise calibrated to SNR
    signal_var = np.mean(X_signal ** 2)
    noise_std = np.sqrt(signal_var / (10 ** (snr_db / 10)))
    X = X_signal + rng.standard_normal((n_samples, n_in)) * noise_std

    # Standardise to zero-mean, unit std (keeps hardware-compatible scale)
    X = X / (np.std(X) + 1e-8)

    return X, U_true, eigs


def subspace_alignment(W, U_true):
    """
    Measure alignment between learned weight rows and true principal directions.

    Returns the mean squared cosine similarity between each row of W and
    its nearest column in U_true (best-match assignment, greedy).

    Score 1.0 = perfect alignment; 0.0 = orthogonal.
    """
    W_norm = W / (np.linalg.norm(W, axis=1, keepdims=True) + 1e-8)
    U_norm = U_true / (np.linalg.norm(U_true, axis=0, keepdims=True) + 1e-8)
    cos_sim = W_norm @ U_norm           # (n_rows, n_components)
    # Greedy best-match
    available = list(range(U_true.shape[1]))
    total = 0.0
    for i in range(min(W.shape[0], len(available))):
        row_sims = np.abs(cos_sim[i, available])
        best = available[np.argmax(row_sims)]
        total += np.abs(cos_sim[i, best]) ** 2
        available.remove(best)
    return total / W.shape[0]


# ── Bars and stripes ──────────────────────────────────────────────────────────

def bars_stripes(n_samples=4000, grid=4, noise=0.05, seed=0):
    """
    Generate bars-and-stripes patterns on a grid×grid binary image.

    Each pattern independently activates each row-bar (horizontal) or
    column-bar (vertical) with probability 0.5.  Each pattern has at least
    one bar.

    Returns
    -------
    X      : (n_samples, grid*grid) normalised to [-0.5, +0.5].
    bars   : (grid, grid*grid) ideal bar detector weight matrix (for evaluation).
    labels : (n_samples, 2*grid) binary indicator of which bars are active.
    """
    rng = np.random.default_rng(seed)
    n_pixels = grid * grid
    n_bars = 2 * grid   # grid horizontal + grid vertical bars

    X = np.zeros((n_samples, n_pixels))
    labels = np.zeros((n_samples, n_bars), dtype=int)

    for i in range(n_samples):
        img = np.zeros((grid, grid))
        # Ensure at least one bar is active
        mask = rng.integers(0, 2, size=n_bars)
        if mask.sum() == 0:
            mask[rng.integers(0, n_bars)] = 1
        labels[i] = mask

        for b in range(grid):
            if mask[b]:             # horizontal bar b
                img[b, :] = 1.0
        for b in range(grid):
            if mask[grid + b]:      # vertical bar b
                img[:, b] = 1.0

        # Add noise
        img += rng.standard_normal((grid, grid)) * noise
        X[i] = img.flatten()

    # Normalise to [-0.5, +0.5]
    X = X - 0.5

    # Ideal weight matrix: one detector row per bar
    # Rows 0..grid-1: horizontal detectors; rows grid..2*grid-1: vertical
    bars = np.zeros((n_bars, n_pixels))
    for b in range(grid):
        bars[b, b * grid:(b + 1) * grid] = 1.0   # horizontal bar b
    for b in range(grid):
        bars[grid + b, b::grid] = 1.0             # vertical bar b
    bars = bars / np.linalg.norm(bars, axis=1, keepdims=True)

    return X, bars, labels


def bar_selectivity(W, grid):
    """
    Measure how well each row of W responds to individual bars.

    For each weight row, compute its correlation with each of the 2*grid
    ideal bar detectors.  Report the max correlation and the fraction of
    rows that are 'selective' (max correlation > 0.7).

    Returns
    -------
    max_corr     : (n_rows,) — max bar correlation per row.
    selective    : float — fraction of rows with max_corr > 0.7.
    """
    n_pixels = grid * grid
    _, bars, _ = bars_stripes(n_samples=1, grid=grid)
    W_norm = W / (np.linalg.norm(W, axis=1, keepdims=True) + 1e-8)
    corr = W_norm @ bars.T    # (n_rows, 2*grid)
    max_corr = np.max(np.abs(corr), axis=1)
    selective = float(np.mean(max_corr > 0.7))
    return max_corr, selective


# ── Reconstruction metrics ────────────────────────────────────────────────────

def random_templates(n_samples=8000, n_templates=8, n_in=16,
                      k_active_max=3, noise=0.05, seed=0):
    """
    Sparse template task: each sample is a random linear combination of
    1..k_active_max templates from a fixed dictionary of n_templates
    random unit-norm vectors.

    This is an idealized version of bars-and-stripes where templates are
    genuinely orthogonal (approx) in high dimensions, making it analytically
    tractable for PCA-style recovery.

    Returns
    -------
    X         : (n_samples, n_in)  data matrix, std-normalised.
    templates : (n_templates, n_in) true template matrix (unit-norm rows).
    labels    : (n_samples, n_templates) binary activation indicator.
    """
    rng = np.random.default_rng(seed)

    # Orthonormal template set (QR gives exactly orthonormal columns)
    T_raw = rng.standard_normal((n_in, n_templates))
    T_ortho, _ = np.linalg.qr(T_raw)
    templates = T_ortho[:, :n_templates].T  # (n_templates, n_in)

    X = np.zeros((n_samples, n_in))
    labels = np.zeros((n_samples, n_templates), dtype=int)

    for i in range(n_samples):
        k = rng.integers(1, k_active_max + 1)
        active = rng.choice(n_templates, size=k, replace=False)
        labels[i, active] = 1
        coeffs = rng.uniform(0.5, 1.5, size=k)
        for t, c in zip(active, coeffs):
            X[i] += c * templates[t]
        X[i] += rng.standard_normal(n_in) * noise

    X = X / (np.std(X) + 1e-8)
    return X, templates, labels


def template_selectivity(W, templates, threshold=0.7):
    """
    Fraction of weight rows with max cosine similarity to templates > threshold.
    """
    W_norm = W / (np.linalg.norm(W, axis=1, keepdims=True) + 1e-8)
    T_norm = templates / (np.linalg.norm(templates, axis=1, keepdims=True) + 1e-8)
    cos_sim = np.abs(W_norm @ T_norm.T)
    max_corr = np.max(cos_sim, axis=1)
    return max_corr, float(np.mean(max_corr > threshold))


def reconstruction_error(layer, X_test, use_pred_down=True):
    """
    Mean squared reconstruction error on a test set.

    Forward: y = W @ x
    Reconstruct: x̂ = W^T @ y  (requires use_pred_down=True)
                 or x̂ = 0     (measures raw output energy when False)

    Returns mean ||x - x̂||² / ||x||².
    """
    total = 0.0
    for x in X_test:
        y = layer.forward(x)
        if use_pred_down:
            x_hat = layer.predict_down(y)
        else:
            x_hat = np.zeros_like(x)
        total += np.sum((x - x_hat) ** 2) / (np.sum(x ** 2) + 1e-8)
    return total / len(X_test)

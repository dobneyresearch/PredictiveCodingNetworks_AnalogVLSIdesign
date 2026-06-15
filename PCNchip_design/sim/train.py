"""
train.py — Training loop and evaluation for the PCN simulation.

Presents input patterns one at a time to the PCNLayer and applies the
hardware-faithful update rule.  Matches the chip's operating procedure:
  1. Present x to the array (forward pass).
  2. Compute row-level error ε = y - y_pred.
  3. Apply precision-gated Hebbian update (per the selected mode).
  4. Quantise weights (if enabled).

For temporal-reuse experiments (PCNTemporalStack), each pattern is
propagated through all virtual layers in sequence, with the ADC
quantisation applied between layers.
"""

import numpy as np
from pcn_core import PCNLayer, PCNTemporalStack


def train_layer(layer, X_train, n_epochs=1,
                y_pred_fn=None, eval_every=200,
                eval_fn=None, shuffle=True, seed=0):
    """
    Train a single PCNLayer on the dataset X_train.

    Parameters
    ----------
    layer       : PCNLayer
    X_train     : (n_samples, n_cols)
    n_epochs    : int — number of full passes through the data.
    y_pred_fn   : callable(x) → (n_rows,) or None.
                  Generates the top-down prediction for each input.
                  If None, prediction is zero (V1 feedforward mode).
    eval_every  : int — record metrics every N weight-update steps.
    eval_fn     : callable(layer, step) → dict or None.
                  Additional evaluation function (e.g. subspace alignment).
    shuffle     : bool — shuffle data each epoch.
    seed        : int — RNG seed for shuffling.

    Returns
    -------
    history : dict — training metrics logged at each eval point.
    """
    rng = np.random.default_rng(seed)
    history = {
        'step':       [],
        'pred_error': [],
        'gate_frac':  [],
        'w_std':      [],
    }
    if eval_fn is not None:
        history['extra'] = []

    step = 0
    for epoch in range(n_epochs):
        idx = rng.permutation(len(X_train)) if shuffle else np.arange(len(X_train))
        for i in idx:
            x = X_train[i]
            y = layer.forward(x)
            y_pred = y_pred_fn(x) if y_pred_fn is not None else np.zeros(layer.n_rows)
            record = (step % eval_every == 0)
            layer.update(x, y, y_pred, record=record)
            if record:
                history['step'].append(step)
                history['pred_error'].append(layer.history['pred_error'][-1])
                history['gate_frac'].append(layer.history['gate_frac'][-1])
                history['w_std'].append(layer.history['w_std'][-1])
                if eval_fn is not None:
                    history['extra'].append(eval_fn(layer, step))
            step += 1

    return history


def compare_modes(X_train, n_rows, n_cols,
                  lr=0.02, threshold=0.05, n_epochs=3,
                  y_pred_fn=None, eval_fn=None, eval_every=100,
                  quantise=True, seed=42):
    """
    Train one layer with each learning mode (v1, bcm, v2) under identical
    conditions.  Returns a dict of per-mode history and final layer objects.

    Used to generate the mode comparison figure for the paper.
    """
    results = {}
    for mode in ('v1', 'bcm', 'v2'):
        layer = PCNLayer(n_rows, n_cols,
                         lr=lr, threshold=threshold,
                         mode=mode, quantise=quantise, seed=seed)
        history = train_layer(layer, X_train,
                              n_epochs=n_epochs,
                              y_pred_fn=y_pred_fn,
                              eval_every=eval_every,
                              eval_fn=eval_fn,
                              seed=seed)
        results[mode] = {'history': history, 'layer': layer}
    return results


def train_temporal(stack, X_train, n_epochs=1,
                   predictions=None, eval_every=500, seed=0):
    """
    Train a PCNTemporalStack — each virtual layer updates on the output
    of the previous layer (with ADC quantisation between layers).

    Parameters
    ----------
    stack       : PCNTemporalStack
    X_train     : (n_samples, n_cols)
    predictions : list of callable(x_vl) → (n_rows,) or None
    eval_every  : int

    Returns
    -------
    history : list of per-layer history dicts.
    """
    rng = np.random.default_rng(seed)
    histories = [{'step': [], 'pred_error': []} for _ in range(stack.n_virt)]

    step = 0
    for epoch in range(n_epochs):
        idx = rng.permutation(len(X_train))
        for i in idx:
            x = X_train[i]
            record = (step % eval_every == 0)
            act = x
            for k, layer in enumerate(stack.layers):
                y = layer.forward(act)
                pred = (predictions[k](act) if predictions and predictions[k]
                        else np.zeros(layer.n_rows))
                layer.update(act, y, pred, record=record)
                act = stack._adc_quantise(y)
            if record:
                for k, layer in enumerate(stack.layers):
                    if layer.history['pred_error']:
                        histories[k]['step'].append(step)
                        histories[k]['pred_error'].append(
                            layer.history['pred_error'][-1])
            step += 1

    return histories

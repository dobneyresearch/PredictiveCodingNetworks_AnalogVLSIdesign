#!/usr/bin/env python3
"""
PCN MAC Cell — Simulation Results Plotter
Reads CSV output produced by run_sim.sh and saves PNG plots to output/plots/.

Usage:
    python3 plot_results.py                        # reads ./output/
    python3 plot_results.py --sim-dir /path/to/output
    python3 plot_results.py --show                 # also display interactively
    python3 plot_results.py --no-summary           # skip combined figure

Requirements:
    pip install numpy pandas matplotlib
"""

import sys
import argparse
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from pathlib import Path
from typing import Optional, List


# ── Style ──────────────────────────────────────────────────────────────────
plt.rcParams.update({
    'font.family':        'sans-serif',
    'font.size':          10,
    'axes.titlesize':     11,
    'axes.titleweight':   'bold',
    'axes.labelsize':     10,
    'axes.spines.top':    False,
    'axes.spines.right':  False,
    'axes.grid':          True,
    'grid.alpha':         0.25,
    'grid.linestyle':     '--',
    'lines.linewidth':    1.8,
    'figure.dpi':         110,
    'savefig.dpi':        150,
    'savefig.bbox':       'tight',
    'legend.framealpha':  0.85,
    'legend.fontsize':    8,
})

BLUE    = '#2563EB'
GREEN   = '#16A34A'
RED     = '#DC2626'
PURPLE  = '#7C3AED'
GRAY    = '#9CA3AF'
LGRAY   = '#F3F4F6'


# ── Data loading ───────────────────────────────────────────────────────────

def load_csv(path: Path,
             names: Optional[List[str]] = None) -> Optional[pd.DataFrame]:
    """
    Load an ngspice wrdata ASCII file.

    Handles two formats ngspice may produce:
      - with a whitespace-separated header row  (ngspice 37+)
      - without a header row (older versions)
    Returns None if the file is missing or unparseable.
    """
    if not path.exists():
        print(f"  [skip]  {path.name} not found")
        return None
    try:
        raw = pd.read_csv(path, sep=r'\s+', skipinitialspace=True, comment='*')

        # If the first column header is numeric-looking, there is no header row
        try:
            float(raw.columns[0])
            has_header = False
        except ValueError:
            has_header = True

        if not has_header:
            raw = pd.read_csv(path, sep=r'\s+', skipinitialspace=True,
                              comment='*', header=None)

        # Apply caller-supplied column names if count matches
        if names:
            raw = raw.iloc[:, :len(names)]
            raw.columns = names[:len(raw.columns)]

        df = raw.apply(pd.to_numeric, errors='coerce').dropna()
        if df.empty:
            print(f"  [warn]  {path.name} parsed but contains no numeric data")
            return None
        return df

    except Exception as exc:
        print(f"  [warn]  Could not load {path.name}: {exc}")
        return None


# ── Analysis 2: DC Transfer Curve ─────────────────────────────────────────

def plot_transfer_curve(df: pd.DataFrame, plot_dir: Path) -> None:
    """Two panels: I_out vs V_diff, and gm = dI_out/dV_diff."""
    fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(11, 4.5))
    fig.suptitle("Analysis 2 — MAC Cell DC Transfer Curve", y=1.01)

    vcm   = 0.9
    vinp  = df.iloc[:, 0].values
    i_out = df.iloc[:, 1].values
    vdiff = (vinp - vcm) * 1e3     # V → mV
    i_ua  = i_out * 1e6            # A → µA

    # ── Panel A: transfer curve ───────────────────────────────────────────
    ax0.plot(vdiff, i_ua, color=BLUE, zorder=3)
    ax0.axvline(0, color=GRAY, lw=0.8, ls='--', zorder=2)
    ax0.axhline(0, color=GRAY, lw=0.8, ls='--', zorder=2)

    # Saturation annotations
    i_hi = i_ua.max()
    i_lo = i_ua.min()
    for val, vd, dy in [(i_hi, vdiff[-10], -18), (i_lo, vdiff[10], 12)]:
        ax0.annotate(f'{val:+.1f} µA', xy=(vd, val),
                     xytext=(0, dy), textcoords='offset points',
                     fontsize=8, color=BLUE, ha='center',
                     arrowprops=dict(arrowstyle='->', color=BLUE, lw=0.7))

    ax0.set_xlabel("V_diff  =  V_inp − V_cm  (mV)")
    ax0.set_ylabel("I_out  (µA)")
    ax0.set_title("Output Current")

    # ── Panel B: transconductance gm ─────────────────────────────────────
    vdiff_v = vinp - vcm                             # in V for derivative
    gm_mav  = np.gradient(i_out, vdiff_v) * 1e3     # A/V → mA/V

    ax1.plot(vdiff, gm_mav, color=GREEN, zorder=3)

    peak_idx = int(np.argmax(gm_mav))
    gm_peak  = gm_mav[peak_idx]
    ax1.annotate(f'gm_peak = {gm_peak:.2f} mA/V',
                 xy=(vdiff[peak_idx], gm_peak),
                 xytext=(20, -28), textcoords='offset points',
                 fontsize=8.5, color=GREEN,
                 arrowprops=dict(arrowstyle='->', color=GREEN, lw=0.8),
                 bbox=dict(boxstyle='round,pad=0.25', fc='white', alpha=0.9))

    ax1.set_xlabel("V_diff  =  V_inp − V_cm  (mV)")
    ax1.set_ylabel("gm  =  dI_out / dV_diff  (mA/V)")
    ax1.set_title("Transconductance")

    plt.tight_layout()
    out = plot_dir / 'a2_transfer_curve.png'
    fig.savefig(out)
    print(f"  Saved: {out}")
    plt.close(fig)


# ── Analysis 3: Transient Step Response ───────────────────────────────────

def plot_step_response(df: pd.DataFrame, plot_dir: Path) -> None:
    """Two stacked panels sharing the time axis: V_inp and I_out vs time."""
    fig, (ax_v, ax_i) = plt.subplots(2, 1, figsize=(9, 6.5), sharex=True)
    fig.suptitle("Analysis 3 — Transient Input Step Response", y=1.01)

    time  = df.iloc[:, 0].values * 1e9    # s → ns
    vinp  = df.iloc[:, 1].values * 1e3    # V → mV
    i_out = df.iloc[:, 2].values * 1e6    # A → µA

    # ── V_inp ─────────────────────────────────────────────────────────────
    ax_v.plot(time, vinp, color=BLUE, zorder=3)
    ax_v.set_ylabel("V_inp  (mV)")
    ax_v.set_title("Input Voltage")

    vcm_mv   = float(np.median(vinp))
    step_mv  = vinp.max() - vcm_mv
    step_idx = int(np.argmax(np.diff(vinp)))
    t_step   = time[step_idx]

    if step_mv > 1:
        ax_v.annotate(f'+{step_mv:.0f} mV step\nat t = {t_step:.0f} ns',
                      xy=(t_step, vinp[step_idx + 1]),
                      xytext=(18, 8), textcoords='offset points',
                      fontsize=8, color=BLUE,
                      arrowprops=dict(arrowstyle='->', color=BLUE, lw=0.7))

    # ── I_out ─────────────────────────────────────────────────────────────
    ax_i.plot(time, i_out, color=GREEN, zorder=3)
    ax_i.axhline(0, color=GRAY, lw=0.8, ls='--', zorder=2)
    ax_i.set_xlabel("Time  (ns)")
    ax_i.set_ylabel("I_out  (µA)")
    ax_i.set_title("Output Current")

    # Estimate 10–90% rise time from step onset
    if step_idx > 5 and step_idx + 40 < len(i_out):
        i_lo_val  = float(np.mean(i_out[max(0, step_idx - 10):step_idx]))
        i_hi_val  = float(np.mean(i_out[step_idx + 30:step_idx + 60]))
        swing     = i_hi_val - i_lo_val
        if abs(swing) > 0.05:
            t10 = next((time[step_idx + j]
                        for j, v in enumerate(i_out[step_idx:])
                        if (v - i_lo_val) >= 0.10 * swing), None)
            t90 = next((time[step_idx + j]
                        for j, v in enumerate(i_out[step_idx:])
                        if (v - i_lo_val) >= 0.90 * swing), None)
            if t10 and t90:
                tr = t90 - t10
                ax_i.axvline(t90, color=RED, lw=0.9, ls=':', alpha=0.8)
                ax_i.text(t90 + 1, i_lo_val + 0.7 * swing,
                          f't_rise\n(10–90%)\n≈ {tr:.1f} ns',
                          fontsize=7.5, color=RED, va='center')

    plt.tight_layout()
    out = plot_dir / 'a3_step_response.png'
    fig.savefig(out)
    print(f"  Saved: {out}")
    plt.close(fig)


# ── Analysis 4: Hebbian Weight Write ──────────────────────────────────────

def plot_weight_write(df: pd.DataFrame, plot_dir: Path) -> None:
    """Two stacked panels: Vw and V_we vs time."""
    fig, (ax_w, ax_we) = plt.subplots(2, 1, figsize=(9, 6.5), sharex=True)
    fig.suptitle("Analysis 4 — Hebbian Weight Write  (Charge Retention)", y=1.01)

    time = df.iloc[:, 0].values * 1e6    # s → µs
    vw   = df.iloc[:, 1].values * 1e3    # V → mV
    v_we = df.iloc[:, 2].values          # V (digital signal)

    # ── Vw ────────────────────────────────────────────────────────────────
    ax_w.plot(time, vw, color=PURPLE, zorder=3)
    ax_w.set_ylabel("Vw  (mV)")
    ax_w.set_title("Weight Voltage  (stored on Cw = 200 fF)")

    # Before/after reference lines and ΔVw annotation
    mask_pre  = time < 4.5
    mask_post = time > 5.5                        # post-pulse: after 5µs+pulse
    vw_pre  = float(vw[mask_pre].mean())  if mask_pre.any()  else float(vw[0])
    vw_post = float(vw[mask_post].mean()) if mask_post.any() else float(vw[-1])
    delta   = vw_post - vw_pre

    ax_w.axhline(vw_pre,  color=GRAY,   lw=0.9, ls='--', alpha=0.8,
                 label=f'Before: {vw_pre:.2f} mV')
    ax_w.axhline(vw_post, color=PURPLE, lw=0.9, ls='--', alpha=0.7,
                 label=f'After:  {vw_post:.2f} mV')
    ax_w.legend(loc='lower right')

    # Double-headed arrow for ΔVw — place in the post-pulse region
    t_arrow = time[int(len(time) * 0.75)]
    ax_w.annotate('', xy=(t_arrow, vw_post), xytext=(t_arrow, vw_pre),
                  arrowprops=dict(arrowstyle='<->', color=RED, lw=1.3))
    ax_w.text(t_arrow * 1.05, (vw_pre + vw_post) / 2,
              f'ΔVw = {delta:+.2f} mV',
              fontsize=8.5, color=RED, va='center',
              bbox=dict(boxstyle='round,pad=0.2', fc='white', alpha=0.85))

    # ── V_we ─────────────────────────────────────────────────────────────
    ax_we.fill_between(time, 0, v_we, color=GREEN, alpha=0.18, zorder=2)
    ax_we.plot(time, v_we, color=GREEN, lw=1.4, zorder=3, label='V_we')
    ax_we.set_ylim(-0.15, 2.15)
    ax_we.set_yticks([0, 1.8])
    ax_we.set_yticklabels(['0 V  (hold)', '1.8 V  (write)'])
    ax_we.set_xlabel("Time  (µs)")
    ax_we.set_ylabel("V_we  (V)")
    ax_we.set_title("Write Enable  (gates MN4 access transistor)")

    # Label the pulse width
    we_high = v_we > 0.9
    if we_high.any():
        t_start = float(time[np.argmax(we_high)])
        t_end   = float(time[len(time) - 1 - np.argmax(we_high[::-1])])
        pw_us   = t_end - t_start
        pw_lbl  = f'{pw_us * 1e3:.1f} ns' if pw_us < 0.1 else f'{pw_us:.2f} µs'
        ax_we.annotate('', xy=(t_end, 1.0), xytext=(t_start, 1.0),
                       arrowprops=dict(arrowstyle='<->', color=GREEN, lw=1.1))
        ax_we.text(t_end * 1.05, 1.15, f'WE pulse = {pw_lbl}',
                   ha='left', fontsize=8, color=GREEN)

    plt.tight_layout()
    out = plot_dir / 'a4_weight_write.png'
    fig.savefig(out)
    print(f"  Saved: {out}")
    plt.close(fig)


# ── Summary: all analyses on one page ─────────────────────────────────────

def plot_summary(df2: Optional[pd.DataFrame],
                 df3: Optional[pd.DataFrame],
                 df4: Optional[pd.DataFrame],
                 plot_dir: Path) -> None:
    """5-panel summary figure combining all analyses."""
    fig = plt.figure(figsize=(15, 9))
    fig.suptitle(
        "PCN MAC Cell — Simulation Summary  "
        "(SkyWater Sky130A, 130 nm, VDD = 1.8 V, Vw = 0.75 V)",
        fontsize=12, fontweight='bold', y=1.01)

    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.5, wspace=0.38)

    # ── A2a: transfer curve ───────────────────────────────────────────────
    ax0 = fig.add_subplot(gs[0, 0])
    ax0.set_title("A2: Transfer Curve")
    ax0.set_xlabel("V_diff (mV)")
    ax0.set_ylabel("I_out (µA)")
    if df2 is not None:
        vcm   = 0.9
        vdiff = (df2.iloc[:, 0].values - vcm) * 1e3
        i_ua  = df2.iloc[:, 1].values * 1e6
        ax0.plot(vdiff, i_ua, color=BLUE, lw=1.6)
        ax0.axvline(0, color=GRAY, lw=0.7, ls='--')
        ax0.axhline(0, color=GRAY, lw=0.7, ls='--')
    else:
        ax0.text(0.5, 0.5, 'no data', ha='center', va='center',
                 color=GRAY, transform=ax0.transAxes)

    # ── A2b: transconductance ─────────────────────────────────────────────
    ax1 = fig.add_subplot(gs[0, 1])
    ax1.set_title("A2: Transconductance  gm")
    ax1.set_xlabel("V_diff (mV)")
    ax1.set_ylabel("gm (mA/V)")
    if df2 is not None:
        vcm   = 0.9
        vdiff = (df2.iloc[:, 0].values - vcm) * 1e3
        gm    = np.gradient(df2.iloc[:, 1].values,
                            df2.iloc[:, 0].values - vcm) * 1e3
        ax1.plot(vdiff, gm, color=GREEN, lw=1.6)
        gm_pk = gm.max()
        ax1.text(0.97, 0.95, f'peak: {gm_pk:.2f} mA/V',
                 ha='right', va='top', transform=ax1.transAxes,
                 fontsize=8, color=GREEN,
                 bbox=dict(boxstyle='round,pad=0.2', fc='white', alpha=0.85))
    else:
        ax1.text(0.5, 0.5, 'no data', ha='center', va='center',
                 color=GRAY, transform=ax1.transAxes)

    # ── A4: weight write (spans both rows of col 2) ───────────────────────
    ax4 = fig.add_subplot(gs[:, 2])
    ax4.set_title("A4: Hebbian Weight Write")
    ax4.set_xlabel("Time (µs)")
    ax4.set_ylabel("Vw (mV)", color=PURPLE)
    ax4.tick_params(axis='y', colors=PURPLE)
    if df4 is not None:
        time4 = df4.iloc[:, 0].values * 1e6
        vw    = df4.iloc[:, 1].values * 1e3
        v_we  = df4.iloc[:, 2].values

        ax4.plot(time4, vw, color=PURPLE, lw=1.6, label='Vw')

        ax4r = ax4.twinx()
        ax4r.fill_between(time4, 0, v_we, color=GREEN, alpha=0.12)
        ax4r.plot(time4, v_we, color=GREEN, lw=0.9, ls='--',
                  alpha=0.7, label='V_we')
        ax4r.set_ylim(-0.1, 2.6)
        ax4r.set_yticks([0, 1.8])
        ax4r.set_yticklabels(['0', '1.8V'], fontsize=8, color=GREEN)
        ax4r.tick_params(axis='y', colors=GREEN)
        ax4r.spines['right'].set_visible(True)

        mask_pre  = time4 < 4.5
        mask_post = time4 > 5.5
        vw_pre  = float(vw[mask_pre].mean())  if mask_pre.any()  else float(vw[0])
        vw_post = float(vw[mask_post].mean()) if mask_post.any() else float(vw[-1])
        dv      = vw_post - vw_pre

        ax4.axhline(vw_pre,  color=GRAY,   lw=0.7, ls=':')
        ax4.axhline(vw_post, color=PURPLE, lw=0.7, ls=':')
        ax4.text(0.97, 0.5, f'ΔVw\n= {dv:+.2f} mV',
                 ha='right', va='center', transform=ax4.transAxes,
                 fontsize=9, color=PURPLE,
                 bbox=dict(boxstyle='round,pad=0.3', fc='white', alpha=0.9))

        h1, l1 = ax4.get_legend_handles_labels()
        h2, l2 = ax4r.get_legend_handles_labels()
        ax4.legend(h1 + h2, l1 + l2, loc='upper left', fontsize=8)
    else:
        ax4.text(0.5, 0.5, 'no data', ha='center', va='center',
                 color=GRAY, transform=ax4.transAxes)

    # ── A3a: I_out step response ──────────────────────────────────────────
    ax2 = fig.add_subplot(gs[1, 0])
    ax2.set_title("A3: Step Response  (I_out)")
    ax2.set_xlabel("Time (ns)")
    ax2.set_ylabel("I_out (µA)")
    if df3 is not None:
        t3    = df3.iloc[:, 0].values * 1e9
        i_out = df3.iloc[:, 2].values * 1e6
        ax2.plot(t3, i_out, color=GREEN, lw=1.6)
        ax2.axhline(0, color=GRAY, lw=0.7, ls='--')
    else:
        ax2.text(0.5, 0.5, 'no data', ha='center', va='center',
                 color=GRAY, transform=ax2.transAxes)

    # ── A3b: V_inp step ───────────────────────────────────────────────────
    ax3 = fig.add_subplot(gs[1, 1])
    ax3.set_title("A3: Step Response  (V_inp)")
    ax3.set_xlabel("Time (ns)")
    ax3.set_ylabel("V_inp (mV)")
    if df3 is not None:
        t3   = df3.iloc[:, 0].values * 1e9
        vinp = df3.iloc[:, 1].values * 1e3
        ax3.plot(t3, vinp, color=BLUE, lw=1.6)
    else:
        ax3.text(0.5, 0.5, 'no data', ha='center', va='center',
                 color=GRAY, transform=ax3.transAxes)

    out = plot_dir / 'summary.png'
    fig.savefig(out)
    print(f"  Saved: {out}")
    plt.close(fig)


# ── Main ───────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot PCN MAC cell SPICE simulation CSV results.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 plot_results.py
  python3 plot_results.py --sim-dir /path/to/output
  python3 plot_results.py --show
  python3 plot_results.py --no-summary
""")
    parser.add_argument(
        '--sim-dir', default='output',
        help='Directory containing simulation CSV files (default: output/)')
    parser.add_argument(
        '--plot-dir', default=None,
        help='Directory for PNG plots (default: <sim-dir>/plots/)')
    parser.add_argument(
        '--no-summary', action='store_true',
        help='Skip the combined 5-panel summary figure')
    parser.add_argument(
        '--show', action='store_true',
        help='Display plots interactively after saving')
    args = parser.parse_args()

    sim_dir  = Path(args.sim_dir)
    plot_dir = Path(args.plot_dir) if args.plot_dir else sim_dir / 'plots'

    if not sim_dir.exists():
        print(f"Error: simulation directory not found: {sim_dir}")
        print("Run ./run_sim.sh first to generate simulation output.")
        sys.exit(1)

    plot_dir.mkdir(parents=True, exist_ok=True)

    print(f"Input:   {sim_dir}/")
    print(f"Output:  {plot_dir}/")
    print()

    # ── Load ──────────────────────────────────────────────────────────────
    # ngspice wrdata writes (x,y) pairs per vector, producing 2N cols per row.
    # It also writes N+1 "blocks" (repeats of the data); the LAST block is
    # always the correct, most-recent analysis result.  Blocks are detected
    # by finding where the x-axis (col 0) decreases (resets to start value).
    def _last_block(df):
        if df is None or len(df) == 0:
            return df
        x = df.iloc[:, 0].values
        restarts = np.where(np.diff(x) < 0)[0] + 1
        if len(restarts) == 0:
            return df
        return df.iloc[int(restarts[-1]):].reset_index(drop=True)

    def _pick(df, cols, names):
        if df is None or df.shape[1] < max(cols) + 1:
            return df
        d = df.iloc[:, cols].copy()
        d.columns = names
        return d

    df2 = _last_block(load_csv(sim_dir / 'a2_transfer.csv'))
    df2 = _pick(df2, [0, 3], ['vinp', 'i_out'])

    df3 = _last_block(load_csv(sim_dir / 'a3_step.csv'))
    df3 = _pick(df3, [0, 3, 5], ['time', 'vinp', 'i_out'])

    df4 = _last_block(load_csv(sim_dir / 'a4_write.csv'))
    df4 = _pick(df4, [0, 3, 5], ['time', 'vw', 'v_we'])

    n_loaded = sum(d is not None for d in [df2, df3, df4])
    print(f"Loaded {n_loaded}/3 datasets\n")

    if n_loaded == 0:
        print("Nothing to plot.  Has run_sim.sh completed successfully?")
        sys.exit(1)

    # ── Individual plots ──────────────────────────────────────────────────
    if df2 is not None:
        print("Plotting A2: Transfer Curve + Transconductance ...")
        plot_transfer_curve(df2, plot_dir)

    if df3 is not None:
        print("Plotting A3: Transient Step Response ...")
        plot_step_response(df3, plot_dir)

    if df4 is not None:
        print("Plotting A4: Hebbian Weight Write ...")
        plot_weight_write(df4, plot_dir)

    # ── Summary ───────────────────────────────────────────────────────────
    if not args.no_summary:
        print("Plotting summary (all analyses) ...")
        plot_summary(df2, df3, df4, plot_dir)

    # ── Interactive display ────────────────────────────────────────────────
    if args.show:
        plt.show()

    print()
    print(f"Done.  {len(list(plot_dir.glob('*.png')))} PNG files in {plot_dir}/")


if __name__ == '__main__':
    main()

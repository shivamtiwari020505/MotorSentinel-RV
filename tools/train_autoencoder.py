"""Train and quantize the EdgeMatrix-RV 16 -> 8 -> 16 autoencoder.

Offline tool: it needs NumPy, but its output is a pure-integer JSON model that
the standard-library reference model and the RTL consume. Training is seeded
and deterministic, so the committed model can be regenerated exactly.

Steps:
1. simulate healthy motors with randomized speed, load, noise and mounting tilt;
2. extract bit-exact features and calibrate per-feature INT8 normalization;
3. train a ReLU autoencoder initialized from a sign-split PCA solution;
4. post-training-quantize weights, biases and shifts to the hardware contract;
5. set the anomaly threshold from held-out healthy windows only.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import sys

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from model.edgematrix import (  # noqa: E402
    DEFAULT_MODEL_PATH,
    HIDDEN,
    INPUTS,
    MAX_NORM_SHIFT,
    QuantizedModel,
    image_crc,
    infer,
    model_image,
    normalize,
    save_model,
)
from model.features import FEATURE_NAMES, extract_overlapping  # noqa: E402
from model.motor_sim import XorShift32, healthy_profile, simulate  # noqa: E402

RUN_SAMPLES = 2048
TRAIN_SEED_BASE = 1000
VALIDATION_SEED_BASE = 5000


def healthy_windows(seed_base: int, runs: int) -> list[tuple[int, ...]]:
    windows: list[tuple[int, ...]] = []
    for run in range(runs):
        seed = seed_base + run
        profile = healthy_profile(XorShift32(seed ^ 0x9E3779B9))
        windows += extract_overlapping(simulate(RUN_SAMPLES, seed, profile))
    return windows


def calibrate_normalization(features: np.ndarray, counts_per_sigma: float):
    mean = features.mean(axis=0)
    std = features.std(axis=0)
    offsets, scales, shifts = [], [], []
    for index in range(INPUTS):
        if index < 3:  # signed axis means: absolute floor of 8 LSB (31 mg)
            floor = 8.0
        elif 9 <= index <= 11:  # zero-crossing counts
            floor = 2.0
        else:  # energies and peak-to-peak: at least +/-10 % is one sigma
            floor = 0.10 * abs(mean[index]) + 1.0
        sigma = max(float(std[index]), floor)
        gain = counts_per_sigma / sigma
        shift = int(math.floor(math.log2(32767.0 / gain)))
        shift = max(0, min(MAX_NORM_SHIFT, shift))
        scale = int(round(gain * (1 << shift)))
        scale = max(-32768, min(32767, scale))
        offsets.append(int(round(float(mean[index]))))
        scales.append(scale)
        shifts.append(shift)
    return tuple(offsets), tuple(scales), tuple(shifts)


def train_float(q: np.ndarray, seed: int, steps: int):
    rng = np.random.default_rng(seed)
    centered = q - q.mean(axis=0)
    _, _, vt = np.linalg.svd(centered, full_matrices=False)
    components = vt[: HIDDEN // 2]

    # Sign-split PCA: [v, -v] through ReLU reproduces the linear projection
    # exactly, giving a strong deterministic starting point.
    w1 = np.zeros((HIDDEN, INPUTS))
    w2 = np.zeros((INPUTS, HIDDEN))
    for k, vector in enumerate(components):
        w1[2 * k] = vector
        w1[2 * k + 1] = -vector
        w2[:, 2 * k] = vector
        w2[:, 2 * k + 1] = -vector
    mean_q = q.mean(axis=0)
    b1 = -(w1 @ mean_q)
    b2 = mean_q.copy()
    w1 += 0.01 * rng.standard_normal(w1.shape)

    params = [w1, b1, w2, b2]
    moments = [np.zeros_like(p) for p in params]
    velocities = [np.zeros_like(p) for p in params]
    rate, beta1, beta2 = 2e-3, 0.9, 0.999
    count = q.shape[0]
    for step in range(1, steps + 1):
        pre = q @ w1.T + b1
        hidden = np.maximum(pre, 0.0)
        out = hidden @ w2.T + b2
        error = out - q
        grad_out = 2.0 * error / count
        grad_w2 = grad_out.T @ hidden
        grad_b2 = grad_out.sum(axis=0)
        grad_hidden = (grad_out @ w2) * (pre > 0)
        grad_w1 = grad_hidden.T @ q
        grad_b1 = grad_hidden.sum(axis=0)
        grads = [grad_w1, grad_b1, grad_w2, grad_b2]
        for index, (param, grad) in enumerate(zip(params, grads)):
            moments[index] = beta1 * moments[index] + (1 - beta1) * grad
            velocities[index] = beta2 * velocities[index] + (1 - beta2) * grad**2
            m_hat = moments[index] / (1 - beta1**step)
            v_hat = velocities[index] / (1 - beta2**step)
            param -= rate * m_hat / (np.sqrt(v_hat) + 1e-8)
    hidden = np.maximum(q @ w1.T + b1, 0.0)
    return w1, b1, w2, b2, hidden


def bound_latent(w1, b1, w2, hidden, latent_peak: float):
    """Rescale each hidden unit so its healthy peak is ``latent_peak`` counts.

    ReLU is positive-homogeneous, so scaling a unit's input weights by k and
    its output weights by 1/k leaves the float network unchanged. With the
    hidden layer then read as raw INT8 counts, sat8 caps every unit just above
    its healthy range: the decoder cannot extrapolate along healthy directions,
    so far-out windows (for example a 3x imbalance) stay unreconstructable.
    """

    w1, b1, w2 = w1.copy(), b1.copy(), w2.copy()
    for unit in range(HIDDEN):
        peak = float(hidden[:, unit].max())
        if peak <= 1e-6:
            continue
        gain = latent_peak / peak
        w1[unit] *= gain
        b1[unit] *= gain
        w2[:, unit] /= gain
    return w1, b1, w2


def quantize(w1, b1, w2, b2, offsets, scales, shifts) -> QuantizedModel:
    a = int(math.floor(math.log2(127.0 / np.abs(w1).max())))
    c = 0  # bound_latent already places hidden values in INT8 counts
    d = int(math.floor(math.log2(127.0 / np.abs(w2).max())))
    s1 = a - c
    s2 = d + c
    if s1 < 0 or s2 < 0:
        raise RuntimeError(f"unrepresentable scales a={a} c={c} d={d}")

    def q8(matrix: np.ndarray, exponent: int):
        values = np.clip(np.rint(matrix * (2.0**exponent)), -128, 127)
        return tuple(tuple(int(v) for v in row) for row in values)

    return QuantizedModel(
        offset=offsets,
        scale=scales,
        norm_shift=shifts,
        w1=q8(w1, a),
        b1=tuple(int(round(v * 2.0**a)) for v in b1),
        w2=q8(w2, d),
        b2=tuple(int(round(v * 2.0 ** (d + c))) for v in b2),
        s1=s1,
        s2=s2,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_MODEL_PATH)
    parser.add_argument("--train-runs", type=int, default=96)
    parser.add_argument("--validation-runs", type=int, default=32)
    parser.add_argument("--steps", type=int, default=4000)
    parser.add_argument("--counts-per-sigma", type=float, default=8.0)
    parser.add_argument("--latent-peak", type=float, default=100.0)
    args = parser.parse_args()

    train = healthy_windows(TRAIN_SEED_BASE, args.train_runs)
    validation = healthy_windows(VALIDATION_SEED_BASE, args.validation_runs)
    offsets, scales, shifts = calibrate_normalization(
        np.array(train, dtype=float), args.counts_per_sigma
    )

    staging = QuantizedModel(
        offset=offsets, scale=scales, norm_shift=shifts,
        w1=((0,) * INPUTS,) * HIDDEN, b1=(0,) * HIDDEN,
        w2=((0,) * HIDDEN,) * INPUTS, b2=(0,) * INPUTS, s1=0, s2=0,
    )
    q_train = np.array([normalize(staging, f) for f in train], dtype=float)
    w1, b1, w2, b2, hidden = train_float(q_train, seed=7, steps=args.steps)
    w1, b1, w2 = bound_latent(w1, b1, w2, hidden, args.latent_peak)
    model = quantize(w1, b1, w2, b2, offsets, scales, shifts)

    train_scores = [infer(model, f).score for f in train]
    validation_scores = [infer(model, f).score for f in validation]
    # Threshold from held-out healthy data only: 50 % margin above the worst
    # healthy window, plus a small absolute guard band.
    threshold = int(math.ceil(1.5 * max(validation_scores))) + 8
    model = QuantizedModel(**{**model.__dict__, "threshold": threshold})

    metadata = {
        "generator": "tools/train_autoencoder.py",
        "train_windows": len(train),
        "validation_windows": len(validation),
        "train_score_max": max(train_scores),
        "validation_score_max": max(validation_scores),
        "validation_score_mean": round(sum(validation_scores) / len(validation_scores), 2),
        "feature_names": list(FEATURE_NAMES),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    save_model(model, args.output, metadata)
    print(f"wrote {args.output}")
    print(f"train windows={len(train)} validation windows={len(validation)}")
    print(f"s1={model.s1} s2={model.s2} threshold={threshold}")
    print(f"healthy score max train={max(train_scores)} validation={max(validation_scores)}")
    print(f"image CRC-32=0x{image_crc(model_image(model)):08x}")


if __name__ == "__main__":
    main()

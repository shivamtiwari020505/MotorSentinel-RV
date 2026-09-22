"""Bit-exact reference models for MotorSentinel-RV."""

from .features import (
    AXES,
    FEATURE_COUNT,
    FEATURE_NAMES,
    HOP_SIZE,
    WINDOW_SIZE,
    extract_features,
    extract_overlapping,
)

__all__ = [
    "AXES",
    "FEATURE_COUNT",
    "FEATURE_NAMES",
    "HOP_SIZE",
    "WINDOW_SIZE",
    "extract_features",
    "extract_overlapping",
]

"""scipy.signal stand-in: butter, zpk2sos, sosfilt, sosfilt_zi, sosfiltfilt, lfilter, lfilter_zi.

Filter *design* is numpy (a port of SciPy's butter/zpk2sos pipeline, BSD-3-Clause, same section order so
results match to float64 rounding). Filtering runs in libSafariumRaster: direct form II transposed with explicit
state (`zi` in, final state out), so block-by-block use carries state across blocks and never lowers precision.
"""
from ._design import butter, zpk2sos, buttap, bilinear_zpk, zpk2tf
from ._filt import lfilter, lfilter_zi, sosfilt, sosfilt_zi, sosfiltfilt

__all__ = ["butter", "zpk2sos", "buttap", "bilinear_zpk", "zpk2tf",
           "lfilter", "lfilter_zi", "sosfilt", "sosfilt_zi", "sosfiltfilt"]

"""Hidden self-test cases: they exercise the harness itself (RAM subprocess measurement, timing, UNSUPPORTED path, engine
labels). `ref` and `shim` are DIFFERENT functions wherever the test needs to detect swapped labels.
Run only through test_bench_raster.py or `bench_raster.py --area selftest`."""
from __future__ import annotations

import sys
import time

import numpy as np

from . import register

_KW = dict(area="selftest", variant="", family="py", hidden=True)


def _alloc(mb):
    def f(mod, x):
        a = np.ones(mb * 1024 * 1024 // 8, dtype=np.float64)   # touched pages: counts in RSS and footprint
        a[::512] = 2.0
        return np.full((4, 4), 1.0) if a[0] else None
    return f


def _sleeper(ms, mb=0):
    def f(mod, x):
        if mb:
            a = np.ones(mb * 1024 * 1024 // 8)
            a[::512] = 2.0
        time.sleep(ms / 1000.0)
        return np.full((8, 8), 1.0)
    return f


def _noop(mod, x):
    return None


def _needs_missing(mod, x):
    return mod.this_function_does_not_exist(x)


def _hang(mod, x):
    time.sleep(120)


def _noisy(mod, x):
    sys.stderr.write("x" * 300_000 + "\n")     # more than a 64 KB pipe buffer per call
    sys.stderr.flush()
    sys.stdout.write("noise " * 50_000 + "\n")   # stdout noise that is not a JSON line
    sys.stdout.flush()


def _transient_input(rng):
    big = np.ones(300 * 1024 * 1024 // 8)       # an import-like transient: raises lifetime peak, freed before the op
    big[::512] = 3.0
    del big
    return {}


register(op="alloc200", make_input=lambda rng: {}, ref=_alloc(200), **_KW)
register(op="noop", make_input=lambda rng: {}, ref=_noop, **_KW)
register(op="sleep2ms", make_input=lambda rng: {}, ref=_sleeper(2), **_KW)
register(op="needs_missing_fn", make_input=lambda rng: {}, ref=_needs_missing, requires=("this_function_does_not_exist",), **_KW)
register(op="hang", make_input=lambda rng: {}, ref=_hang, **_KW)
register(op="noisy", make_input=lambda rng: {}, ref=_noisy, **_KW)
register(op="transient50", make_input=_transient_input, ref=_alloc(50), **_KW)
register(op="engine_probe", make_input=lambda rng: {}, ref=lambda m, x: np.full((4, 4), 1.0),
         shim=lambda m, x: np.full((4, 4), 2.0), **_KW)
# shim function is faster (2 ms vs 8 ms) and lighter (10 MB vs 120 MB) with identical output: swapped labels => LOSS
register(op="ab", make_input=lambda rng: {}, ref=_sleeper(8, 120), shim=_sleeper(2, 10), metric="numeric", **_KW)

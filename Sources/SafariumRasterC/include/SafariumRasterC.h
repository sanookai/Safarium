// SafariumRasterC — small C/NEON kernels for hot paths where Swift SIMD loses to libjpeg-turbo/OpenCV.
// Pick approved 2026-11-24. Apple toolchain only; no third-party code linked. Each kernel's owner is
// listed in docs/raster-plan.md (area ownership). Headers per area: include/sr_<area>.h.
#ifndef SAFARIUM_RASTER_C_H
#define SAFARIUM_RASTER_C_H
#include <stdint.h>
#include <stddef.h>

/// ABI version of the C kernels (bump on breaking change).
int32_t src_kernels_version(void);

#include "sr_core.h"   // core-numeric NEON kernels (core area)
#include "sr_jpeg.h"   // JPEG baseline encoder kernels (IO area)
#include "sr_linalg.h" // Accelerate BLAS/LAPACK + k-means kernels (Phase 2)
#include "sr_ops.h"    // Phase 3 imgproc filter/color C kernels

#endif

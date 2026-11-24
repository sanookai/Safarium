"""cv2-compatible shim backed by Safarium's libSafariumRaster (Apple frameworks, no OpenCV, no FFmpeg).

Only the subset the Sompong reel pipeline uses. Contract: Projects/Safarium/docs/raster-plan.md
Area ownership: _constants/_numpy_ops (numpy agent), _draw (draw agent), _ops (image-ops agent), _io (IO+video agent).
"""
from ._lib import error  # noqa: F401
from ._constants import *  # noqa: F401,F403
from ._numpy_ops import *  # noqa: F401,F403
from ._core import *  # noqa: F401,F403  (phase 1: core-numeric)
from ._linalg import *  # noqa: F401,F403  (phase 2: linalg + transforms)
from ._draw import *  # noqa: F401,F403
from ._ops import *  # noqa: F401,F403
from ._io import *  # noqa: F401,F403
from ._videoio import *  # noqa: F401,F403  (phase 6: wins over _io's VideoCapture)
from ._gpu import *  # noqa: F401,F403  (opt-in Metal paths; off by default)
from . import utils  # noqa: F401

__version__ = "safarium-raster-0.1"

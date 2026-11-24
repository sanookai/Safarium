"""cv2.utils.logging for the Safarium shim (Area D).

The shim has no native log stream, so the level is only remembered; values match OpenCV's LogLevel enum.
Default = WARNING (3), as OpenCV's release builds.
"""

LOG_LEVEL_SILENT = 0
LOG_LEVEL_FATAL = 1
LOG_LEVEL_ERROR = 2
LOG_LEVEL_WARNING = 3
LOG_LEVEL_INFO = 4
LOG_LEVEL_DEBUG = 5
LOG_LEVEL_VERBOSE = 6

_level = LOG_LEVEL_WARNING

__all__ = [
    "LOG_LEVEL_SILENT", "LOG_LEVEL_FATAL", "LOG_LEVEL_ERROR", "LOG_LEVEL_WARNING", "LOG_LEVEL_INFO",
    "LOG_LEVEL_DEBUG", "LOG_LEVEL_VERBOSE", "getLogLevel", "setLogLevel",
]


def getLogLevel() -> int:
    return _level


def setLogLevel(level) -> int:
    """Set the level; returns the previous one (as cv::utils::logging::setLogLevel does)."""
    global _level
    previous, _level = _level, int(level)
    return previous

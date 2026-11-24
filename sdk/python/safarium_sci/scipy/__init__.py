"""Safarium stand-in for the parts of SciPy the Sompong pipeline uses (Area E of SafariumRaster).

Sub-packages: io (netcdf_file, wavfile), signal (butter, sosfilt, sosfiltfilt, lfilter, ...), ndimage (minimum_filter1d).
The heavy numeric loops run in libSafariumRaster (Accelerate-era Swift); filter design, file formats and glue are numpy.
Algorithms follow SciPy's (BSD-3-Clause) reference behaviour; origin notes sit next to the ported pieces.
"""
__version__ = "1.18.1+safarium"

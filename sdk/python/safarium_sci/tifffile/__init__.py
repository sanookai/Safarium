"""Safarium stand-in for the parts of `tifffile` the Sompong pipeline uses (Area E of SafariumRaster).

Reads classic TIFF and BigTIFF (tiles or strips, chunky samples, uint/int/float 8-64 bit, compression none / deflate /
PackBits, predictors 2 and 3, any byte order) incl. GeoTIFF tags by name, from a path, a file object or bytes; works
on header-only prefixes of cloud-optimised GeoTIFFs. Writes classic TIFF (tiles or strips, none / deflate, predictor 2,
multi-page, extra tags). Pure Python + numpy + zlib: pixel data moves as bytes, there is no numeric loop to offload.
Not supported (raises NotImplementedError): LZW, JPEG, planar-separate layout, sub-byte samples.
"""
from ._tiff import (COMPRESSION, PHOTOMETRIC, TiffFile, TiffFileError, TiffPage, TiffPages, TiffTag, TiffTags,
                    TiffWriter, imread, imwrite)

__version__ = "2026.11.16+safarium"
__all__ = ["COMPRESSION", "PHOTOMETRIC", "TiffFile", "TiffFileError", "TiffPage", "TiffPages", "TiffTag", "TiffTags",
           "TiffWriter", "imread", "imwrite"]

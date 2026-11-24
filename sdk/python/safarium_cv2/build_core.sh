#!/bin/sh
# Builds cv2/_srcore (CPython extension, METH_FASTCALL bridge for the core-numeric functions of libSafariumRaster) with clang only.
# No setuptools/pip, nothing is installed: the .so is written next to _srcore.c.
#   PYTHON=/path/to/python3.12 ./build_core.sh      (default: python3.12 from PATH)
# If the build is not done (or fails) cv2 keeps working through the slower ctypes path; SAFARIUM_NO_SRCORE=1 forces that path.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
py=${PYTHON:-python3.12}
inc=$("$py" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
suffix=$("$py" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
out="$here/cv2/_srcore$suffix"
clang -O3 -ffp-contract=off -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type -Wno-missing-field-initializers -shared -fPIC -undefined dynamic_lookup \
  -I"$inc" "$here/cv2/_srcore.c" -o "$out"
echo "built $out"

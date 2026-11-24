"""scipy.io.netcdf_file stand-in: NetCDF classic (CDF-1) and 64-bit-offset (CDF-2) reader/writer.

Behaviour follows SciPy's `netcdf_file` (BSD-3-Clause): same attribute API (`f.title = ...`, `v.units = ...`), same
`variables` / `dimensions` dicts, same `mmap` semantics (read-only views of the file when mmap=True, private copies when
False), same byte layout when writing (files written here are byte-identical to SciPy's). Pure numpy/struct: this is
file I/O, not a numeric loop, so there is nothing for the Swift kernels to do.
"""
from __future__ import annotations

import mmap as mm
import warnings
import weakref
from functools import reduce
from operator import mul

import numpy as np
from numpy import little_endian as LITTLE_ENDIAN

__all__ = ["netcdf_file", "netcdf_variable"]

ABSENT = b"\x00" * 8
ZERO = b"\x00" * 4
NC_BYTE, NC_CHAR, NC_SHORT = b"\x00\x00\x00\x01", b"\x00\x00\x00\x02", b"\x00\x00\x00\x03"
NC_INT, NC_FLOAT, NC_DOUBLE = b"\x00\x00\x00\x04", b"\x00\x00\x00\x05", b"\x00\x00\x00\x06"
NC_DIMENSION, NC_VARIABLE, NC_ATTRIBUTE = b"\x00\x00\x00\n", b"\x00\x00\x00\x0b", b"\x00\x00\x00\x0c"
FILL_BYTE, FILL_CHAR, FILL_SHORT, FILL_INT = b"\x81", b"\x00", b"\x80\x01", b"\x80\x00\x00\x01"
FILL_FLOAT, FILL_DOUBLE = b"\x7C\xF0\x00\x00", b"\x47\x9E\x00\x00\x00\x00\x00\x00"

TYPEMAP = {NC_BYTE: ("b", 1), NC_CHAR: ("c", 1), NC_SHORT: ("h", 2), NC_INT: ("i", 4), NC_FLOAT: ("f", 4),
           NC_DOUBLE: ("d", 8)}
FILLMAP = {NC_BYTE: FILL_BYTE, NC_CHAR: FILL_CHAR, NC_SHORT: FILL_SHORT, NC_INT: FILL_INT, NC_FLOAT: FILL_FLOAT,
           NC_DOUBLE: FILL_DOUBLE}
REVERSE = {("b", 1): NC_BYTE, ("B", 1): NC_CHAR, ("c", 1): NC_CHAR, ("h", 2): NC_SHORT, ("i", 4): NC_INT,
           ("f", 4): NC_FLOAT, ("d", 8): NC_DOUBLE,
           ("l", 4): NC_INT, ("S", 1): NC_CHAR}


class netcdf_file:
    """Read/write a NetCDF-3 file: `netcdf_file(filename, mode='r', mmap=None, version=1, maskandscale=False)`."""

    def __init__(self, filename, mode="r", mmap=None, version=1, maskandscale=False):
        if mode not in "rwa":
            raise ValueError("Mode must be either 'r', 'w' or 'a'.")
        if hasattr(filename, "seek"):
            self.fp = filename
            self.filename = "None"
            if mmap is None:
                mmap = False
            elif mmap and not hasattr(filename, "fileno"):
                raise ValueError("Cannot use file object for mmap")
        else:
            self.filename = filename
            self.fp = open(self.filename, f"{'r+' if mode == 'a' else mode}b")
            if mmap is None:
                mmap = True
        if mode != "r":
            mmap = False
        self.use_mmap = mmap
        self.mode = mode
        self.version_byte = version
        self.maskandscale = maskandscale
        self.dimensions = {}
        self.variables = {}
        self._dims = []
        self._recs = 0
        self._recsize = 0
        self._mm = None
        self._mm_buf = None
        if self.use_mmap:
            self._mm = mm.mmap(self.fp.fileno(), 0, access=mm.ACCESS_READ)
            self._mm_buf = np.frombuffer(self._mm, dtype=np.int8)
        self._attributes = {}
        if mode in "ra":
            self._read()

    def __setattr__(self, attr, value):
        try:
            self._attributes[attr] = value
        except AttributeError:
            pass
        self.__dict__[attr] = value

    def close(self):
        if hasattr(self, "fp") and not self.fp.closed:
            try:
                self.flush()
            finally:
                self.variables = {}
                if self._mm_buf is not None:
                    ref = weakref.ref(self._mm_buf)
                    self._mm_buf = None
                    if ref() is None:
                        self._mm.close()
                    else:
                        warnings.warn(
                            "Cannot close a netcdf_file opened with mmap=True, when netcdf_variables or arrays "
                            "referring to its data still exist. All data arrays obtained from such files refer "
                            "directly to data on disk, and must be copied before the file can be cleanly closed.",
                            category=RuntimeWarning, stacklevel=2)
                self._mm = None
                self.fp.close()

    __del__ = close

    def __enter__(self):
        return self

    def __exit__(self, type, value, traceback):
        self.close()

    def createDimension(self, name, length):
        if length is None and self._dims:
            raise ValueError("Only first dimension may be unlimited!")
        self.dimensions[name] = length
        self._dims.append(name)

    def createVariable(self, name, type, dimensions):
        shape = tuple(self.dimensions[d] for d in dimensions)
        shape_ = tuple(d or 0 for d in shape)
        type = np.dtype(type)
        typecode, size = type.char, type.itemsize
        if (typecode, size) not in REVERSE:
            raise ValueError(f"NetCDF 3 does not support type {type}")
        data = np.empty(shape_, dtype=type.newbyteorder("B"))
        self.variables[name] = netcdf_variable(data, typecode, size, shape, dimensions,
                                               maskandscale=self.maskandscale)
        return self.variables[name]

    def flush(self):
        if hasattr(self, "mode") and self.mode in "wa":
            self._write()

    sync = flush

    # ---- writing ----
    def _write(self):
        self.fp.seek(0)
        self.fp.write(b"CDF")
        self.fp.write(np.array(self.version_byte, ">b").tobytes())
        for var in self.variables.values():
            if var.isrec and len(var.data) > self._recs:
                self.__dict__["_recs"] = len(var.data)
        self._pack_int(self._recs)
        if self.dimensions:
            self.fp.write(NC_DIMENSION)
            self._pack_int(len(self.dimensions))
            for name in self._dims:
                self._pack_string(name)
                self._pack_int(self.dimensions[name] or 0)
        else:
            self.fp.write(ABSENT)
        self._write_att_array(self._attributes)
        self._write_var_array()

    def _write_att_array(self, attributes):
        if attributes:
            self.fp.write(NC_ATTRIBUTE)
            self._pack_int(len(attributes))
            for name, values in attributes.items():
                self._pack_string(name)
                self._write_att_values(values)
        else:
            self.fp.write(ABSENT)

    def _write_var_array(self):
        if not self.variables:
            self.fp.write(ABSENT)
            return
        self.fp.write(NC_VARIABLE)
        self._pack_int(len(self.variables))

        def sortkey(n):
            v = self.variables[n]
            return (-1,) if v.isrec else v._shape

        order = sorted(self.variables, key=sortkey, reverse=True)
        for name in order:
            self._write_var_metadata(name)
        self.__dict__["_recsize"] = sum(v._vsize for v in self.variables.values() if v.isrec)
        for name in order:
            self._write_var_data(name)

    def _write_var_metadata(self, name):
        var = self.variables[name]
        self._pack_string(name)
        self._pack_int(len(var.dimensions))
        for dimname in var.dimensions:
            self._pack_int(self._dims.index(dimname))
        self._write_att_array(var._attributes)
        self.fp.write(REVERSE[var.typecode(), var.itemsize()])
        if not var.isrec:
            vsize = var.data.size * var.data.itemsize
            vsize += -vsize % 4
        else:
            try:
                vsize = var.data[0].size * var.data.itemsize
            except IndexError:
                vsize = 0
            if sum(1 for v in self.variables.values() if v.isrec) > 1:
                vsize += -vsize % 4
        var.__dict__["_vsize"] = vsize
        self._pack_int(vsize)
        var.__dict__["_begin"] = self.fp.tell()
        self._pack_begin(0)

    def _write_var_data(self, name):
        var = self.variables[name]
        begin = self.fp.tell()
        self.fp.seek(var._begin)
        self._pack_begin(begin)
        self.fp.seek(begin)
        if not var.isrec:
            self.fp.write(var.data.tobytes())
            self._write_var_padding(var, var._vsize - var.data.size * var.data.itemsize)
        else:
            if self._recs > len(var.data):
                shape = (self._recs,) + var.data.shape[1:]
                try:
                    var.data.resize(shape)
                except ValueError:
                    dt = var.data.dtype
                    var.__dict__["data"] = np.resize(var.data, shape).astype(dt)
            pos0 = pos = self.fp.tell()
            for rec in var.data:
                if not rec.shape and (rec.dtype.byteorder == "<" or (rec.dtype.byteorder == "=" and LITTLE_ENDIAN)):
                    rec = rec.byteswap()
                self.fp.write(rec.tobytes())
                self._write_var_padding(var, var._vsize - rec.size * rec.itemsize)
                pos += self._recsize
                self.fp.seek(pos)
            self.fp.seek(pos0 + var._vsize)

    def _write_var_padding(self, var, size):
        fill = var._get_encoded_fill_value()
        self.fp.write(fill * (size // len(fill)))

    def _write_att_values(self, values):
        if hasattr(values, "dtype"):
            nc_type = REVERSE[values.dtype.char, values.dtype.itemsize]
        else:
            types = [(int, NC_INT), (float, NC_FLOAT), (str, NC_CHAR)]
            if isinstance(values, (str, bytes)):
                sample = values
            else:
                try:
                    sample = values[0]
                except TypeError:
                    sample = values
            for class_, nc_type in types:
                if isinstance(sample, class_):
                    break
        typecode, size = TYPEMAP[nc_type]
        dtype_ = f">{typecode}"
        dtype_ = "S" if dtype_ == ">c" else dtype_
        values = np.asarray(values, dtype=dtype_)
        self.fp.write(nc_type)
        nelems = values.itemsize if values.dtype.char == "S" else values.size
        self._pack_int(nelems)
        if not values.shape and (values.dtype.byteorder == "<" or (values.dtype.byteorder == "=" and LITTLE_ENDIAN)):
            values = values.byteswap()
        self.fp.write(values.tobytes())
        self.fp.write(b"\x00" * (-(values.size * values.itemsize) % 4))

    # ---- reading ----
    def _read(self):
        if self.fp.read(3) != b"CDF":
            raise TypeError(f"Error: {self.filename} is not a valid NetCDF 3 file")
        self.__dict__["version_byte"] = np.frombuffer(self.fp.read(1), ">b")[0]
        self.__dict__["_recs"] = self._unpack_int()
        header = self.fp.read(4)
        if header not in (ZERO, NC_DIMENSION):
            raise ValueError("Unexpected header.")
        for _ in range(self._unpack_int()):
            name = self._unpack_string().decode("latin1")
            self.dimensions[name] = self._unpack_int() or None
            self._dims.append(name)
        for k, v in self._read_att_array().items():
            self.__setattr__(k, v)
        self._read_var_array()

    def _read_att_array(self):
        if self.fp.read(4) not in (ZERO, NC_ATTRIBUTE):
            raise ValueError("Unexpected header.")
        attrs = {}
        for _ in range(self._unpack_int()):
            name = self._unpack_string().decode("latin1")
            attrs[name] = self._read_att_values()
        return attrs

    def _read_var_array(self):
        if self.fp.read(4) not in (ZERO, NC_VARIABLE):
            raise ValueError("Unexpected header.")
        begin = 0
        dtypes = {"names": [], "formats": []}
        rec_vars = []
        for var in range(self._unpack_int()):
            name, dimensions, shape, attributes, typecode, size, dtype_, begin_, vsize = self._read_var()
            if shape and shape[0] is None:
                rec_vars.append(name)
                self.__dict__["_recsize"] += vsize
                if begin == 0:
                    begin = begin_
                dtypes["names"].append(name)
                dtypes["formats"].append(str(shape[1:]) + dtype_)
                if typecode in "bch":
                    actual = reduce(mul, (1,) + shape[1:]) * size
                    padding = -actual % 4
                    if padding:
                        dtypes["names"].append(f"_padding_{var}")
                        dtypes["formats"].append(f"({padding},)>b")
                data = None
            else:
                a_size = reduce(mul, shape, 1) * size
                if self.use_mmap:
                    data = self._mm_buf[begin_:begin_ + a_size].view(dtype=dtype_).reshape(shape)
                else:
                    pos = self.fp.tell()
                    self.fp.seek(begin_)
                    data = np.frombuffer(self.fp.read(a_size), dtype=dtype_).copy().reshape(shape)
                    self.fp.seek(pos)
            self.variables[name] = netcdf_variable(data, typecode, size, shape, dimensions, attributes,
                                                   maskandscale=self.maskandscale)
        if rec_vars:
            if len(rec_vars) == 1:
                dtypes["names"] = dtypes["names"][:1]
                dtypes["formats"] = dtypes["formats"][:1]
            if self.use_mmap:
                buf = self._mm_buf[begin:begin + self._recs * self._recsize]
                rec_array = buf.view(dtype=dtypes).reshape((self._recs,))
            else:
                pos = self.fp.tell()
                self.fp.seek(begin)
                rec_array = np.frombuffer(self.fp.read(self._recs * self._recsize), dtype=dtypes).copy()
                rec_array = rec_array.reshape((self._recs,))
                self.fp.seek(pos)
            for var in rec_vars:
                self.variables[var].__dict__["data"] = rec_array[var]

    def _read_var(self):
        name = self._unpack_string().decode("latin1")
        dimensions, shape = [], []
        for _ in range(self._unpack_int()):
            dimname = self._dims[self._unpack_int()]
            dimensions.append(dimname)
            shape.append(self.dimensions[dimname])
        attributes = self._read_att_array()
        nc_type = self.fp.read(4)
        vsize = self._unpack_int()
        begin = [self._unpack_int, self._unpack_int64][self.version_byte - 1]()
        typecode, size = TYPEMAP[nc_type]
        return name, tuple(dimensions), tuple(shape), attributes, typecode, size, f">{typecode}", begin, vsize

    def _read_att_values(self):
        nc_type = self.fp.read(4)
        n = self._unpack_int()
        typecode, size = TYPEMAP[nc_type]
        count = n * size
        values = self.fp.read(int(count))
        self.fp.read(-count % 4)
        if typecode != "c":
            values = np.frombuffer(values, dtype=f">{typecode}").copy()
            if values.shape == (1,):
                values = values[0]
        else:
            values = values.rstrip(b"\x00")
        return values

    def _pack_begin(self, begin):
        if self.version_byte == 1:
            self._pack_int(begin)
        elif self.version_byte == 2:
            self._pack_int64(begin)

    def _pack_int(self, value):
        self.fp.write(np.array(value, ">i").tobytes())

    def _unpack_int(self):
        return int(np.frombuffer(self.fp.read(4), ">i")[0])

    def _pack_int64(self, value):
        self.fp.write(np.array(value, ">q").tobytes())

    def _unpack_int64(self):
        return np.frombuffer(self.fp.read(8), ">q")[0]

    def _pack_string(self, s):
        self._pack_int(len(s))
        self.fp.write(s.encode("latin1"))
        self.fp.write(b"\x00" * (-len(s) % 4))

    def _unpack_string(self):
        count = self._unpack_int()
        s = self.fp.read(count).rstrip(b"\x00")
        self.fp.read(-count % 4)
        return s


class netcdf_variable:
    """A NetCDF variable: `.data` (numpy, big-endian), `.shape`, `.dimensions`, attributes as members, `[...]`."""

    def __init__(self, data, typecode, size, shape, dimensions, attributes=None, maskandscale=False):
        self.data = data
        self._typecode = typecode
        self._size = size
        self._shape = shape
        self.dimensions = dimensions
        self.maskandscale = maskandscale
        self._attributes = attributes or {}
        for k, v in self._attributes.items():
            self.__dict__[k] = v

    def __setattr__(self, attr, value):
        try:
            self._attributes[attr] = value
        except AttributeError:
            pass
        self.__dict__[attr] = value

    @property
    def isrec(self):
        return bool(self.data.shape) and not self._shape[0]

    @property
    def shape(self):
        return self.data.shape

    def getValue(self):
        return self.data.item()

    def assignValue(self, value):
        if not self.data.flags.writeable:
            raise RuntimeError("variable is not writeable")
        self.data[:] = value

    def typecode(self):
        return self._typecode

    def itemsize(self):
        return self._size

    def __getitem__(self, index):
        if not self.maskandscale:
            return self.data[index]
        data = self.data[index].copy()
        data = self._apply_missing_value(data, self._get_missing_value())
        scale_factor = self._attributes.get("scale_factor")
        add_offset = self._attributes.get("add_offset")
        if add_offset is not None or scale_factor is not None:
            data = data.astype(np.float64)
        if scale_factor is not None:
            data = data * scale_factor
        if add_offset is not None:
            data += add_offset
        return data

    def __setitem__(self, index, data):
        if self.maskandscale:
            missing_value = self._get_missing_value() or getattr(data, "fill_value", 999999)
            self._attributes.setdefault("missing_value", missing_value)
            self._attributes.setdefault("_FillValue", missing_value)
            data = (data - self._attributes.get("add_offset", 0.0)) / self._attributes.get("scale_factor", 1.0)
            data = np.ma.asarray(data).filled(missing_value)
            if self._typecode not in "fd" and data.dtype.kind == "f":
                data = np.round(data)
        if self.isrec:
            rec_index = index[0] if isinstance(index, tuple) else index
            if isinstance(rec_index, slice):
                recs = (rec_index.start or 0) + len(data)
            else:
                recs = rec_index + 1
            if recs > len(self.data):
                shape = (recs,) + self._shape[1:]
                try:
                    self.data.resize(shape)
                except ValueError:
                    dt = self.data.dtype
                    self.__dict__["data"] = np.resize(self.data, shape).astype(dt)
        self.data[index] = data

    def _default_encoded_fill_value(self):
        return FILLMAP[REVERSE[self.typecode(), self.itemsize()]]

    def _get_encoded_fill_value(self):
        if "_FillValue" in self._attributes:
            fill = np.array(self._attributes["_FillValue"], dtype=self.data.dtype).tobytes()
            if len(fill) == self.itemsize():
                return fill
        return self._default_encoded_fill_value()

    def _get_missing_value(self):
        if "_FillValue" in self._attributes:
            return self._attributes["_FillValue"]
        if "missing_value" in self._attributes:
            return self._attributes["missing_value"]
        return None

    @staticmethod
    def _apply_missing_value(data, missing_value):
        if missing_value is None:
            return data
        try:
            is_nan = np.isnan(missing_value)
        except (TypeError, NotImplementedError):
            is_nan = False
        mask = np.isnan(data) if is_nan else (data == missing_value)
        return np.ma.masked_where(mask, data)


NetCDFFile = netcdf_file
NetCDFVariable = netcdf_variable

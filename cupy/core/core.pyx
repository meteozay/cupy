# distutils: language = c++

from __future__ import division
import string
import sys

import ctypes
import numpy
import six

import cupy
from cupy.core import _errors
from cupy.core._kernel import create_reduction_func
from cupy.core._kernel import create_ufunc
from cupy.core._kernel import ElementwiseKernel
from cupy.core._kernel import ReductionKernel
from cupy.core._kernel import ufunc  # NOQA
from cupy.core._ufuncs import elementwise_copy
from cupy.core import flags
from cupy.cuda import device


try:
    from cupy.cuda import thrust
except ImportError:
    pass
from cupy import util
from cupy.cuda.runtime import CUDARuntimeError

cimport cpython  # NOQA
cimport cython  # NOQA
from libcpp cimport vector

from cupy.core cimport _dtype
from cupy.core._dtype cimport get_dtype
from cupy.core._kernel cimport create_reduction_func
from cupy.core._kernel cimport create_ufunc
from cupy.core cimport _routines_manipulation as _manipulation
from cupy.core._scalar import get_typename as _get_typename
from cupy.core cimport dlpack
from cupy.core cimport internal
from cupy.cuda cimport cublas
from cupy.cuda cimport function
from cupy.cuda cimport pinned_memory
from cupy.cuda cimport runtime
from cupy.cuda cimport memory
from cupy.cuda cimport stream as stream_module


DEF MAX_NDIM = 25


@cython.profile(False)
cdef inline _should_use_rop(x, y):
    xp = getattr(x, '__array_priority__', 0)
    yp = getattr(y, '__array_priority__', 0)
    return xp < yp and not isinstance(y, ndarray)


cdef tuple _HANDLED_TYPES


cdef class ndarray:

    """Multi-dimensional array on a CUDA device.

    This class implements a subset of methods of :class:`numpy.ndarray`.
    The difference is that this class allocates the array content on the
    current GPU device.

    Args:
        shape (tuple of ints): Length of axes.
        dtype: Data type. It must be an argument of :class:`numpy.dtype`.
        memptr (cupy.cuda.MemoryPointer): Pointer to the array content head.
        order ({'C', 'F'}): Row-major (C-style) or column-major
            (Fortran-style) order.

    Attributes:
        base (None or cupy.ndarray): Base array from which this array is
            created as a view.
        data (cupy.cuda.MemoryPointer): Pointer to the array content head.
        ~ndarray.dtype(numpy.dtype): Dtype object of element type.

            .. seealso::
               `Data type objects (dtype) \
               <https://docs.scipy.org/doc/numpy/reference/arrays.dtypes.html>`_
        ~ndarray.size (int): Number of elements this array holds.

            This is equivalent to product over the shape tuple.

            .. seealso:: :attr:`numpy.ndarray.size`

    """

    def __init__(self, shape, dtype=float, memptr=None, strides=None,
                 order='C'):
        cdef Py_ssize_t x, itemsize
        cdef vector.vector[Py_ssize_t] s = internal.get_size(shape)
        cdef int order_char = (
            b'C' if order is None else internal._normalize_order(order))
        del shape

        # `strides` is prioritized over `order`, but invalid `order` should be
        # checked even if `strides` is given.
        if order_char != b'C' and order_char != b'F':
            raise TypeError('order not understood. order=%s' % order)

        # Check for erroneous shape
        for x in s:
            if x < 0:
                raise ValueError('Negative dimensions are not allowed')

        # dtype
        self.dtype, itemsize = _dtype.get_dtype_with_itemsize(dtype)

        # Store shape and strides
        if strides is not None:
            if memptr is None:
                raise ValueError('memptr is required if strides is given.')
            self._set_shape_and_strides(s, strides, True, True)
        elif order_char == b'C':
            self._set_shape_and_contiguous_strides(s, itemsize, True)
        elif order_char == b'F':
            self._set_shape_and_contiguous_strides(s, itemsize, False)
        else:
            assert False

        # data
        if memptr is None:
            self.data = memory.alloc(self.size * itemsize)
        else:
            self.data = memptr

    @property
    def __cuda_array_interface__(self):
        desc = {
            'shape': self.shape,
            'typestr': self.dtype.str,
            'descr': self.dtype.descr,
            'data': (self.data.mem.ptr, False),
            'version': 0,
        }
        if not self._c_contiguous:
            desc['strides'] = self._strides

        return desc

    # The definition order of attributes and methods are borrowed from the
    # order of documentation at the following NumPy document.
    # https://docs.scipy.org/doc/numpy/reference/arrays.ndarray.html

    # -------------------------------------------------------------------------
    # Memory layout
    # -------------------------------------------------------------------------
    @property
    def flags(self):
        """Object containing memory-layout information.

        It only contains ``c_contiguous``, ``f_contiguous``, and ``owndata``
        attributes. All of these are read-only. Accessing by indexes is also
        supported.

        .. seealso:: :attr:`numpy.ndarray.flags`

        """
        return flags.Flags(self._c_contiguous, self._f_contiguous,
                           self.base is None)

    property shape:
        """Lengths of axes.

        Setter of this property involves reshaping without copy. If the array
        cannot be reshaped without copy, it raises an exception.

        .. seealso: :attr:`numpy.ndarray.shape`

        """

        def __get__(self):
            return tuple(self._shape)

        def __set__(self, newshape):
            _manipulation._ndarray_shape_setter(self, newshape)

    @property
    def strides(self):
        """Strides of axes in bytes.

        .. seealso:: :attr:`numpy.ndarray.strides`

        """
        return tuple(self._strides)

    @property
    def ndim(self):
        """Number of dimensions.

        ``a.ndim`` is equivalent to ``len(a.shape)``.

        .. seealso:: :attr:`numpy.ndarray.ndim`

        """
        return self._shape.size()

    @property
    def itemsize(self):
        """Size of each element in bytes.

        .. seealso:: :attr:`numpy.ndarray.itemsize`

        """
        return self.dtype.itemsize

    @property
    def nbytes(self):
        """Total size of all elements in bytes.

        It does not count skips between elements.

        .. seealso:: :attr:`numpy.ndarray.nbytes`

        """
        return self.size * self.dtype.itemsize

    # -------------------------------------------------------------------------
    # Other attributes
    # -------------------------------------------------------------------------
    @property
    def T(self):
        """Shape-reversed view of the array.

        If ndim < 2, then this is just a reference to the array itself.

        """
        if self.ndim < 2:
            return self
        else:
            return _manipulation._transpose(self, vector.vector[Py_ssize_t]())

    __array_priority__ = 100

    # -------------------------------------------------------------------------
    # Array interface
    # -------------------------------------------------------------------------
    # TODO(beam2d): Implement __array_interface__

    # -------------------------------------------------------------------------
    # foreign function interface
    # -------------------------------------------------------------------------
    @property
    def cstruct(self):
        """C representation of the array.

        This property is used for sending an array to CUDA kernels. The type of
        returned C structure is different for different dtypes and ndims. The
        definition of C type is written in ``cupy/carray.cuh``.

        """
        return CArray(self)

    # -------------------------------------------------------------------------
    # Array conversion
    # -------------------------------------------------------------------------
    cpdef item(self):
        """Converts the array with one element to a Python scalar

        Returns:
            int or float or complex: The element of the array.

        .. seealso:: :meth:`numpy.ndarray.item`

        """
        if self.size != 1:
            raise ValueError(
                'can only convert an array of size 1 to a Python scalar')
        return self.get().item()

    cpdef tolist(self):
        """Converts the array to a (possibly nested) Python list.

        Returns:
            list: The possibly nested Python list of array elements.

        .. seealso:: :meth:`numpy.ndarray.tolist`

        """
        return self.get().tolist()

    # TODO(okuta): Implement itemset
    # TODO(okuta): Implement tostring
    # TODO(okuta): Implement tobytes

    cpdef tofile(self, fid, sep='', format='%s'):
        """Writes the array to a file.

        .. seealso:: :meth:`numpy.ndarray.tolist`

        """
        self.get().tofile(fid, sep, format)

    cpdef dump(self, file):
        """Dumps a pickle of the array to a file.

        Dumped file can be read back to :class:`cupy.ndarray` by
        :func:`cupy.load`.

        """
        six.moves.cPickle.dump(self, file, -1)

    cpdef dumps(self):
        """Dumps a pickle of the array to a string."""
        return six.moves.cPickle.dumps(self, -1)

    cpdef ndarray astype(
            self, dtype, order='K', casting=None, subok=None, copy=True):
        """Casts the array to given data type.

        Args:
            dtype: Type specifier.
            order ({'C', 'F', 'A', 'K'}): Row-major (C-style) or column-major
                (Fortran-style) order.
                When ``order`` is 'A', it uses 'F' if ``a`` is column-major and
                uses 'C' otherwise.
                And when ``order`` is 'K', it keeps strides as closely as
                possible.
            copy (bool): If it is False and no cast happens, then this method
                returns the array itself. Otherwise, a copy is returned.

        Returns:
            If ``copy`` is False and no cast is required, then the array itself
            is returned. Otherwise, it returns a (possibly casted) copy of the
            array.

        .. note::
           This method currently does not support ``casting``, and ``subok``
           arguments.

        .. seealso:: :meth:`numpy.ndarray.astype`

        """
        cdef vector.vector[Py_ssize_t] strides
        cdef Py_ssize_t stride

        # TODO(beam2d): Support casting and subok option
        if casting is not None:
            raise TypeError('casting is not supported yet')
        if subok is not None:
            raise TypeError('subok is not supported yet')

        if order is None:
            order = 'K'
        cdef int order_char = internal._normalize_order(order)

        dtype = get_dtype(dtype)
        if dtype == self.dtype:
            if not copy and (
                    order_char == b'K' or
                    order_char == b'A' and (self._c_contiguous or
                                            self._f_contiguous) or
                    order_char == b'C' and self._c_contiguous or
                    order_char == b'F' and self._f_contiguous):
                return self

        order_char = _update_order_char(self, order_char)

        if order_char == b'K':
            strides = _get_strides_for_order_K(self, dtype)
            newarray = ndarray(self.shape, dtype=dtype)
            # TODO(niboshi): Confirm update_x_contiguity flags
            newarray._set_shape_and_strides(self._shape, strides, True, True)
        else:
            newarray = ndarray(self.shape, dtype=dtype, order=chr(order_char))

        if self.size == 0:
            # skip copy
            pass
        elif self.dtype.kind == 'c' and newarray.dtype.kind == 'b':
            cupy.not_equal(self, 0j, out=newarray)
        elif self.dtype.kind == 'c' and newarray.dtype.kind != 'c':
            warnings.warn(
                'Casting complex values to real discards the imaginary part',
                numpy.ComplexWarning)
            elementwise_copy(self.real, newarray)
        else:
            elementwise_copy(self, newarray)
        return newarray

    # TODO(okuta): Implement byteswap

    cpdef ndarray copy(self, order='C'):
        """Returns a copy of the array.

        This method makes a copy of a given array in the current device.
        Even when a given array is located in another device, you can copy it
        to the current device.

        Args:
            order ({'C', 'F', 'A', 'K'}): Row-major (C-style) or column-major
                (Fortran-style) order.
                When ``order`` is 'A', it uses 'F' if ``a`` is column-major and
                uses 'C' otherwise.
                And when `order` is 'K', it keeps strides as closely as
                possible.

        .. seealso::
           :func:`cupy.copy` for full documentation,
           :meth:`numpy.ndarray.copy`

        """
        if self.size == 0:
            return self.astype(self.dtype, order=order)

        dev_id = device.get_device_id()
        if self.data.device_id == dev_id:
            return self.astype(self.dtype, order=order)

        # It need to make a contiguous copy for copying from another device
        runtime.setDevice(self.data.device_id)
        try:
            x = self.astype(self.dtype, order=order, copy=False)
        finally:
            runtime.setDevice(dev_id)
        newarray = ndarray(x.shape, dtype=x.dtype)
        # TODO(niboshi): Confirm update_x_contiguity flags
        newarray._set_shape_and_strides(x._shape, x._strides, True, True)
        newarray.data.copy_from_device(x.data, x.nbytes)
        return newarray

    cpdef ndarray view(self, dtype=None):
        """Returns a view of the array.

        Args:
            dtype: If this is different from the data type of the array, the
                returned view reinterpret the memory sequence as an array of
                this type.

        Returns:
            cupy.ndarray: A view of the array. A reference to the original
            array is stored at the :attr:`~ndarray.base` attribute.

        .. seealso:: :meth:`numpy.ndarray.view`

        """
        # Use __new__ instead of __init__ to skip recomputation of contiguity
        cdef ndarray v
        cdef Py_ssize_t ndim
        cdef int self_is, v_is
        v = ndarray.__new__(ndarray)
        v._c_contiguous = self._c_contiguous
        v._f_contiguous = self._f_contiguous
        v.data = self.data
        v.base = self.base if self.base is not None else self
        v.size = self.size
        v._shape = self._shape
        v._strides = self._strides
        if dtype is None:
            v.dtype = self.dtype
            return v

        v.dtype, v_is = _dtype.get_dtype_with_itemsize(dtype)
        self_is = self.dtype.itemsize
        if v_is == self_is:
            return v

        ndim = self._shape.size()
        if ndim == 0:
            raise ValueError(
                "Changing the dtype of a 0d array is only supported if "
                "the itemsize is unchanged")
        if not self._c_contiguous:
            raise ValueError(
                "To change to a dtype of a different size, the array must "
                "be C-contiguous")
        v._shape[ndim - 1] = v._shape[ndim - 1] * self_is // v_is
        v._strides[ndim - 1] = v._strides[ndim - 1] * v_is // self_is
        v.size = v.size * self_is // v_is
        return v

    # TODO(okuta): Implement getfield
    # TODO(okuta): Implement setflags

    cpdef fill(self, value):
        """Fills the array with a scalar value.

        Args:
            value: A scalar value to fill the array content.

        .. seealso:: :meth:`numpy.ndarray.fill`

        """
        if isinstance(value, numpy.ndarray):
            if value.shape != ():
                raise ValueError(
                    'non-scalar numpy.ndarray cannot be used for fill')
            value = value.item()

        if value == 0 and self._c_contiguous:
            self.data.memset_async(0, self.nbytes)
        else:
            fill_kernel(value, self)

    # -------------------------------------------------------------------------
    # Shape manipulation
    # -------------------------------------------------------------------------
    def reshape(self, *shape, order='C'):
        """Returns an array of a different shape and the same content.

        .. seealso::
           :func:`cupy.reshape` for full documentation,
           :meth:`numpy.ndarray.reshape`

        """
        return _manipulation._ndarray_reshape(self, shape, order)

    # TODO(okuta): Implement resize

    def transpose(self, *axes):
        """Returns a view of the array with axes permuted.

        .. seealso::
           :func:`cupy.transpose` for full documentation,
           :meth:`numpy.ndarray.reshape`

        """
        return _manipulation._ndarray_transpose(self, axes)

    cpdef ndarray swapaxes(self, Py_ssize_t axis1, Py_ssize_t axis2):
        """Returns a view of the array with two axes swapped.

        .. seealso::
           :func:`cupy.swapaxes` for full documentation,
           :meth:`numpy.ndarray.swapaxes`

        """
        return _manipulation._ndarray_swapaxes(self, axis1, axis2)

    cpdef ndarray flatten(self):
        """Returns a copy of the array flatten into one dimension.

        It currently supports C-order only.

        Returns:
            cupy.ndarray: A copy of the array with one dimension.

        .. seealso:: :meth:`numpy.ndarray.flatten`

        """
        # TODO(beam2d): Support ordering option
        return _manipulation._ndarray_flatten(self)

    cpdef ndarray ravel(self, order='C'):
        """Returns an array flattened into one dimension.

        .. seealso::
           :func:`cupy.ravel` for full documentation,
           :meth:`numpy.ndarray.ravel`

        """
        return _manipulation._ndarray_ravel(self, order)

    cpdef ndarray squeeze(self, axis=None):
        """Returns a view with size-one axes removed.

        .. seealso::
           :func:`cupy.squeeze` for full documentation,
           :meth:`numpy.ndarray.squeeze`

        """
        return _manipulation._ndarray_squeeze(self, axis)

    # -------------------------------------------------------------------------
    # Item selection and manipulation
    # -------------------------------------------------------------------------
    cpdef ndarray take(self, indices, axis=None, out=None):
        """Returns an array of elements at given indices along the axis.

        .. seealso::
           :func:`cupy.take` for full documentation,
           :meth:`numpy.ndarray.take`

        """
        if axis is None:
            return _take(self, indices, 0, self._shape.size() - 1, out)
        else:
            return _take(self, indices, axis, axis, out)

    # TODO(okuta): Implement put

    cpdef repeat(self, repeats, axis=None):
        """Returns an array with repeated arrays along an axis.

        .. seealso::
            :func:`cupy.repeat` for full documentation,
            :meth:`numpy.ndarray.repeat`

        """
        return _manipulation._ndarray_repeat(self, repeats, axis)

    cpdef choose(self, choices, out=None, mode='raise'):
        a = self
        n = choices.shape[0]

        # broadcast `a` and `choices[i]` for all i
        if a.ndim < choices.ndim - 1:
            for i in range(choices.ndim - 1 - a.ndim):
                a = a[None, ...]
        elif a.ndim > choices.ndim - 1:
            for i in range(a.ndim + 1 - choices.ndim):
                choices = choices[:, None, ...]
        ba, bcs = _manipulation.broadcast(a, choices).values

        if out is None:
            out = ndarray(ba.shape[1:], choices.dtype)

        n_channel = numpy.prod(bcs[0].shape)
        if mode == 'raise':
            if not ((a < n).all() and (0 <= a).all()):
                raise ValueError('invalid entry in choice array')
            _choose_kernel(ba[0], bcs, n_channel, out)
        elif mode == 'wrap':
            ba = ba[0] % n
            _choose_kernel(ba, bcs, n_channel, out)
        elif mode == 'clip':
            _choose_clip_kernel(ba[0], bcs, n_channel, n, out)
        else:
            raise TypeError('clipmode not understood')

        return out

    cpdef sort(self, int axis=-1):
        """Sort an array, in-place with a stable sorting algorithm.

        Args:
            axis (int): Axis along which to sort. Default is -1, which means
                sort along the last axis.

        .. note::
           For its implementation reason, ``ndarray.sort`` currently supports
           only arrays with their own data, and does not support ``kind`` and
           ``order`` parameters that ``numpy.ndarray.sort`` does support.

        .. seealso::
            :func:`cupy.sort` for full documentation,
            :meth:`numpy.ndarray.sort`

        """

        # TODO(takagi): Support kind argument.

        cdef int ndim = self._shape.size()
        cdef ndarray data

        if not cupy.cuda.thrust_enabled:
            raise RuntimeError('Thrust is needed to use cupy.sort. Please '
                               'install CUDA Toolkit with Thrust then '
                               'reinstall CuPy after uninstalling it.')

        if ndim == 0:
            raise ValueError('Sorting arrays with the rank of zero is not '
                             'supported')  # as numpy.sort() raises

        # TODO(takagi): Support sorting views
        if not self._c_contiguous:
            raise NotImplementedError('Sorting non-contiguous array is not '
                                      'supported.')

        if axis < 0:
            axis += ndim
        if not (0 <= axis < ndim):
            raise _errors._AxisError('Axis out of range')

        if axis == ndim - 1:
            data = self
        else:
            data = _manipulation.rollaxis(self, axis, ndim).copy()

        if ndim == 1:
            thrust.sort(self.dtype, data.data.ptr, 0, self.shape)
        else:
            keys_array = ndarray(data.shape, dtype=numpy.intp)
            thrust.sort(
                self.dtype, data.data.ptr, keys_array.data.ptr, data.shape)

        if axis == ndim - 1:
            pass
        else:
            data = _manipulation.rollaxis(data, -1, axis)
            elementwise_copy(data, self)

    cpdef ndarray argsort(self, axis=-1):
        """Returns the indices that would sort an array with stable sorting

        Args:
            axis (int or None): Axis along which to sort. Default is -1, which
                means sort along the last axis. If None is supplied, the array
                is flattened before sorting.

        Returns:
            cupy.ndarray: Array of indices that sort the array.

        .. seealso::
            :func:`cupy.argsort` for full documentation,
            :meth:`numpy.ndarray.argsort`

        """

        # TODO(takagi): Support kind argument.

        cdef int _axis, ndim = self._shape.size()
        cdef ndarray data

        if not cupy.cuda.thrust_enabled:
            raise RuntimeError('Thrust is needed to use cupy.argsort. Please '
                               'install CUDA Toolkit with Thrust then '
                               'reinstall CuPy after uninstalling it.')

        if ndim == 0:
            raise ValueError('Sorting arrays with the rank of zero is not '
                             'supported')  # as numpy.argsort() raises

        if axis is None:
            data = self.ravel()
            _axis = -1
        else:
            data = self
            _axis = axis

        if _axis < 0:
            _axis += ndim
        if not (0 <= _axis < ndim):
            raise _errors._AxisError('Axis out of range')

        if _axis == ndim - 1:
            data = data.copy()
        else:
            data = _manipulation.rollaxis(data, _axis, ndim).copy()
        shape = data.shape

        idx_array = ndarray(shape, dtype=numpy.intp)

        if ndim == 1:
            thrust.argsort(self.dtype, idx_array.data.ptr, data.data.ptr, 0,
                           shape)
        else:
            keys_array = ndarray(shape, dtype=numpy.intp)
            thrust.argsort(self.dtype, idx_array.data.ptr, data.data.ptr,
                           keys_array.data.ptr, shape)

        if _axis == ndim - 1:
            return idx_array
        else:
            return _manipulation.rollaxis(idx_array, -1, _axis)

    cpdef partition(self, kth, int axis=-1):
        """Partitions an array.

        Args:
            kth (int or sequence of ints): Element index to partition by. If
                supplied with a sequence of k-th it will partition all elements
                indexed by k-th of them into their sorted position at once.

            axis (int): Axis along which to sort. Default is -1, which means
                sort along the last axis.

        .. seealso::
            :func:`cupy.partition` for full documentation,
            :meth:`numpy.ndarray.partition`

        """

        if self.dtype.kind == 'c':
            raise NotImplementedError('Sorting arrays with dtype \'{}\' is '
                                      'not supported'.format(self.dtype))

        cdef int ndim = self._shape.size()
        cdef Py_ssize_t k, max_k, length, s, sz, t
        cdef ndarray data

        if ndim == 0:
            raise ValueError('Sorting arrays with the rank of zero is not '
                             'supported')

        if not self._c_contiguous:
            raise NotImplementedError('Sorting non-contiguous array is not '
                                      'supported.')

        if axis < 0:
            axis += ndim
        if not (0 <= axis < ndim):
            raise _errors._AxisError('Axis out of range')

        if axis == ndim - 1:
            data = self
        else:
            data = _manipulation.rollaxis(self, axis, ndim).copy()

        length = self._shape[axis]
        if isinstance(kth, int):
            kth = kth,
        max_k = 0
        for k in kth:
            if k < 0:
                k += length
            if not (0 <= k < length):
                raise ValueError('kth(={}) out of bounds {}'.format(k, length))
            if max_k < k:
                max_k = k

        # For simplicity, max_k is round up to the power of 2. If max_k is
        # already the power of 2, it is round up to the next power of 2 because
        # we need to collect the first max(kth)+1 elements.
        max_k = max(32, 1 << max_k.bit_length())

        # The parameter t is the length of the list that stores elements to be
        # selected for each thread. We divide the array into sz subarrays.
        # These parameters are determined from the measurement on TITAN X.
        t = 4
        sz = 512
        while sz > 0 and length // sz < max_k + 32 * t:
            sz //= 2
        sz *= self.size // length

        # If the array size is small or k is large, we simply sort the array.
        if length < 32 or sz <= 32 or max_k >= 1024:
            # kth is ignored.
            data.sort(axis=-1)
        else:
            shape = data.shape
            data = data.ravel()

            # For each subarray, we collect first k elements to the head.
            kern, merge_kern = _partition_kernel(self.dtype)
            block_size = 32
            grid_size = sz
            kern(grid=(grid_size,), block=(block_size,), args=(
                data, max_k, self.size, t, sz))

            # Merge heads of subarrays.
            s = 1
            while s < sz // (self.size // length):
                block_size = 32
                grid_size = sz // s // 2
                merge_kern(grid=(grid_size,), block=(block_size,), args=(
                    data, max_k, self.size, sz, s))
                s *= 2

            data = data.reshape(shape)

        if axis != ndim - 1:
            data = _manipulation.rollaxis(data, -1, axis)
            elementwise_copy(data, self)

    cpdef ndarray argpartition(self, kth, axis=-1):
        """Returns the indices that would partially sort an array.

        Args:
            kth (int or sequence of ints): Element index to partition by. If
                supplied with a sequence of k-th it will partition all elements
                indexed by k-th of them into their sorted position at once.
            axis (int or None): Axis along which to sort. Default is -1, which
                means sort along the last axis. If None is supplied, the array
                is flattened before sorting.

        Returns:
            cupy.ndarray: Array of the same type and shape as ``a``.

        .. seealso::
            :func:`cupy.argpartition` for full documentation,
            :meth:`numpy.ndarray.argpartition`

        """
        cdef int _axis, ndim
        cdef Py_ssize_t k, length
        cdef ndarray data
        if axis is None:
            data = self.ravel()
            _axis = -1
        else:
            data = self
            _axis = axis

        ndim = data._shape.size()
        if _axis < 0:
            _axis += ndim
        if not (0 <= _axis < ndim):
            raise _errors._AxisError('Axis out of range')

        length = data._shape[_axis]
        if isinstance(kth, int):
            kth = kth,
        for k in kth:
            if k < 0:
                k += length
            if not (0 <= k < length):
                raise ValueError('kth(={}) out of bounds {}'.format(k, length))

        # TODO(takgi) For its implementation reason, cupy.ndarray.argsort
        # currently performs full argsort with Thrust's efficient radix sort
        # algoritm.

        # kth is ignored.
        return data.argsort(_axis)

    # TODO(okuta): Implement searchsorted

    cpdef tuple nonzero(self):
        """Return the indices of the elements that are non-zero.

        Returned Array is containing the indices of the non-zero elements
        in that dimension.

        Returns:
            tuple of arrays: Indices of elements that are non-zero.

        .. seealso::
            :func:`numpy.nonzero`

        """
        cdef Py_ssize_t count_nonzero, ndim
        dtype = numpy.int64
        if self.size == 0:
            count_nonzero = 0
        else:
            r = self.ravel()
            nonzero = not_equal(r, 0, ndarray(r.shape, dtype))
            del r
            scan_index = scan(nonzero)
            count_nonzero = int(scan_index[-1])
        ndim = max(self._shape.size(), 1)
        if count_nonzero == 0:
            return (ndarray((0,), dtype=dtype),) * ndim

        if ndim <= 1:
            dst = ndarray((count_nonzero,), dtype=dtype)
            _nonzero_kernel_1d(nonzero, scan_index, dst)
            return dst,
        else:
            nonzero.shape = self.shape
            scan_index.shape = self.shape
            dst = ndarray((ndim, count_nonzero), dtype=dtype)
            _nonzero_kernel(nonzero, scan_index, dst)
            return tuple([dst[i] for i in range(ndim)])

    # TODO(okuta): Implement compress

    cpdef ndarray diagonal(self, offset=0, axis1=0, axis2=1):
        """Returns a view of the specified diagonals.

        .. seealso::
           :func:`cupy.diagonal` for full documentation,
           :meth:`numpy.ndarray.diagonal`

        """
        return _diagonal(self, offset, axis1, axis2)

    # -------------------------------------------------------------------------
    # Calculation
    # -------------------------------------------------------------------------
    cpdef ndarray max(self, axis=None, out=None, dtype=None, keepdims=False):
        """Returns the maximum along a given axis.

        .. seealso::
           :func:`cupy.amax` for full documentation,
           :meth:`numpy.ndarray.max`

        """
        return _amax(
            self, axis=axis, out=out, dtype=dtype, keepdims=keepdims)

    cpdef ndarray argmax(self, axis=None, out=None, dtype=None,
                         keepdims=False):
        """Returns the indices of the maximum along a given axis.

        .. seealso::
           :func:`cupy.argmax` for full documentation,
           :meth:`numpy.ndarray.argmax`

        """
        return _argmax(
            self, axis=axis, out=out, dtype=dtype, keepdims=keepdims)

    cpdef ndarray min(self, axis=None, out=None, dtype=None, keepdims=False):
        """Returns the minimum along a given axis.

        .. seealso::
           :func:`cupy.amin` for full documentation,
           :meth:`numpy.ndarray.min`

        """
        return _amin(
            self, axis=axis, out=out, dtype=dtype, keepdims=keepdims)

    cpdef ndarray argmin(self, axis=None, out=None, dtype=None,
                         keepdims=False):
        """Returns the indices of the minimum along a given axis.

        .. seealso::
           :func:`cupy.argmin` for full documentation,
           :meth:`numpy.ndarray.argmin`

        """
        return _argmin(
            self, axis=axis, out=out, dtype=dtype, keepdims=keepdims)

    # TODO(okuta): Implement ptp

    cpdef ndarray clip(self, a_min=None, a_max=None, out=None):
        """Returns an array with values limited to [a_min, a_max].

        .. seealso::
           :func:`cupy.clip` for full documentation,
           :meth:`numpy.ndarray.clip`

        """
        if a_min is None and a_max is None:
            raise ValueError('array_clip: must set either max or min')
        kind = self.dtype.kind
        if a_min is None:
            if kind == 'f':
                a_min = self.dtype.type('-inf')
            elif kind in 'iu':
                a_min = numpy.iinfo(self.dtype.type).min
        if a_max is None:
            if kind == 'f':
                a_max = self.dtype.type('inf')
            elif kind in 'iu':
                a_max = numpy.iinfo(self.dtype.type).max
        return _clip(self, a_min, a_max, out=out)

    cpdef ndarray round(self, decimals=0, out=None):
        """Returns an array with values rounded to the given number of decimals.

        .. seealso::
           :func:`cupy.around` for full documentation,
           :meth:`numpy.ndarray.round`

        """
        return _round_ufunc(self, decimals, out=out)

    cpdef ndarray trace(self, offset=0, axis1=0, axis2=1, dtype=None,
                        out=None):
        """Returns the sum along diagonals of the array.

        .. seealso::
           :func:`cupy.trace` for full documentation,
           :meth:`numpy.ndarray.trace`

        """
        d = self.diagonal(offset, axis1, axis2)
        return d.sum(-1, dtype, out, False)

    cpdef ndarray sum(self, axis=None, dtype=None, out=None, keepdims=False):
        """Returns the sum along a given axis.

        .. seealso::
           :func:`cupy.sum` for full documentation,
           :meth:`numpy.ndarray.sum`

        """
        if dtype is None:
            return _sum_auto_dtype(self, axis, dtype, out, keepdims)
        else:
            return _sum_keep_dtype(self, axis, dtype, out, keepdims)

    cpdef ndarray cumsum(self, axis=None, dtype=None, out=None):
        """Returns the cumulative sum of an array along a given axis.

        .. seealso::
           :func:`cupy.cumsum` for full documentation,
           :meth:`numpy.ndarray.cumsum`

        """
        return cupy.cumsum(self, axis, dtype, out)

    cpdef ndarray mean(self, axis=None, dtype=None, out=None, keepdims=False):
        """Returns the mean along a given axis.

        .. seealso::
           :func:`cupy.mean` for full documentation,
           :meth:`numpy.ndarray.mean`

        """
        return _mean(self, axis=axis, dtype=dtype, out=out, keepdims=keepdims)

    cpdef ndarray var(self, axis=None, dtype=None, out=None, ddof=0,
                      keepdims=False):
        """Returns the variance along a given axis.

        .. seealso::
           :func:`cupy.var` for full documentation,
           :meth:`numpy.ndarray.var`

        """
        return _var(self, axis=axis, dtype=dtype, out=out, ddof=ddof,
                    keepdims=keepdims)

    cpdef ndarray std(self, axis=None, dtype=None, out=None, ddof=0,
                      keepdims=False):
        """Returns the standard deviation along a given axis.

        .. seealso::
           :func:`cupy.std` for full documentation,
           :meth:`numpy.ndarray.std`

        """
        return _std(self, axis=axis, dtype=dtype, out=out, ddof=ddof,
                    keepdims=keepdims)

    cpdef ndarray prod(self, axis=None, dtype=None, out=None, keepdims=None):
        """Returns the product along a given axis.

        .. seealso::
           :func:`cupy.prod` for full documentation,
           :meth:`numpy.ndarray.prod`

        """
        if dtype is None:
            return _prod_auto_dtype(self, axis, dtype, out, keepdims)
        else:
            return _prod_keep_dtype(self, axis, dtype, out, keepdims)

    cpdef ndarray cumprod(a, axis=None, dtype=None, out=None):
        """Returns the cumulative product of an array along a given axis.

        .. seealso::
           :func:`cupy.cumprod` for full documentation,
           :meth:`numpy.ndarray.cumprod`

        """
        return cupy.cumprod(a, axis, dtype, out)

    cpdef ndarray all(self, axis=None, out=None, keepdims=False):
        return _all(self, axis=axis, out=out, keepdims=keepdims)

    cpdef ndarray any(self, axis=None, out=None, keepdims=False):
        return _any(self, axis=axis, out=out, keepdims=keepdims)

    # -------------------------------------------------------------------------
    # Arithmetic and comparison operations
    # -------------------------------------------------------------------------
    # Comparison operators:

    def __richcmp__(object self, object other, int op):
        if isinstance(other, numpy.ndarray) and other.ndim == 0:
            other = other.item()  # Workaround for numpy<1.13
        if op == 0:
            return less(self, other)
        if op == 1:
            return less_equal(self, other)
        if op == 2:
            return equal(self, other)
        if op == 3:
            return not_equal(self, other)
        if op == 4:
            return greater(self, other)
        if op == 5:
            return greater_equal(self, other)
        return NotImplemented

    # Truth value of an array (bool):

    def __nonzero__(self):
        if self.size == 0:
            return False
        elif self.size == 1:
            return bool(self.get())
        else:
            msg = ('The truth value of an array with more than one element is '
                   'ambiguous. Use a.any() or a.all()')
            raise ValueError(msg)

    # Unary operations:

    def __neg__(self):
        return negative(self)

    def __pos__(self):
        return self

    def __abs__(self):
        return absolute(self)

    def __invert__(self):
        return invert(self)

    # Arithmetic:

    def __add__(x, y):
        if _should_use_rop(x, y):
            return y.__radd__(x)
        else:
            return add(x, y)

    def __sub__(x, y):
        if _should_use_rop(x, y):
            return y.__rsub__(x)
        else:
            return subtract(x, y)

    def __mul__(x, y):
        if _should_use_rop(x, y):
            return y.__rmul__(x)
        else:
            return multiply(x, y)

    def __matmul__(x, y):
        if _should_use_rop(x, y):
            return y.__rmatmul__(x)
        else:
            return matmul(x, y)

    def __div__(x, y):
        if _should_use_rop(x, y):
            return y.__rdiv__(x)
        else:
            return divide(x, y)

    def __truediv__(x, y):
        if _should_use_rop(x, y):
            return y.__rtruediv__(x)
        else:
            return true_divide(x, y)

    def __floordiv__(x, y):
        if _should_use_rop(x, y):
            return y.__rfloordiv__(x)
        else:
            return floor_divide(x, y)

    def __mod__(x, y):
        if _should_use_rop(x, y):
            return y.__rmod__(x)
        else:
            return remainder(x, y)

    def __divmod__(x, y):
        if _should_use_rop(x, y):
            return y.__rdivmod__(x)
        else:
            return divmod(x, y)

    def __pow__(x, y, modulo):
        # Note that we ignore the modulo argument as well as NumPy.
        if _should_use_rop(x, y):
            return y.__rpow__(x)
        else:
            return power(x, y)

    def __lshift__(x, y):
        if _should_use_rop(x, y):
            return y.__rlshift__(x)
        else:
            return left_shift(x, y)

    def __rshift__(x, y):
        if _should_use_rop(x, y):
            return y.__rrshift__(x)
        else:
            return right_shift(x, y)

    def __and__(x, y):
        if _should_use_rop(x, y):
            return y.__rand__(x)
        else:
            return bitwise_and(x, y)

    def __or__(x, y):
        if _should_use_rop(x, y):
            return y.__ror__(x)
        else:
            return bitwise_or(x, y)

    def __xor__(x, y):
        if _should_use_rop(x, y):
            return y.__rxor__(x)
        else:
            return bitwise_xor(x, y)

    # Arithmetic, in-place:

    def __iadd__(self, other):
        return add(self, other, self)

    def __isub__(self, other):
        return subtract(self, other, self)

    def __imul__(self, other):
        return multiply(self, other, self)

    def __idiv__(self, other):
        return divide(self, other, self)

    def __itruediv__(self, other):
        return true_divide(self, other, self)

    def __ifloordiv__(self, other):
        return floor_divide(self, other, self)

    def __imod__(self, other):
        return remainder(self, other, self)

    def __ipow__(self, other):
        return power(self, other, self)

    def __ilshift__(self, other):
        return left_shift(self, other, self)

    def __irshift__(self, other):
        return right_shift(self, other, self)

    def __iand__(self, other):
        return bitwise_and(self, other, self)

    def __ior__(self, other):
        return bitwise_or(self, other, self)

    def __ixor__(self, other):
        return bitwise_xor(self, other, self)

    cpdef ndarray conj(self):
        if self.dtype.kind == 'c':
            return conj(self)
        else:
            return self

    @property
    def real(self):
        if self.dtype.kind == 'c':
            view = ndarray(
                shape=self._shape, dtype=get_dtype(self.dtype.char.lower()),
                memptr=self.data, strides=self._strides)
            view.base = self.base if self.base is not None else self
            return view
        return self

    @real.setter
    def real(self, value):
        if self.dtype.kind == 'c':
            _real_setter(value, self)
        else:
            elementwise_copy(value, self)

    @property
    def imag(self):
        if self.dtype.kind == 'c':
            view = ndarray(
                shape=self._shape, dtype=get_dtype(self.dtype.char.lower()),
                memptr=self.data + self.dtype.itemsize // 2,
                strides=self._strides)
            view.base = self.base if self.base is not None else self
            return view
        new_array = ndarray(self.shape, dtype=self.dtype)
        new_array.fill(0)
        return new_array

    @imag.setter
    def imag(self, value):
        if self.dtype.kind == 'c':
            _imag_setter(value, self)
        else:
            raise TypeError('cupy.ndarray does not have imaginary part to set')

    # -------------------------------------------------------------------------
    # Special methods
    # -------------------------------------------------------------------------
    # For standard library functions:

    def __copy__(self):
        return self.copy()

    def __deepcopy__(self, memo):
        with self.device:
            return self.copy()

    def __reduce__(self):
        return array, (self.get(),)

    # Basic customization:

    # cupy.ndarray does not define __new__

    def __array__(self, dtype=None):
        if dtype is None or self.dtype == dtype:
            return self
        else:
            return self.astype(dtype)

    # TODO(okuta): Implement __array_wrap__

    # Container customization:

    def __iter__(self):
        if self._shape.size() == 0:
            raise TypeError('iteration over a 0-d array')
        return (self[i] for i in six.moves.range(self._shape[0]))

    def __len__(self):
        if self._shape.size() == 0:
            raise TypeError('len() of unsized object')
        return self._shape[0]

    def __getitem__(self, slices):
        """x.__getitem__(y) <==> x[y]

        Supports both basic and advanced indexing.

        .. note::

            Currently, it does not support ``slices`` that consists of more
            than one boolean arrays

        .. note::

           CuPy handles out-of-bounds indices differently from NumPy.
           NumPy handles them by raising an error, but CuPy wraps around them.

        Example:

            >>> a = cupy.arange(3)
            >>> a[[1, 3]]
            array([1, 0])

        """
        # supports basic indexing (by slices, ints or Ellipsis) and
        # some parts of advanced indexing by integer or boolean arrays.
        # TODO(beam2d): Support the advanced indexing of NumPy.
        cdef Py_ssize_t mask_i
        cdef list slice_list, adv_mask, adv_slices
        cdef bint advanced, mask_exists

        slice_list, advanced, mask_exists = _prepare_slice_list(
            slices, self._shape.size())

        if mask_exists:
            mask_i = _get_mask_index(slice_list)
            return _getitem_mask_single(self, slice_list[mask_i], mask_i)
        if advanced:
            a, adv_slices, adv_mask = _prepare_advanced_indexing(
                self, slice_list)
            if sum(adv_mask) == 1:
                axis = adv_mask.index(True)
                return a.take(adv_slices[axis], axis)
            return _getitem_multiple(a, adv_slices)

        return _simple_getitem(self, slice_list)

    def __setitem__(self, slices, value):
        """x.__setitem__(slices, y) <==> x[slices] = y

        Supports both basic and advanced indexing.

        .. note::

            Currently, it does not support ``slices`` that consists of more
            than one boolean arrays

        .. note::

            CuPy handles out-of-bounds indices differently from NumPy when
            using integer array indexing.
            NumPy handles them by raising an error, but CuPy wraps around them.

            >>> import cupy
            >>> x = cupy.arange(3)
            >>> x[[1, 3]] = 10
            >>> x
            array([10, 10,  2])

        .. note::

            The behavior differs from NumPy when integer arrays in ``slices``
            reference the same location multiple times.
            In that case, the value that is actually stored is undefined.

            >>> import cupy
            >>> a = cupy.zeros((2,))
            >>> i = cupy.arange(10000) % 2
            >>> v = cupy.arange(10000).astype(cupy.float)
            >>> a[i] = v
            >>> a  # doctest: +SKIP
            array([9150., 9151.])

            On the other hand, NumPy stores the value corresponding to the
            last index among the indices referencing duplicate locations.

            >>> import numpy
            >>> a_cpu = numpy.zeros((2,))
            >>> i_cpu = numpy.arange(10000) % 2
            >>> v_cpu = numpy.arange(10000).astype(numpy.float)
            >>> a_cpu[i_cpu] = v_cpu
            >>> a_cpu
            array([9998., 9999.])

        """
        _scatter_op(self, slices, value, 'update')

    def scatter_add(self, slices, value):
        """Adds given values to specified elements of an array.

        .. seealso::
            :func:`cupyx.scatter_add` for full documentation.

        """
        _scatter_op(self, slices, value, 'add')

    # TODO(okuta): Implement __getslice__
    # TODO(okuta): Implement __setslice__
    # TODO(okuta): Implement __contains__

    # numpy/ufunc compat
    def __array_ufunc__(self, ufunc, method, *inputs, **kwargs):

        """Apply unary or binary ufunc to this array

        If binary, only allow if second argument is another cupy ndarray or
        a number, i.e., raise ValueError instead of silently converting a
        numpy array.
        """
        import cupy  # top-level ufuncs
        if 'out' in kwargs:
            # need to unfold tuple argument in kwargs
            out = kwargs['out']
            if len(out) != 1:
                raise ValueError("The 'out' parameter must have exactly one "
                                 "array value")
            kwargs['out'] = out[0]

        if method == '__call__':
            if ufunc.signature is not None:
                # we don't support generalised-ufuncs (gufuncs)
                return NotImplemented
            name = ufunc.__name__
            try:
                cp_ufunc = getattr(cupy, name)
            except AttributeError:
                return NotImplemented
            if name in [
                    'greater', 'greater_equal', 'less', 'less_equal',
                    'equal', 'not_equal']:
                # workaround for numpy/numpy#12142
                inputs = tuple([
                    x.item()
                    if isinstance(x, numpy.ndarray) and x.ndim == 0
                    else x
                    for x in inputs
                ])
            return cp_ufunc(*inputs, **kwargs)
        # Don't use for now, interface uncertain
        # elif method =='at' and name == 'add':
            # the only ufunc attribute currently
            # http://docs-cupy.chainer.org/en/stable/reference/ufunc.html#ufunc-at
            # self.scatter_add(*inputs, **kwargs)
        else:
            return NotImplemented

    def __array_function__(self, func, types, args, kwargs):
        if not hasattr(cupy, func.__name__):
            return NotImplemented
        for t in types:
            if t not in _HANDLED_TYPES:
                return NotImplemented
        return getattr(cupy, func.__name__)(*args, **kwargs)

    # Conversion:

    def __int__(self):
        return int(self.get())

    if sys.version_info < (3,):
        def __long__(self):
            # Avoid using long() for flake8
            return self.get().__long__()

    def __float__(self):
        return float(self.get())

    def __complex__(self):
        return complex(self.get())

    def __oct__(self):
        return oct(self.get())

    def __hex__(self):
        return hex(self.get())

    # String representations:

    def __repr__(self):
        return repr(self.get())

    def __str__(self):
        return str(self.get())

    # -------------------------------------------------------------------------
    # Methods outside of the ndarray main documentation
    # -------------------------------------------------------------------------
    def dot(self, ndarray b, ndarray out=None):
        """Returns the dot product with given array.

        .. seealso::
           :func:`cupy.dot` for full documentation,
           :meth:`numpy.ndarray.dot`

        """
        return dot(self, b, out)

    # -------------------------------------------------------------------------
    # Cupy specific attributes and methods
    # -------------------------------------------------------------------------
    @property
    def device(self):
        """CUDA device on which this array resides."""
        return self.data.device

    cpdef get(self, stream=None, order='C'):
        """Returns a copy of the array on host memory.

        Args:
            stream (cupy.cuda.Stream): CUDA stream object. If it is given, the
                copy runs asynchronously. Otherwise, the copy is synchronous.
                The default uses CUDA stream object of the current context.
            order ({'C', 'F', 'A'}): The desired memory layout of the host
                array. When ``order`` is 'A', it uses 'F' if the array is
                fortran-contiguous and 'C' otherwise.

        Returns:
            numpy.ndarray: Copy of the array on host memory.

        """
        if self.size == 0:
            return numpy.ndarray(self._shape, dtype=self.dtype)

        order = order.upper()
        if order == 'A':
            if self._f_contiguous:
                order = 'F'
            else:
                order = 'C'

        with self.device:
            if order == 'C':
                a_gpu = ascontiguousarray(self)
            elif order == 'F':
                a_gpu = asfortranarray(self)
            else:
                raise ValueError("unsupported order: {}".format(order))
        a_cpu = numpy.empty(self._shape, dtype=self.dtype, order=order)
        ptr = a_cpu.ctypes.get_as_parameter()
        if stream is not None:
            a_gpu.data.copy_to_host_async(ptr, a_gpu.nbytes, stream)
        else:
            stream_ptr = stream_module.get_current_stream_ptr()
            if stream_ptr == 0:
                a_gpu.data.copy_to_host(ptr, a_gpu.nbytes)
            else:
                a_gpu.data.copy_to_host_async(ptr, a_gpu.nbytes)
        return a_cpu

    cpdef set(self, arr, stream=None):
        """Copies an array on the host memory to :class:`cupy.ndarray`.

        Args:
            arr (numpy.ndarray): The source array on the host memory.
            stream (cupy.cuda.Stream): CUDA stream object. If it is given, the
                copy runs asynchronously. Otherwise, the copy is synchronous.
                The default uses CUDA stream object of the current context.

        """
        if not isinstance(arr, numpy.ndarray):
            raise TypeError('Only numpy.ndarray can be set to cupy.ndarray')
        if self.dtype != arr.dtype:
            raise TypeError('{} array cannot be set to {} array'.format(
                arr.dtype, self.dtype))
        if self.shape != arr.shape:
            raise ValueError(
                'Shape mismatch. Old shape: {}, new shape: {}'.format(
                    self.shape, arr.shape))
        if self._c_contiguous:
            arr = numpy.ascontiguousarray(arr)
        elif self._f_contiguous:
            arr = numpy.asfortranarray(arr)
        else:
            raise RuntimeError('Cannot set to non-contiguous array')

        ptr = arr.ctypes.get_as_parameter()
        if stream is not None:
            self.data.copy_from_host_async(ptr, self.nbytes, stream)
        else:
            stream_ptr = stream_module.get_current_stream_ptr()
            if stream_ptr == 0:
                self.data.copy_from_host(ptr, self.nbytes)
            else:
                self.data.copy_from_host_async(ptr, self.nbytes)

    cpdef ndarray reduced_view(self, dtype=None):
        """Returns a view of the array with minimum number of dimensions.

        Args:
            dtype: Data type specifier. If it is given, then the memory
                sequence is reinterpreted as the new type.

        Returns:
            cupy.ndarray: A view of the array with reduced dimensions.

        """
        cdef vector.vector[Py_ssize_t] shape, strides
        cdef Py_ssize_t ndim
        ndim = self._shape.size()
        if ndim <= 1:
            return self
        internal.get_reduced_dims(
            self._shape, self._strides, self.itemsize, shape, strides)
        if ndim == <Py_ssize_t>shape.size():
            return self

        view = self.view(dtype=dtype)
        # TODO(niboshi): Confirm update_x_contiguity flags
        view._set_shape_and_strides(shape, strides, True, True)
        return view

    cpdef _update_c_contiguity(self):
        if self.size == 0:
            self._c_contiguous = True
            return
        self._c_contiguous = internal.get_c_contiguity(
            self._shape, self._strides, self.itemsize)

    cpdef _update_f_contiguity(self):
        cdef Py_ssize_t i, count
        cdef vector.vector[Py_ssize_t] rev_shape, rev_strides
        if self.size == 0:
            self._f_contiguous = True
            return
        if self._c_contiguous:
            count = 0
            for i in self._shape:
                if i == 1:
                    count += 1
            self._f_contiguous = (<Py_ssize_t>self._shape.size()) - count <= 1
            return
        rev_shape.assign(self._shape.rbegin(), self._shape.rend())
        rev_strides.assign(self._strides.rbegin(), self._strides.rend())
        self._f_contiguous = internal.get_c_contiguity(
            rev_shape, rev_strides, self.itemsize)

    cpdef _update_contiguity(self):
        self._update_c_contiguity()
        self._update_f_contiguity()

    cpdef _set_shape_and_strides(self, vector.vector[Py_ssize_t]& shape,
                                 vector.vector[Py_ssize_t]& strides,
                                 bint update_c_contiguity,
                                 bint update_f_contiguity):
        if shape.size() != strides.size():
            raise ValueError('len(shape) != len(strides)')
        self._shape = shape
        self._strides = strides
        self.size = internal.prod_ssize_t(shape)
        if update_c_contiguity:
            self._update_c_contiguity()
        if update_f_contiguity:
            self._update_f_contiguity()

    cpdef _set_shape_and_contiguous_strides(
            self, vector.vector[Py_ssize_t]& shape,
            Py_ssize_t itemsize, bint is_c_contiguous):

        self.size = internal.set_contiguous_strides(
            shape, self._strides, itemsize, is_c_contiguous)
        self._shape = shape
        if is_c_contiguous:
            self._c_contiguous = True
            self._update_f_contiguity()
        else:
            self._f_contiguous = True
            self._update_c_contiguity()

    cdef function.CPointer get_pointer(self):
        return CArray(self)

    cpdef object toDlpack(self):
        """Zero-copy conversion to a DLPack tensor.

        DLPack is a open in memory tensor structure proposed in this
        repository: `dmlc/dlpack <https://github.com/dmlc/dlpack>`_.

        This function returns a :class:`PyCapsule` object which contains a
        pointer to a DLPack tensor converted from the own ndarray. This
        function does not copy the own data to the output DLpack tensor
        but it shares the pointer which is pointing to the same memory region
        for the data.

        Returns:
            dltensor (:class:`PyCapsule`): Output DLPack tensor which is
                encapsulated in a :class:`PyCapsule` object.

        .. seealso::

            :meth:`~cupy.fromDlpack` is a method for zero-copy conversion from
            a DLPack tensor (which is encapsulated in a :class:`PyCapsule`
            object) to a :class:`ndarray`

        .. admonition:: Example

            >>> import cupy
            >>> array1 = cupy.array([0, 1, 2], dtype=cupy.float32)
            >>> dltensor = array1.toDlpack()
            >>> array2 = cupy.fromDlpack(dltensor)
            >>> cupy.testing.assert_array_equal(array1, array2)

        """
        return dlpack.toDlpack(self)


cpdef int _update_order_char(ndarray x, int order_char):
    # update order_char based on array contiguity
    if order_char == b'A':
        if x._f_contiguous:
            order_char = b'F'
        else:
            order_char = b'C'
    elif order_char == b'K':
        if x._f_contiguous:
            order_char = b'F'
        elif x._c_contiguous:
            order_char = b'C'
    return order_char


cpdef vector.vector[Py_ssize_t] _get_strides_for_order_K(ndarray x, dtype):
    cdef vector.vector[Py_ssize_t] strides
    # strides used when order='K' for astype, empty_like, etc.
    stride_and_index = [
        (abs(s), -i) for i, s in enumerate(x.strides)]
    stride_and_index.sort()
    strides.resize(x.ndim)
    stride = dtype.itemsize
    for s, i in stride_and_index:
        strides[-i] = stride
        stride *= x.shape[-i]
    return strides


_HANDLED_TYPES = (ndarray, numpy.ndarray)


include "carray.pxi"


# =============================================================================
# Routines
# =============================================================================

cdef str _id = 'out0 = in0'

cdef fill_kernel = ElementwiseKernel('T x', 'T y', 'y = x', 'fill')

elementwise_copy_where = create_ufunc(
    'cupy_copy_where',
    ('??->?', 'b?->b', 'B?->B', 'h?->h', 'H?->H', 'i?->i', 'I?->I', 'l?->l',
     'L?->L', 'q?->q', 'Q?->Q', 'e?->e', 'f?->f', 'd?->d', 'F?->F', 'D?->D'),
    'if (in1) out0 = in0', default_casting='unsafe')

cdef str _divmod_float = '''
    out0_type a = _floor_divide(in0, in1);
    out0 = a;
    out1 = in0 - a * in1'''


divmod = create_ufunc(
    'cupy_divmod',
    ('bb->bb', 'BB->BB', 'hh->hh', 'HH->HH', 'ii->ii', 'II->II', 'll->ll',
     'LL->LL', 'qq->qq', 'QQ->QQ',
     ('ee->ee', _divmod_float),
     ('ff->ff', _divmod_float),
     ('dd->dd', _divmod_float)),
    '''
    if (in1 == 0) {
        out0 = 0;
        out1 = 0;
    } else {
        out0_type a = _floor_divide(in0, in1);
        out0 = a;
        out1 = in0 - a * in1;
    }''')


cdef _min_max_preamble = '''
template <typename T>
struct min_max_st{
    T value;
    int index;
    __device__ min_max_st() : index(-1) { }
    __device__ min_max_st(T v) : value(v), index(0) { }
    __device__ min_max_st(T v, int i) : value(v), index(i) { }
};

template <typename T>
inline __device__ bool is_nan(T x) {
    return x != x;
}

template <typename T>
__device__ min_max_st<T> my_min(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    return min_max_st<T>(min(a.value, b.value));
}
template <typename T>
__device__ min_max_st<T> my_min_float(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (is_nan(a.value)) return a;
    if (is_nan(b.value)) return b;
    return min_max_st<T>(min(a.value, b.value));
}
template <typename T>
__device__ min_max_st<T> my_min_complex(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (is_nan(a.value.real())) return a;
    if (is_nan(a.value.imag())) return a;
    if (is_nan(b.value.real())) return b;
    if (is_nan(b.value.imag())) return b;
    return min_max_st<T>(min(a.value, b.value));
}

template <typename T>
__device__ min_max_st<T> my_max(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    return min_max_st<T>(max(a.value, b.value));
}
template <typename T>
__device__ min_max_st<T> my_max_float(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (is_nan(a.value)) return a;
    if (is_nan(b.value)) return b;
    return min_max_st<T>(max(a.value, b.value));
}
template <typename T>
__device__ min_max_st<T> my_max_complex(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (is_nan(a.value.real())) return a;
    if (is_nan(a.value.imag())) return a;
    if (is_nan(b.value.real())) return b;
    if (is_nan(b.value.imag())) return b;
    return min_max_st<T>(max(a.value, b.value));
}

template <typename T>
__device__ min_max_st<T> my_argmin(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (a.value == b.value)
        return min_max_st<T>(a.value, min(a.index, b.index));
    return (a.value <= b.value) ? a : b;
}
template <typename T>
__device__ min_max_st<T> my_argmin_float(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (a.value == b.value)
        return min_max_st<T>(a.value, min(a.index, b.index));
    if (is_nan(a.value)) return a;
    if (is_nan(b.value)) return b;
    return (a.value <= b.value) ? a : b;
}
template <typename T>
__device__ min_max_st<T> my_argmin_complex(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (a.value == b.value)
        return min_max_st<T>(a.value, min(a.index, b.index));
    if (is_nan(a.value.real())) return a;
    if (is_nan(a.value.imag())) return a;
    if (is_nan(b.value.real())) return b;
    if (is_nan(b.value.imag())) return b;
    return (a.value <= b.value) ? a : b;
}

template <typename T>
__device__ min_max_st<T> my_argmax(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (a.value == b.value)
        return min_max_st<T>(a.value, min(a.index, b.index));
    return (a.value >= b.value) ? a : b;
}
template <typename T>
__device__ min_max_st<T> my_argmax_float(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (a.value == b.value)
        return min_max_st<T>(a.value, min(a.index, b.index));
    if (is_nan(a.value)) return a;
    if (is_nan(b.value)) return b;
    return (a.value >= b.value) ? a : b;
}
template <typename T>
__device__ min_max_st<T> my_argmax_complex(
        const min_max_st<T>& a, const min_max_st<T>& b) {
    if (a.index == -1) return b;
    if (b.index == -1) return a;
    if (a.value == b.value)
        return min_max_st<T>(a.value, min(a.index, b.index));
    if (is_nan(a.value.real())) return a;
    if (is_nan(a.value.imag())) return a;
    if (is_nan(b.value.real())) return b;
    if (is_nan(b.value.imag())) return b;
    return (a.value >= b.value) ? a : b;
}
'''


_amin = create_reduction_func(
    'cupy_min',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q',
     ('e->e', (None, 'my_min_float(a, b)', None, None)),
     ('f->f', (None, 'my_min_float(a, b)', None, None)),
     ('d->d', (None, 'my_min_float(a, b)', None, None)),
     ('F->F', (None, 'my_min_complex(a, b)', None, None)),
     ('D->D', (None, 'my_min_complex(a, b)', None, None))),
    ('min_max_st<type_in0_raw>(in0)', 'my_min(a, b)', 'out0 = a.value',
     'min_max_st<type_in0_raw>'),
    None, _min_max_preamble)


_amax = create_reduction_func(
    'cupy_max',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q',
     ('e->e', (None, 'my_max_float(a, b)', None, None)),
     ('f->f', (None, 'my_max_float(a, b)', None, None)),
     ('d->d', (None, 'my_max_float(a, b)', None, None)),
     ('F->F', (None, 'my_max_complex(a, b)', None, None)),
     ('D->D', (None, 'my_max_complex(a, b)', None, None)),
     ),
    ('min_max_st<type_in0_raw>(in0)', 'my_max(a, b)', 'out0 = a.value',
     'min_max_st<type_in0_raw>'),
    None, _min_max_preamble)


nanmin = create_reduction_func(
    'cupy_nanmin',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q', 'e->e', 'f->f', 'd->d'),
    ('min_max_st<type_in0_raw>(in0)', 'my_min(a, b)', 'out0 = a.value',
     'min_max_st<type_in0_raw>'),
    None, _min_max_preamble)


nanmax = create_reduction_func(
    'cupy_nanmax',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q', 'e->e', 'f->f', 'd->d'),
    ('min_max_st<type_in0_raw>(in0)', 'my_max(a, b)', 'out0 = a.value',
     'min_max_st<type_in0_raw>'),
    None, _min_max_preamble)


cdef _argmin = create_reduction_func(
    'cupy_argmin',
    ('?->q', 'B->q', 'h->q', 'H->q', 'i->q', 'I->q', 'l->q', 'L->q',
     'q->q', 'Q->q',
     ('e->q', (None, 'my_argmin_float(a, b)', None, None)),
     ('f->q', (None, 'my_argmin_float(a, b)', None, None)),
     ('d->q', (None, 'my_argmin_float(a, b)', None, None)),
     ('F->q', (None, 'my_argmin_complex(a, b)', None, None)),
     ('D->q', (None, 'my_argmin_complex(a, b)', None, None))),
    ('min_max_st<type_in0_raw>(in0, _J)', 'my_argmin(a, b)', 'out0 = a.index',
     'min_max_st<type_in0_raw>'),
    None, _min_max_preamble)


cdef _argmax = create_reduction_func(
    'cupy_argmax',
    ('?->q', 'B->q', 'h->q', 'H->q', 'i->q', 'I->q', 'l->q', 'L->q',
     'q->q', 'Q->q',
     ('e->q', (None, 'my_argmax_float(a, b)', None, None)),
     ('f->q', (None, 'my_argmax_float(a, b)', None, None)),
     ('d->q', (None, 'my_argmax_float(a, b)', None, None)),
     ('F->q', (None, 'my_argmax_complex(a, b)', None, None)),
     ('D->q', (None, 'my_argmax_complex(a, b)', None, None))),
    ('min_max_st<type_in0_raw>(in0, _J)', 'my_argmax(a, b)', 'out0 = a.index',
     'min_max_st<type_in0_raw>'),
    None, _min_max_preamble)


cdef _round_preamble = '''
template<typename T> __device__ T pow10(long long n){
  T x = 1, a = 10;
  while (n) {
    if (n & 1) x *= a;
    a *= a;
    n >>= 1;
  }
  return x;
};
'''


cdef _round_float = '''
if (in1 == 0) {
    out0 = round(in0);
} else {
    double x;
    x = pow10<double>(abs(in1));  // TODO(okuta): Move before loop
    out0 = in1 < 0 ? round(in0 / x) * x : round(in0 * x) / x;
}'''

cdef _round_complex = '''
double x, inv_x;
if (in1 == 0) {
    x = inv_x = 1;
} else {
    x = pow10<double>(abs(in1));  // TODO(okuta): Move before loop
    inv_x = 1.0 / x;
    if (in1 < 0) {
        double y = x;
        x = inv_x;
        inv_x = y;
    }
}
out0 = in0_type(round(in0.real() * x) * inv_x,
                round(in0.imag() * x) * inv_x);'''


_round_ufunc = create_ufunc(
    'cupy_round',
    ('?q->e',
     'bq->b', 'Bq->B', 'hq->h', 'Hq->H', 'iq->i', 'Iq->I', 'lq->l', 'Lq->L',
     'qq->q', 'Qq->Q',
     ('eq->e', _round_float),
     ('fq->f', _round_float),
     ('dq->d', _round_float),
     ('Fq->F', _round_complex),
     ('Dq->D', _round_complex)),
    '''
    if (in1 < 0) {
        // TODO(okuta): Move before loop
        long long x = pow10<long long>(-in1 - 1);
        // TODO(okuta): Check Numpy
        out0 = ((in0 / x + (in0 > 0 ? 5 : -5)) / 10) * x * 10;
    } else {
        out0 = in0;
    }''', preamble=_round_preamble)


# -----------------------------------------------------------------------------
# Array creation routines
# -----------------------------------------------------------------------------

cpdef ndarray array(obj, dtype=None, bint copy=True, order='K',
                    bint subok=False, Py_ssize_t ndmin=0):
    # TODO(beam2d): Support subok options
    cdef Py_ssize_t ndim
    cdef ndarray a, src
    cdef size_t nbytes
    if subok:
        raise NotImplementedError
    if order is None:
        order = 'K'
    if isinstance(obj, ndarray):
        src = obj
        if dtype is None:
            dtype = src.dtype
        if src.data.device_id == device.get_device_id():
            a = src.astype(dtype, order=order, copy=copy)
        else:
            a = src.copy(order=order).astype(dtype, copy=False)

        ndim = a._shape.size()
        if ndmin > ndim:
            if a is obj:
                # When `copy` is False, `a` is same as `obj`.
                a = a.view()
            a.shape = (1,) * (ndmin - ndim) + a.shape
    else:
        if order is not None and len(order) >= 1 and order[0] in 'KAka':
            if isinstance(obj, numpy.ndarray) and obj.flags.f_contiguous:
                order = 'F'
            else:
                order = 'C'
        a_cpu = numpy.array(obj, dtype=dtype, copy=False, order=order,
                            ndmin=ndmin)
        a_dtype = a_cpu.dtype
        if a_dtype.char not in '?bhilqBHILQefdFD':
            raise ValueError('Unsupported dtype %s' % a_dtype)
        a = ndarray(a_cpu.shape, dtype=a_dtype, order=order)
        if a_cpu.ndim == 0:
            a.fill(a_cpu[()])
            return a
        nbytes = a.nbytes
        stream = stream_module.get_current_stream()

        mem = None
        error = None
        try:
            mem = pinned_memory.alloc_pinned_memory(nbytes)
        except CUDARuntimeError as e:
            if e.status != runtime.errorMemoryAllocation:
                raise
            error = e

        if mem is not None:
            src_cpu = numpy.frombuffer(mem, a_dtype, a_cpu.size)
            src_cpu[:] = a_cpu.ravel(order)
            a.data.copy_from_host_async(ctypes.c_void_p(mem.ptr), nbytes)
            pinned_memory._add_to_watch_list(stream.record(), mem)
        else:
            warnings.warn(
                'Using synchronous transfer as pinned memory ({} bytes) '
                'could not be allocated. '
                'This generally occurs because of insufficient host memory. '
                'The original error was: {}'.format(nbytes, error),
                util.PerformanceWarning)
            a.data.copy_from_host(a_cpu.ctypes.get_as_parameter(), nbytes)

    return a


cpdef ndarray ascontiguousarray(ndarray a, dtype=None):
    if dtype is None:
        if a._c_contiguous:
            return a
        dtype = a.dtype
    else:
        dtype = get_dtype(dtype)
        if a._c_contiguous and dtype == a.dtype:
            return a

    newarray = ndarray(a.shape, dtype)
    elementwise_copy(a, newarray)
    return newarray


cpdef ndarray asfortranarray(ndarray a, dtype=None):
    cdef ndarray newarray
    cdef int m, n

    if dtype is None:
        if a._f_contiguous:
            return a
        dtype = a.dtype
    else:
        dtype = get_dtype(dtype)
        if a._f_contiguous and dtype == a.dtype:
            return a

    newarray = ndarray(a.shape, dtype, order='F')
    if (a.flags.c_contiguous and
            (a.dtype == numpy.float32 or a.dtype == numpy.float64) and
            a.ndim == 2 and dtype == a.dtype):
        m, n = a.shape
        handle = device.get_cublas_handle()
        if a.dtype == numpy.float32:
            cublas.sgeam(
                handle,
                1,  # transpose a
                1,  # transpose newarray
                m, n, 1., a.data.ptr, n, 0., a.data.ptr, n,
                newarray.data.ptr, m)
        elif a.dtype == numpy.float64:
            cublas.dgeam(
                handle,
                1,  # transpose a
                1,  # transpose newarray
                m, n, 1., a.data.ptr, n, 0., a.data.ptr, n,
                newarray.data.ptr, m)
        return newarray
    else:
        elementwise_copy(a, newarray)
        return newarray


# -----------------------------------------------------------------------------
# Binary operations
# -----------------------------------------------------------------------------

cpdef _create_bit_op(name, op, no_bool, doc=''):
    types = () if no_bool else ('??->?',)
    return create_ufunc(
        'cupy_' + name,
        types + ('bb->b', 'BB->B', 'hh->h', 'HH->H', 'ii->i', 'II->I', 'll->l',
                 'LL->L', 'qq->q', 'QQ->Q'),
        'out0 = in0 %s in1' % op,
        doc=doc)


bitwise_and = _create_bit_op(
    'bitwise_and', '&', False,
    '''Computes the bitwise AND of two arrays elementwise.

    Only integer and boolean arrays are handled.

    .. seealso:: :data:`numpy.bitwise_and`

    ''')


bitwise_or = _create_bit_op(
    'bitwise_or', '|', False,
    '''Computes the bitwise OR of two arrays elementwise.

    Only integer and boolean arrays are handled.

    .. seealso:: :data:`numpy.bitwise_or`

    ''')


bitwise_xor = _create_bit_op(
    'bitwise_xor', '^', False,
    '''Computes the bitwise XOR of two arrays elementwise.

    Only integer and boolean arrays are handled.

    .. seealso:: :data:`numpy.bitwise_xor`

    ''')


invert = create_ufunc(
    'cupy_invert',
    (('?->?', 'out0 = !in0'), 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I',
     'l->l', 'L->L', 'q->q', 'Q->Q'),
    'out0 = ~in0',
    doc='''Computes the bitwise NOT of an array elementwise.

    Only integer and boolean arrays are handled.

    .. seealso:: :data:`numpy.invert`

    ''')


left_shift = _create_bit_op(
    'left_shift', '<<', True,
    '''Shifts the bits of each integer element to the left.

    Only integer arrays are handled.

    .. seealso:: :data:`numpy.left_shift`

    ''')


right_shift = _create_bit_op(
    'right_shift', '>>', True,
    '''Shifts the bits of each integer element to the right.

    Only integer arrays are handled

    .. seealso:: :data:`numpy.right_shift`

    ''')

# -----------------------------------------------------------------------------
# Indexing routines
# -----------------------------------------------------------------------------

cpdef tuple _prepare_slice_list(slices, Py_ssize_t ndim):
    cdef Py_ssize_t i, n_newaxes, axis
    cdef list slice_list
    cdef char kind
    cdef bint advanced, mask_exists

    if isinstance(slices, tuple):
        slice_list = list(slices)
    elif isinstance(slices, list):
        slice_list = list(slices)  # copy list
        for s in slice_list:
            if not isinstance(s, int):
                break
        else:
            slice_list = [slice_list]
    else:
        slice_list = [slices]

    slice_list, n_newaxes = internal.complete_slice_list(slice_list, ndim)

    # Check if advanced is true,
    # and convert list/NumPy arrays to cupy.ndarray
    advanced = False
    mask_exists = False
    for i, s in enumerate(slice_list):
        to_gpu = True
        if isinstance(s, list):
            # handle the case when s is an empty list
            s = numpy.array(s)
            if s.size == 0:
                s = s.astype(numpy.int32)
        elif isinstance(s, bool):
            s = numpy.array(s)
        elif isinstance(s, ndarray):
            to_gpu = False
        elif not isinstance(s, numpy.ndarray):
            continue
        kind = ord(s.dtype.kind)
        if kind == b'i' or kind == b'u':
            advanced = True
        elif kind == b'b':
            mask_exists = True
        else:
            raise IndexError(
                'arrays used as indices must be of integer or boolean '
                'type. (actual: {})'.format(s.dtype.type))
        if to_gpu:
            slice_list[i] = array(s)

    if not mask_exists and len(slice_list) > ndim + n_newaxes:
        raise IndexError('too many indices for array')
    return slice_list, advanced, mask_exists


cdef Py_ssize_t _get_mask_index(list slice_list) except *:
    cdef Py_ssize_t i, n_not_slice_none, mask_i
    cdef slice none_slice = slice(None)
    n_not_slice_none = 0
    mask_i = -1
    for i, s in enumerate(slice_list):
        if not isinstance(s, slice) or s != none_slice:
            n_not_slice_none += 1
            if isinstance(s, ndarray) and s.dtype == numpy.bool_:
                mask_i = i
    if n_not_slice_none != 1 or mask_i == -1:
        raise ValueError('currently, CuPy only supports slices that '
                         'consist of one boolean array.')
    return mask_i


cdef tuple _prepare_advanced_indexing(ndarray a, list slice_list):
    cdef slice none_slice = slice(None)

    # split slices that can be handled by basic-indexing
    cdef list basic_slices = []
    cdef list adv_slices = []
    cdef list adv_mask = []
    cdef bint use_basic_indexing = False
    for i, s in enumerate(slice_list):
        if s is None:
            basic_slices.append(None)
            adv_slices.append(none_slice)
            adv_mask.append(False)
            use_basic_indexing = True
        elif isinstance(s, slice):
            basic_slices.append(s)
            adv_slices.append(none_slice)
            adv_mask.append(False)
            use_basic_indexing |= s != none_slice
        elif isinstance(s, ndarray):
            kind = s.dtype.kind
            assert kind == 'i' or kind == 'u'
            basic_slices.append(none_slice)
            adv_slices.append(s)
            adv_mask.append(True)
        elif isinstance(s, int):
            basic_slices.append(none_slice)
            scalar_array = ndarray((), dtype=numpy.int64)
            scalar_array.fill(s)
            adv_slices.append(scalar_array)
            adv_mask.append(True)
        else:
            raise IndexError(
                'only integers, slices (`:`), ellipsis (`...`),'
                'numpy.newaxis (`None`) and integer or '
                'boolean arrays are valid indices')

    # check if this is a combination of basic and advanced indexing
    if use_basic_indexing:
        a = _simple_getitem(a, basic_slices)

    return a, adv_slices, adv_mask

cdef ndarray _simple_getitem(ndarray a, list slice_list):
    cdef vector.vector[Py_ssize_t] shape, strides
    cdef ndarray v
    cdef Py_ssize_t i, j, offset, ndim
    cdef Py_ssize_t s_start, s_stop, s_step, dim, ind
    cdef slice ss

    # Create new shape and stride
    j = 0
    offset = 0
    ndim = a._shape.size()
    for i, s in enumerate(slice_list):
        if s is None:
            shape.push_back(1)
            if j < ndim:
                strides.push_back(a._strides[j])
            elif ndim > 0:
                strides.push_back(a._strides[ndim - 1])
            else:
                strides.push_back(a.itemsize)
        elif ndim <= j:
            raise IndexError("too many indices for array")
        elif isinstance(s, slice):
            ss = internal.complete_slice(s, a._shape[j])
            s_start = ss.start
            s_stop = ss.stop
            s_step = ss.step
            if s_step > 0:
                dim = (s_stop - s_start - 1) // s_step + 1
            else:
                dim = (s_stop - s_start + 1) // s_step + 1

            if dim == 0:
                strides.push_back(a._strides[j])
            else:
                strides.push_back(a._strides[j] * s_step)

            if s_start > 0:
                offset += a._strides[j] * s_start
            shape.push_back(dim)
            j += 1
        elif numpy.isscalar(s):
            ind = int(s)
            if ind < 0:
                ind += a._shape[j]
            if not (0 <= ind < a._shape[j]):
                msg = ('Index %s is out of bounds for axis %s with '
                       'size %s' % (s, j, a._shape[j]))
                raise IndexError(msg)
            offset += ind * a._strides[j]
            j += 1
        else:
            raise TypeError('Invalid index type: %s' % type(slice_list[i]))

    v = a.view()
    if a.size != 0:
        v.data = a.data + offset
    # TODO(niboshi): Confirm update_x_contiguity flags
    v._set_shape_and_strides(shape, strides, True, True)
    return v

cdef _take_kernel_core = '''
ptrdiff_t out_i = indices % index_range;
if (out_i < 0) out_i += index_range;
if (ldim != 1) out_i += (i / (cdim * rdim)) * index_range;
if (rdim != 1) out_i = out_i * rdim + i % rdim;
out = a[out_i];
'''

cdef _take_kernel = ElementwiseKernel(
    'raw T a, S indices, uint32 ldim, uint32 cdim, uint32 rdim, S index_range',
    'T out', _take_kernel_core, 'cupy_take')

cdef _take_kernel_scalar = ElementwiseKernel(
    'raw T a, int64 indices, uint32 ldim, uint32 cdim, uint32 rdim, '
    'int64 index_range',
    'T out', _take_kernel_core, 'cupy_take_scalar')


cdef _choose_kernel = ElementwiseKernel(
    'S a, raw T choices, int32 n_channel',
    'T y',
    'y = choices[i + n_channel * a]',
    'cupy_choose')


cdef _choose_clip_kernel = ElementwiseKernel(
    'S a, raw T choices, int32 n_channel, int32 n',
    'T y',
    '''
      S x = a;
      if (a < 0) {
        x = 0;
      } else if (a >= n) {
        x = n - 1;
      }
      y = choices[i + n_channel * x];
    ''',
    'cupy_choose_clip')


cdef _scatter_update_kernel = ElementwiseKernel(
    'T v, S indices, int32 cdim, int32 rdim, int32 adim',
    'raw T a',
    '''
      S wrap_indices = indices % adim;
      if (wrap_indices < 0) wrap_indices += adim;
      ptrdiff_t li = i / (rdim * cdim);
      ptrdiff_t ri = i % rdim;
      a[(li * adim + wrap_indices) * rdim + ri] = v;
    ''',
    'cupy_scatter_update')


cdef _scatter_add_kernel = ElementwiseKernel(
    'raw T v, S indices, int32 cdim, int32 rdim, int32 adim',
    'raw T a',
    '''
      S wrap_indices = indices % adim;
      if (wrap_indices < 0) wrap_indices += adim;
      ptrdiff_t li = i / (rdim * cdim);
      ptrdiff_t ri = i % rdim;
      atomicAdd(&a[(li * adim + wrap_indices) * rdim + ri], v[i]);
    ''',
    'cupy_scatter_add')


cdef _scatter_update_mask_kernel = ElementwiseKernel(
    'raw T v, bool mask, S mask_scanned',
    'T a',
    'if (mask) a = v[mask_scanned - 1]',
    'cupy_scatter_update_mask')


cdef _scatter_add_mask_kernel = ElementwiseKernel(
    'raw T v, bool mask, S mask_scanned',
    'T a',
    'if (mask) a = a + v[mask_scanned - 1]',
    'cupy_scatter_add_mask')


cdef _getitem_mask_kernel = ElementwiseKernel(
    'T a, bool mask, S mask_scanned',
    'raw T out',
    'if (mask) out[mask_scanned - 1] = a',
    'cupy_getitem_mask')


cpdef _prepare_mask_indexing_single(ndarray a, ndarray mask, Py_ssize_t axis):
    cdef ndarray mask_scanned, mask_br, mask_br_scanned
    cdef int n_true
    cdef tuple lshape, rshape, out_shape

    lshape = a.shape[:axis]
    rshape = a.shape[axis + mask._shape.size():]

    if mask.size == 0:
        masked_shape = lshape + (0,) + rshape
        mask_br = _manipulation._reshape(mask, masked_shape)
        return mask_br, mask_br, masked_shape

    for i, s in enumerate(mask._shape):
        if a.shape[axis + i] != s:
            raise IndexError('boolean index did not match')

    # Get number of True in the mask to determine the shape of the array
    # after masking.
    if mask.size <= 2 ** 31 - 1:
        mask_type = numpy.int32
    else:
        mask_type = numpy.int64
    mask_scanned = scan(mask.astype(mask_type).ravel())  # starts with 1
    n_true = int(mask_scanned[-1])
    masked_shape = lshape + (n_true,) + rshape

    # When mask covers the entire array, broadcasting is not necessary.
    if mask._shape.size() == a._shape.size() and axis == 0:
        return (
            mask,
            _manipulation._reshape(mask_scanned, mask._shape),
            masked_shape)
    mask_scanned = None

    # The scan of the broadcasted array is used to index on kernel.
    mask = _manipulation._reshape(
        mask,
        axis * (1,) + mask.shape + (a.ndim - axis - mask.ndim) * (1,))
    if mask._shape.size() > a._shape.size():
        raise IndexError('too many indices for array')

    mask = _manipulation.broadcast_to(mask, a.shape)
    if mask.size <= 2 ** 31 - 1:
        mask_type = numpy.int32
    else:
        mask_type = numpy.int64
    mask_scanned = _manipulation._reshape(
        scan(mask.astype(mask_type).ravel()),
        mask._shape)
    return mask, mask_scanned, masked_shape


cpdef ndarray _getitem_mask_single(ndarray a, ndarray mask, int axis):
    cdef ndarray mask_scanned
    cdef tuple masked_shape

    mask, mask_scanned, masked_shape = _prepare_mask_indexing_single(
        a, mask, axis)
    out = ndarray(masked_shape, dtype=a.dtype)
    if out.size == 0:
        return out
    return _getitem_mask_kernel(a, mask, mask_scanned, out)


cpdef ndarray _take(ndarray a, indices, int li, int ri, ndarray out=None):
    # When li + 1 == ri this function behaves similarly to np.take
    cdef tuple out_shape, ind_shape, indices_shape
    cdef int i, ndim = a._shape.size()
    cdef Py_ssize_t ldim, cdim, rdim, index_range
    if ndim == 0:
        a = a.ravel()
        ndim = 1

    if not (-ndim <= li < ndim and -ndim <= ri < ndim):
        raise _errors._AxisError('Axis overrun')

    if ndim == 1:
        li = ri = 0
    else:
        li %= ndim
        ri %= ndim
        assert 0 <= li <= ri

    if numpy.isscalar(indices):
        indices_shape = ()
        cdim = 1
    else:
        if not isinstance(indices, ndarray):
            indices = array(indices, dtype=int)
        indices_shape = indices.shape
        cdim = indices.size

    ldim = rdim = 1
    if ndim == 1:
        out_shape = indices_shape
        index_range = a.size
    else:
        a_shape = a.shape
        out_shape = a_shape[:li] + indices_shape + a_shape[ri + 1:]
        if len(indices_shape) != 0:
            indices = _manipulation._reshape(
                indices,
                (1,) * li + indices_shape + (1,) * (ndim - (ri + 1)))
        for i in range(li):
            ldim *= a._shape[i]
        for i in range(ri + 1, ndim):
            rdim *= a._shape[i]
        index_range = a.size // (ldim * rdim)

    if out is None:
        out = ndarray(out_shape, dtype=a.dtype)
    else:
        if out.dtype != a.dtype:
            raise TypeError('Output dtype mismatch')
        if out.shape != out_shape:
            raise ValueError('Output shape mismatch')
    if a.size == 0 and out.size != 0:
        raise IndexError('cannot do a non-empty take from an empty axes.')

    if isinstance(indices, ndarray):
        return _take_kernel(
            a.reduced_view(), indices, ldim, cdim, rdim, index_range, out)
    else:
        return _take_kernel_scalar(
            a.reduced_view(), indices, ldim, cdim, rdim, index_range, out)


cpdef _scatter_op_single(ndarray a, ndarray indices, v,
                         Py_ssize_t li=0, Py_ssize_t ri=0, op=''):
    # When op == 'update', this function behaves similarly to
    # a code below using NumPy under the condition that a = a._reshape(shape)
    # does not invoke copy.
    #
    # shape = a[:li] +\
    #     (numpy.prod(a[li:ri+1]),) + a[ri+1:]
    # a = a._reshape(shape)
    # slices = (slice(None),) * li + indices +\
    #     (slice(None),) * (a.ndim - indices.ndim - ri)
    # a[slices] = v
    cdef Py_ssize_t ndim, adim, cdim, rdim
    cdef tuple a_shape, indices_shape, lshape, rshape, v_shape

    ndim = a._shape.size()

    if ndim == 0:
        raise ValueError("requires a.ndim >= 1")
    if not (-ndim <= li < ndim and -ndim <= ri < ndim):
        raise ValueError('Axis overrun')

    if not isinstance(v, ndarray):
        v = array(v, dtype=a.dtype)
    else:
        v = v.astype(a.dtype, copy=False)

    a_shape = a.shape
    li %= ndim
    ri %= ndim

    lshape = a_shape[:li]
    rshape = a_shape[ri + 1:]
    adim = internal.prod(a_shape[li:ri + 1])

    indices_shape = indices.shape
    v_shape = lshape + indices_shape + rshape
    v = _manipulation.broadcast_to(v, v_shape)

    cdim = indices.size
    rdim = internal.prod(rshape)
    indices = _manipulation._reshape(
        indices,
        (1,) * len(lshape) + indices_shape + (1,) * len(rshape))
    indices = _manipulation.broadcast_to(indices, v_shape)

    if op == 'update':
        _scatter_update_kernel(
            v, indices, cdim, rdim, adim, a.reduced_view())
    elif op == 'add':
        # There is constraints on types because atomicAdd() in CUDA 7.5
        # only supports int32, uint32, uint64, and float32.
        if not issubclass(v.dtype.type,
                          (numpy.int32, numpy.float16, numpy.float32,
                           numpy.float64, numpy.uint32, numpy.uint64,
                           numpy.ulonglong)):
            raise TypeError(
                'scatter_add only supports int32, float16, float32, float64, '
                'uint32, uint64, as data type')
        _scatter_add_kernel(
            v, indices, cdim, rdim, adim, a.reduced_view())
    else:
        raise ValueError('provided op is not supported')


cpdef _scatter_op_mask_single(ndarray a, ndarray mask, v, Py_ssize_t axis, op):
    cdef ndarray mask_scanned, src
    cdef tuple masked_shape

    mask, mask_scanned, masked_shape = _prepare_mask_indexing_single(
        a, mask, axis)
    if internal.prod(masked_shape) == 0:
        return

    if not isinstance(v, ndarray):
        src = array(v, dtype=a.dtype)
    else:
        src = v
        src = src.astype(a.dtype, copy=False)
    # broadcast src to shape determined by the mask
    src = _manipulation.broadcast_to(src, masked_shape)

    if op == 'update':
        _scatter_update_mask_kernel(src, mask, mask_scanned, a)
    elif op == 'add':
        _scatter_add_mask_kernel(src, mask, mask_scanned, a)
    else:
        raise ValueError('provided op is not supported')


cpdef _scatter_op(ndarray a, slices, value, op):
    cdef Py_ssize_t i, li, ri
    cdef ndarray v, x, y, a_interm, reduced_idx
    cdef list slice_list, adv_mask, adv_slices
    cdef bint advanced, mask_exists

    slice_list, advanced, mask_exists = _prepare_slice_list(
        slices, a._shape.size())

    if mask_exists:
        mask_i = _get_mask_index(slice_list)
        _scatter_op_mask_single(a, slice_list[mask_i], value, mask_i, op)
        return

    if advanced:
        a, adv_slices, adv_mask = _prepare_advanced_indexing(a, slice_list)
        if sum(adv_mask) == 1:
            axis = adv_mask.index(True)
            _scatter_op_single(a, adv_slices[axis], value, axis, axis, op)
            return

        # scatter_op with multiple integer arrays
        a_interm, reduced_idx, li, ri =\
            _prepare_multiple_array_indexing(a, adv_slices)
        _scatter_op_single(a_interm, reduced_idx, value, li, ri, op)
        return

    y = _simple_getitem(a, slice_list)
    if op == 'update':
        if not isinstance(value, ndarray):
            y.fill(value)
            return
        x = value
        if (internal.vector_equal(y._shape, x._shape) and
                internal.vector_equal(y._strides, x._strides)):
            if y.data.ptr == x.data.ptr:
                return  # Skip since x and y are the same array
            elif y._c_contiguous and x.dtype == y.dtype:
                y.data.copy_from_device_async(x.data, x.nbytes)
                return
        elementwise_copy(x, y)
        return
    if op == 'add':
        add(y, value, y)
        return
    raise ValueError('this op is not supported')


cpdef ndarray _diagonal(ndarray a, Py_ssize_t offset=0, Py_ssize_t axis1=0,
                        Py_ssize_t axis2=1):
    cdef Py_ssize_t ndim = a.ndim
    if not (-ndim <= axis1 < ndim and -ndim <= axis2 < ndim):
        raise _errors._AxisError(
            'axis1(={0}) and axis2(={1}) must be within range '
            '(ndim={2})'.format(axis1, axis2, ndim))

    axis1 %= ndim
    axis2 %= ndim
    if axis1 < axis2:
        min_axis, max_axis = axis1, axis2
    else:
        min_axis, max_axis = axis2, axis1

    tr = list(range(ndim))
    del tr[max_axis]
    del tr[min_axis]
    if offset >= 0:
        a = _manipulation._transpose(a, tr + [axis1, axis2])
    else:
        a = _manipulation._transpose(a, tr + [axis2, axis1])
        offset = -offset

    diag_size = max(0, min(a.shape[-2], a.shape[-1] - offset))
    ret_shape = a.shape[:-2] + (diag_size,)
    if diag_size == 0:
        return ndarray(ret_shape, dtype=a.dtype)

    a = a[..., :diag_size, offset:offset + diag_size]

    ret = a.view()
    # TODO(niboshi): Confirm update_x_contiguity flags
    ret._set_shape_and_strides(
        a.shape[:-2] + (diag_size,),
        a.strides[:-2] + (a.strides[-1] + a.strides[-2],),
        True, True)
    return ret


cpdef tuple _prepare_multiple_array_indexing(ndarray a, list slices):
    # slices consist of either slice(None) or ndarray
    cdef Py_ssize_t i, p, li, ri, max_index
    cdef ndarray take_idx, input_flat, out_flat, ret
    cdef tuple a_shape

    br = _manipulation.broadcast(*slices)
    slices = list(br.values)

    # check if transpose is necessasry
    # li:  index of the leftmost array in slices
    # ri:  index of the rightmost array in slices
    do_transpose = False
    prev_arr_i = None
    li = 0
    ri = 0
    for i, s in enumerate(slices):
        if isinstance(s, ndarray):
            if prev_arr_i is None:
                prev_arr_i = i
                li = i
            elif prev_arr_i is not None and i - prev_arr_i > 1:
                do_transpose = True
            else:
                prev_arr_i = i
                ri = i

    if do_transpose:
        transp_a = []
        transp_b = []
        slices_a = []
        slices_b = []

        for i, s in enumerate(slices):
            if isinstance(s, ndarray):
                transp_a.append(i)
                slices_a.append(s)
            else:
                transp_b.append(i)
                slices_b.append(s)
        a = _manipulation._transpose(a, transp_a + transp_b)
        slices = slices_a + slices_b
        li = 0
        ri = len(transp_a) - 1

    a_interm_shape = a.shape
    a_interm = a

    # build the strides
    strides = [1]
    for s in a.shape[ri:li:-1]:
        strides.insert(0, s * strides[0])

    flattened_indexes = []
    for stride, s, a_interm_shape_i in zip(
            strides, slices[li:ri + 1], a_interm_shape[li:ri + 1]):
        max_index = stride * (a_interm_shape_i - 1)
        # cast to appropriate dtype if the linearized index can
        # exceed the range of the original dtype.
        dtype = None
        if max_index >= 2**31 and issubclass(
                s.dtype.type, (numpy.int8, numpy.int16, numpy.int32)):
            dtype = numpy.int64
        elif max_index >= 2**15 and issubclass(
                s.dtype.type, (numpy.int8, numpy.int16)):
            dtype = numpy.int32
        elif max_index >= 2**7 and issubclass(s.dtype.type, numpy.int8):
            dtype = numpy.int16

        if max_index >= 2**32 and issubclass(
                s.dtype.type, (numpy.uint8, numpy.uint16, numpy.uint32)):
            dtype = numpy.uint64
        elif max_index >= 2**16 and issubclass(
                s.dtype.type, (numpy.uint8, numpy.uint16)):
            dtype = numpy.uint32
        elif max_index >= 2**8 and issubclass(s.dtype.type, numpy.uint8):
            dtype = numpy.uint16

        if dtype is not None:
            s = s.astype(dtype)
        # wrap all out-of-bound indices
        flattened_indexes.append(stride * (s % a_interm_shape_i))

    # do stack: flattened_indexes = stack(flattened_indexes, axis=0)
    concat_shape = (len(flattened_indexes),) + br.shape
    flattened_indexes = _manipulation._concatenate(
        [
            _manipulation._reshape(index, (1,) + index.shape)
            for index in flattened_indexes],
        axis=0, shape=concat_shape, dtype=flattened_indexes[0].dtype)

    reduced_idx = _sum_auto_dtype(flattened_indexes, axis=0)

    return a_interm, reduced_idx, li, ri


cpdef ndarray _getitem_multiple(ndarray a, list slices):
    a, reduced_idx, li, ri = _prepare_multiple_array_indexing(a, slices)
    return _take(a, reduced_idx, li, ri)


# -----------------------------------------------------------------------------
# Linear algebra
# -----------------------------------------------------------------------------

cpdef ndarray dot(ndarray a, ndarray b, ndarray out=None):
    cdef Py_ssize_t a_ndim, b_ndim, a_axis, b_axis, n, m, k
    cdef bint input_a_is_vec, input_b_is_vec
    cdef vector.vector[Py_ssize_t] ret_shape
    cdef vector.vector[Py_ssize_t] shape

    a_ndim = a._shape.size()
    b_ndim = b._shape.size()

    if out is not None and numpy.result_type(a.dtype, b.dtype) != out.dtype:
        raise ValueError('Not supported dtype combination.')

    if a_ndim == 0 or b_ndim == 0:
        return multiply(a, b, out=out)

    input_a_is_vec = a_ndim == 1
    input_b_is_vec = b_ndim == 1
    if input_a_is_vec:
        shape.clear()
        shape.push_back(1)
        shape.push_back(a.size)
        a = _manipulation._reshape(a, shape)
        a_ndim = 2
    if input_b_is_vec:
        shape.clear()
        shape.push_back(b.size)
        shape.push_back(1)
        b = _manipulation._reshape(b, shape)
        b_ndim = 2

    a_axis = a_ndim - 1
    b_axis = b_ndim - 2

    if a._shape[a_axis] != b._shape[b_axis]:
        raise ValueError('Axis dimension mismatch')

    if a_axis:
        a = _manipulation.rollaxis(a, a_axis, 0)
    if b_axis:
        b = _manipulation.rollaxis(b, b_axis, 0)

    k = a._shape[0]
    if k != 0:
        m = b.size // k
        n = a.size // k
    else:
        # When k==0, the function must return a matrix filled with zero
        # like NumPy.
        m = 0
        n = 0

    if not input_a_is_vec:
        ret_shape.insert(ret_shape.end(), a._shape.begin() + 1, a._shape.end())
    if not input_b_is_vec:
        ret_shape.insert(ret_shape.end(), b._shape.begin() + 1, b._shape.end())
    if out is not None:
        if k != 0 and out.size != n * m:
            raise ValueError('Output array has an invalid size')
        if not out._c_contiguous:
            raise ValueError('Output array must be C-contiguous')

    return tensordot_core(a, b, out, n, m, k, ret_shape)


cdef _mat_ptrs_kernel = ElementwiseKernel(
    'T base, T stride', 'T out',
    'out = base + _ind.get()[_ind.ndim - 1] * stride', 'mat_ptrs',
    reduce_dims=False)


cdef ndarray _mat_ptrs(ndarray a):
    """Creates an array of pointers to matrices
    Args:
        a: A batch of matrices on GPU.
           shape: (A, B, C) -> A ptrs to mat o size (B, C)
           shape: (A_1, ..., A_N, B, C) -> A_1*...*A_N ptrs to mat of
                  size (B, C)
    Returns:
        GPU array of pointers to matrices.
    """
    cdef int ndim = a._shape.size()
    assert ndim > 2
    cdef Py_ssize_t sh_, st_
    cdef ndarray idx
    idx = _mat_ptrs_kernel(
        a.data.ptr, a._strides[0],
        cupy.ndarray((a._shape[0],), dtype=numpy.uintp))

    for i in range(1, ndim - 2):
        idx = _mat_ptrs_kernel(
            idx[:, None], a._strides[i],
            cupy.ndarray((idx.size, a._shape[i]), dtype=numpy.uintp))
        idx = idx.ravel()
    return idx


cdef Py_ssize_t _get_stride_for_strided_batched_gemm(ndarray a) except?0:
    cdef int ndim = a._shape.size()
    assert ndim > 2
    return a._strides[ndim - 3] // <Py_ssize_t>a.itemsize


cpdef ndarray matmul(ndarray a, ndarray b, ndarray out=None):
    """ Returns the matrix product of two arrays and is the implementation of
    the `@` operator introduced in Python 3.5 following PEP465.

    The main difference against cupy.dot are the handling of arrays with more
    than 2 dimensions. For more information see :func:`numpy.matmul`.

    .. note::
        The out array as input is currently not supported.

    Args:
        a (cupy.ndarray): The left argument.
        b (cupy.ndarray): The right argument.
        out (cupy.ndarray): Output array.

    Returns:
        cupy.ndarray: Output array.

    .. seealso:: :func:`numpy.matmul`

    """

    if out is not None:
        raise NotImplementedError('The out array as input is currently not '
                                  'supported')

    cdef Py_ssize_t i, n, m, ka, kb, a_sh, b_sh, c_sh
    cdef Py_ssize_t batchCount, a_part_outshape, b_part_outshape
    cdef int orig_a_ndim, orig_b_ndim, a_ndim, b_ndim, ndim
    cdef ndarray ap, bp, outp, out_view
    cdef bint use_broadcast

    orig_a_ndim = a._shape.size()
    orig_b_ndim = b._shape.size()
    if orig_a_ndim == 0 or orig_b_ndim == 0:
        raise ValueError('Scalar operands are not allowed, use \'*\' instead')

    ndim = max(orig_a_ndim, orig_b_ndim)
    if ndim <= 2:
        return dot(a, b, out)

    orig_a = a
    orig_b = b
    a_part_outshape = b_part_outshape = 0
    if orig_a_ndim == 1:
        a = _manipulation._reshape(a, (1, a.size))
    else:
        a = a.view()
        a_part_outshape = a._shape[orig_a_ndim - 2]
    if orig_b_ndim == 1:
        b = _manipulation._reshape(b, (b.size, 1))
        ldout = 1
    else:
        b = b.view()
        b_part_outshape = ldout = b._shape[orig_b_ndim - 1]

    # expand dims
    a_ndim = a._shape.size()
    b_ndim = b._shape.size()
    if a_ndim < ndim:
        # TODO(niboshi): Confirm update_x_contiguity flags
        a._set_shape_and_strides(
            (1,) * (ndim - a_ndim) + a.shape,
            (0,) * (ndim - a_ndim) + a.strides,
            True, True)
    if b_ndim < ndim:
        # TODO(niboshi): Confirm update_x_contiguity flags
        b._set_shape_and_strides(
            (1,) * (ndim - b_ndim) + b.shape,
            (0,) * (ndim - b_ndim) + b.strides,
            True, True)

    ret_dtype = numpy.result_type(a.dtype, b.dtype)
    dtype = numpy.find_common_type((ret_dtype, 'f'), ())

    a = ascontiguousarray(a, dtype)
    b = ascontiguousarray(b, dtype)

    # broadcast
    batchCount = 1  # batchCount = numpy.prod(out_shape[:-2])
    out_shape = []
    use_broadcast = False
    for i in range(0, ndim - 2):
        a_sh = a._shape[i]
        b_sh = b._shape[i]
        if a_sh != b_sh and a_sh != 1 and b_sh != 1:
            raise ValueError(
                'operands could not be broadcast together with '
                'remapped shapes')

        if a_sh == 0 or b_sh == 0:
            c_sh = 0
        else:
            c_sh = max(a_sh, b_sh)
        batchCount *= c_sh
        out_shape.append(c_sh)
        if a_sh == 1 and c_sh > 1:
            a._strides[i] = 0
            a._shape[i] = c_sh
            a._c_contiguous = a._f_contiguous = False
            use_broadcast = True

        if b_sh == 1 and c_sh > 1:
            b._strides[i] = 0
            b._shape[i] = c_sh
            b._c_contiguous = b._f_contiguous = False
            use_broadcast = True

    if orig_a_ndim != 1:
        out_shape.append(a_part_outshape)
    if orig_b_ndim != 1:
        out_shape.append(b_part_outshape)

    # (A B)^T = B^T A^T
    a, b = b, a

    ka = a._shape[ndim - 2]
    lda = n = a._shape[ndim - 1]
    m = b._shape[ndim - 2]
    ldb = kb = b._shape[ndim - 1]

    if ka != kb:
        raise ValueError(
            'shapes ({}) and ({}) not aligned'.format(
                ','.join([str(_) for _ in orig_a.shape]),
                ','.join([str(_) for _ in orig_b.shape])))

    if a.size == 0 or b.size == 0:
        return cupy.zeros(out_shape, ret_dtype)

    out = ndarray(out_shape, dtype=dtype)

    if orig_a_ndim == 1 or orig_b_ndim == 1:
        out_view = out.view()
        if orig_b_ndim == 1:
            out_view._shape.push_back(1)
            out_view._strides.push_back(0)
        if orig_a_ndim == 1:
            out_view._shape.insert(out_view._shape.end() - 1, 1)
            out_view._strides.insert(out_view._strides.end() - 1, 0)
        assert out_view._c_contiguous
        out_view._update_f_contiguity()
    else:
        out_view = out

    global _cuda_runtime_version
    if _cuda_runtime_version < 0:
        _cuda_runtime_version = runtime.runtimeGetVersion()

    handle = device.get_cublas_handle()

    # TODO(anaruse) use cublasGemmStridedBatchedEx() when cuda version >= 9.1
    if not use_broadcast:
        strideA = _get_stride_for_strided_batched_gemm(a)
        strideB = _get_stride_for_strided_batched_gemm(b)
        strideC = _get_stride_for_strided_batched_gemm(out_view)
        if dtype == numpy.float32:
            cublas.sgemmStridedBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1.0,
                a.data.ptr, lda, strideA,
                b.data.ptr, ldb, strideB,
                0.0, out_view.data.ptr, ldout, strideC,
                batchCount)
        elif dtype == numpy.float64:
            cublas.dgemmStridedBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1.0,
                a.data.ptr, lda, strideA,
                b.data.ptr, ldb, strideB,
                0.0, out_view.data.ptr, ldout, strideC,
                batchCount)
        elif dtype == numpy.complex64:
            cublas.cgemmStridedBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1,
                a.data.ptr, lda, strideA,
                b.data.ptr, ldb, strideB,
                0, out_view.data.ptr, ldout, strideC,
                batchCount)
        elif dtype == numpy.complex128:
            cublas.zgemmStridedBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1,
                a.data.ptr, lda, strideA,
                b.data.ptr, ldb, strideB,
                0, out_view.data.ptr, ldout, strideC,
                batchCount)
        else:
            raise TypeError(dtype, a.dtype, b.dtype)
    else:
        ap = _mat_ptrs(a)
        bp = _mat_ptrs(b)
        outp = _mat_ptrs(out_view)
        if dtype == numpy.float32:
            cublas.sgemmBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1.0,
                ap.data.ptr, lda,
                bp.data.ptr, ldb,
                0.0, outp.data.ptr, ldout, batchCount)
        elif dtype == numpy.float64:
            cublas.dgemmBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1.0,
                ap.data.ptr, lda,
                bp.data.ptr, ldb,
                0.0, outp.data.ptr, ldout, batchCount)
        elif dtype == numpy.complex64:
            cublas.cgemmBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1,
                ap.data.ptr, lda,
                bp.data.ptr, ldb,
                0, outp.data.ptr, ldout, batchCount)
        elif dtype == numpy.complex128:
            cublas.zgemmBatched(
                handle,
                0,  # transa
                0,  # transb
                n, m, ka, 1,
                ap.data.ptr, lda,
                bp.data.ptr, ldb,
                0, outp.data.ptr, ldout, batchCount)
        else:
            raise TypeError(dtype, a.dtype, b.dtype)

    if dtype == ret_dtype:
        return out
    else:
        ret = ndarray(out_shape, ret_dtype)
        elementwise_copy(out, ret)
        return ret


cdef int _cuda_runtime_version = -1
cdef _tensordot_core_mul_sum = ReductionKernel(
    'S x, T y', 'U out',
    'static_cast<U>(x) * static_cast<U>(y)',
    'a + b', 'out = a', '0', '_tensordot_core_mul_sum')


cpdef ndarray tensordot_core(
        ndarray a, ndarray b, ndarray out, Py_ssize_t n, Py_ssize_t m,
        Py_ssize_t k, vector.vector[Py_ssize_t] ret_shape):
    cdef vector.vector[Py_ssize_t] shape
    cdef Py_ssize_t inca, incb, transa, transb, lda, ldb
    cdef Py_ssize_t mode, handle
    cdef bint use_sgemmEx
    cdef float one_fp32, zero_fp32
    ret_dtype = a.dtype.char
    if ret_dtype != b.dtype.char:
        ret_dtype = numpy.find_common_type((ret_dtype, b.dtype), ()).char

    if not a.size or not b.size:
        if out is None:
            out = ndarray(ret_shape, dtype=ret_dtype)
        out.fill(0)
        return out

    global _cuda_runtime_version
    if _cuda_runtime_version < 0:
        _cuda_runtime_version = runtime.runtimeGetVersion()

    use_sgemmEx = (a.dtype == 'e' and b.dtype == 'e' and
                   (ret_dtype == 'e' or ret_dtype == 'f'))
    use_tensor_core = (use_sgemmEx and
                       _cuda_runtime_version >= 9000 and
                       int(device.get_compute_capability()) == 70)

    if use_sgemmEx or ret_dtype in 'fdFD':
        dtype = ret_dtype
    else:
        dtype = numpy.find_common_type((ret_dtype, 'f'), ()).char

    if out is None:
        out = ndarray(ret_shape, dtype)
        if dtype == ret_dtype:
            ret = out
        else:
            ret = ndarray(ret_shape, ret_dtype)
    else:
        ret = out
        if out.dtype != dtype:
            out = ndarray(ret_shape, dtype)

    if m == 1 and n == 1:
        _tensordot_core_mul_sum(
            a.ravel(), b.ravel(), _manipulation._reshape(out, ()))
        if out is not ret:
            elementwise_copy(out, ret)
        return ret

    # It copies the operands if needed
    if a._shape.size() != 2 or a._shape[0] != k or a._shape[1] != n:
        shape.clear()
        shape.push_back(k)
        shape.push_back(n)
        a = _manipulation._reshape(a, shape)
    if b._shape.size() != 2 or b._shape[0] != k or b._shape[1] != m:
        shape.clear()
        shape.push_back(k)
        shape.push_back(m)
        b = _manipulation._reshape(b, shape)
    c = out
    if c._shape.size() != 2 or c._shape[0] != n or c._shape[1] != m:
        c = c.view()
        c.shape = (n, m)

    if not use_sgemmEx:
        a = a.astype(dtype, copy=False)
        b = b.astype(dtype, copy=False)

    # Be careful that cuBLAS uses the FORTRAN-order matrix representation.
    handle = device.get_cublas_handle()
    # Matrix-Matrix product A^T * B
    # c is C-contiguous while cuBLAS assumes F-contiguous inputs, so we
    # compute C^T = B^T * A here.
    a, transa, lda = _mat_to_cublas_contiguous(a, 0)
    b, transb, ldb = _mat_to_cublas_contiguous(b, 1)
    if use_sgemmEx:
        Ctype = runtime.CUDA_R_16F if c.dtype == 'e' else runtime.CUDA_R_32F
        if use_tensor_core:
            one_fp32 = 1
            zero_fp32 = 0
            cublas.setMathMode(handle, cublas.CUBLAS_TENSOR_OP_MATH)
            cublas.gemmEx(
                handle, <int>transb, <int> transa, <int>m, <int>n, <int>k,
                <size_t>&one_fp32,
                b.data.ptr, runtime.CUDA_R_16F, <int>ldb,
                a.data.ptr, runtime.CUDA_R_16F, <int>lda,
                <size_t>&zero_fp32,
                c.data.ptr, Ctype, <int>m,
                runtime.CUDA_R_32F, cublas.CUBLAS_GEMM_DEFAULT_TENSOR_OP)
            cublas.setMathMode(handle, cublas.CUBLAS_DEFAULT_MATH)
        else:
            cublas.sgemmEx(
                handle, <int>transb, <int> transa, <int>m, <int>n, <int>k, 1,
                b.data.ptr, runtime.CUDA_R_16F, <int>ldb, a.data.ptr,
                runtime.CUDA_R_16F, <int>lda, 0, c.data.ptr, Ctype, <int>m)
    elif dtype == 'f':
        cublas.sgemmEx(
            handle, <int>transb, <int> transa, <int>m, <int>n, <int>k, 1,
            b.data.ptr, runtime.CUDA_R_32F, <int>ldb,
            a.data.ptr, runtime.CUDA_R_32F, <int>lda, 0,
            c.data.ptr, runtime.CUDA_R_32F, <int>m)
    elif dtype == 'd':
        cublas.dgemm(
            handle, <int>transb, <int>transa, <int>m, <int>n, <int>k, 1,
            b.data.ptr, <int>ldb, a.data.ptr, <int>lda, 0, c.data.ptr, <int>m)
    elif dtype == 'F':
        cublas.cgemm(
            handle, <int>transb, <int>transa, <int>m, <int>n, <int>k, 1,
            b.data.ptr, <int>ldb, a.data.ptr, <int>lda, 0, c.data.ptr, <int>m)
    elif dtype == 'D':
        cublas.zgemm(
            handle, <int>transb, <int>transa, <int>m, <int>n, <int>k, 1,
            b.data.ptr, <int>ldb, a.data.ptr, <int>lda, 0, c.data.ptr, <int>m)
    else:
        raise ValueError('Invalid dtype: %s' % str(dtype))

    if out is not ret:
        elementwise_copy(out, ret)
    return ret


@cython.profile(False)
cpdef inline tuple _mat_to_cublas_contiguous(ndarray a, Py_ssize_t trans):
    assert a.ndim == 2
    if a._f_contiguous:
        # builtin max function is not used for Cython 0.23
        lda = a._strides[1] // a.itemsize
        if lda < a._shape[0]:
            lda = a._shape[0]
        return a, trans, lda
    if not a._c_contiguous:
        a = a.copy()
    return a, 1 - trans, a._strides[0] // a.itemsize


@cython.profile(False)
cpdef inline tuple _to_cublas_vector(ndarray a, Py_ssize_t rundim):
    if a._strides[rundim] < 0:
        return a.copy(), 1
    else:
        return a, a._strides[rundim] // a.itemsize

# -----------------------------------------------------------------------------
# Logic functions
# -----------------------------------------------------------------------------

cpdef create_comparison(name, op, doc='', no_complex_dtype=True):

    if no_complex_dtype:
        ops = ('??->?', 'bb->?', 'BB->?', 'hh->?', 'HH->?', 'ii->?', 'II->?',
               'll->?', 'LL->?', 'qq->?', 'QQ->?', 'ee->?', 'ff->?', 'dd->?')
    else:
        ops = ('??->?', 'bb->?', 'BB->?', 'hh->?', 'HH->?', 'ii->?', 'II->?',
               'll->?', 'LL->?', 'qq->?', 'QQ->?', 'ee->?', 'ff->?', 'dd->?',
               'FF->?', 'DD->?')

    return create_ufunc(
        'cupy_' + name,
        ops,
        'out0 = in0 %s in1' % op,
        doc=doc)


greater = create_comparison(
    'greater', '>',
    '''Tests elementwise if ``x1 > x2``.

    .. seealso:: :data:`numpy.greater`

    ''',
    no_complex_dtype=False)


greater_equal = create_comparison(
    'greater_equal', '>=',
    '''Tests elementwise if ``x1 >= x2``.

    .. seealso:: :data:`numpy.greater_equal`

    ''',
    no_complex_dtype=False)


less = create_comparison(
    'less', '<',
    '''Tests elementwise if ``x1 < x2``.

    .. seealso:: :data:`numpy.less`

    ''',
    no_complex_dtype=False)


less_equal = create_comparison(
    'less_equal', '<=',
    '''Tests elementwise if ``x1 <= x2``.

    .. seealso:: :data:`numpy.less_equal`

    ''',
    no_complex_dtype=False)


equal = create_comparison(
    'equal', '==',
    '''Tests elementwise if ``x1 == x2``.

    .. seealso:: :data:`numpy.equal`

    ''',
    no_complex_dtype=False)


not_equal = create_comparison(
    'not_equal', '!=',
    '''Tests elementwise if ``x1 != x2``.

    .. seealso:: :data:`numpy.equal`

    ''',
    no_complex_dtype=False)


_all = create_reduction_func(
    'cupy_all',
    ('?->?', 'B->?', 'h->?', 'H->?', 'i->?', 'I->?', 'l->?', 'L->?',
     'q->?', 'Q->?', 'e->?', 'f->?', 'd->?', 'F->?', 'D->?'),
    ('in0 != type_in0_raw(0)', 'a & b', 'out0 = a', 'bool'),
    'true', '')


_any = create_reduction_func(
    'cupy_any',
    ('?->?', 'B->?', 'h->?', 'H->?', 'i->?', 'I->?', 'l->?', 'L->?',
     'q->?', 'Q->?', 'e->?', 'f->?', 'd->?', 'F->?', 'D->?'),
    ('in0 != type_in0_raw(0)', 'a | b', 'out0 = a', 'bool'),
    'false', '')


# -----------------------------------------------------------------------------
# Mathematical functions
# -----------------------------------------------------------------------------

_sum_auto_dtype = create_reduction_func(
    'cupy_sum',
    ('?->l', 'b->l', 'B->L', 'h->l', 'H->L', 'i->l', 'I->L', 'l->l', 'L->L',
     'q->q', 'Q->Q',
     ('e->e', (None, None, None, 'float')),
     'f->f', 'd->d', 'F->F', 'D->D'),
    ('in0', 'a + b', 'out0 = type_out0_raw(a)', None), 0)


_sum_keep_dtype = create_reduction_func(
    'cupy_sum_with_dtype',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q',
     ('e->e', (None, None, None, 'float')),
     'f->f', 'd->d', 'F->F', 'D->D'),
    ('in0', 'a + b', 'out0 = type_out0_raw(a)', None), 0)


_prod_auto_dtype = create_reduction_func(
    'cupy_prod',
    ('?->l', 'b->l', 'B->L', 'h->l', 'H->L', 'i->l', 'I->L', 'l->l', 'L->L',
     'q->q', 'Q->Q',
     ('e->e', (None, None, None, 'float')),
     'f->f', 'd->d', 'F->F', 'D->D'),
    ('in0', 'a * b', 'out0 = type_out0_raw(a)', None), 1)


_prod_keep_dtype = create_reduction_func(
    'cupy_prod_with_dtype',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q',
     ('e->e', (None, None, None, 'float')),
     'f->f', 'd->d', 'F->F', 'D->D'),
    ('in0', 'a * b', 'out0 = type_out0_raw(a)', None), 1)


cdef create_arithmetic(name, op, boolop, doc):
    return create_ufunc(
        'cupy_' + name,
        (('??->?', 'out0 = in0 %s in1' % boolop),
         'bb->b', 'BB->B', 'hh->h', 'HH->H', 'ii->i', 'II->I', 'll->l',
         'LL->L', 'qq->q', 'QQ->Q', 'ee->e', 'ff->f', 'dd->d', 'FF->F',
         'DD->D'),
        'out0 = in0 %s in1' % op,
        doc=doc)


add = create_arithmetic(
    'add', '+', '|',
    '''Adds two arrays elementwise.

    .. seealso:: :data:`numpy.add`

    ''')


conj = create_ufunc(
    'cupy_conj',
    ('b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L', 'q->q',
     'Q->Q', 'e->e', 'f->f', 'd->d',
     ('F->F', 'out0 = conj(in0)'),
     ('D->D', 'out0 = conj(in0)')),
    'out0 = in0',
    doc='''Returns the complex conjugate, element-wise.

    .. seealso:: :data:`numpy.conj`

    ''')


angle = create_ufunc(
    'cupy_angle',
    ('?->d', 'e->e', 'f->f', 'd->d',
     ('F->f', 'out0 = arg(in0)'),
     ('D->d', 'out0 = arg(in0)')),
    'out0 = in0 >= 0 ? 0 : M_PI',
    doc='''Returns the angle of the complex argument.

    .. seealso:: :func:`numpy.angle`

    ''')


real = create_ufunc(
    'cupy_real',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q', 'e->e', 'f->f', 'd->d',
     ('F->f', 'out0 = in0.real()'),
     ('D->d', 'out0 = in0.real()')),
    'out0 = in0',
    doc='''Returns the real part of the elements of the array.

    .. seealso:: :func:`numpy.real`

    ''')

_real_setter = create_ufunc(
    'cupy_real_setter',
    ('f->F', 'd->D'),
    'out0.real(in0)',
    doc='''Sets the real part of the elements of the array.
    ''')


imag = create_ufunc(
    'cupy_imag',
    ('?->?', 'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q', 'e->e', 'f->f', 'd->d',
     ('F->f', 'out0 = in0.imag()'),
     ('D->d', 'out0 = in0.imag()')),
    'out0 = 0',
    doc='''Returns the imaginary part of the elements of the array.

    .. seealso:: :func:`numpy.imag`

    ''')


_imag_setter = create_ufunc(
    'cupy_imag_setter',
    ('f->F', 'd->D'),
    'out0.imag(in0)',
    doc='''Sets the imaginary part of the elements of the array.
    ''')


negative = create_ufunc(
    'cupy_negative',
    (('?->?', 'out0 = !in0'),
     'b->b', 'B->B', 'h->h', 'H->H', 'i->i', 'I->I', 'l->l', 'L->L',
     'q->q', 'Q->Q', 'e->e', 'f->f', 'd->d', 'F->F', 'D->D'),
    'out0 = -in0',
    doc='''Takes numerical negative elementwise.

    .. seealso:: :data:`numpy.negative`

    ''')


multiply = create_arithmetic(
    'multiply', '*', '&',
    '''Multiplies two arrays elementwise.

    .. seealso:: :data:`numpy.multiply`

    ''')


divide = create_ufunc(
    'cupy_divide',
    ('bb->b', 'BB->B', 'hh->h', 'HH->H', 'ii->i', 'II->I', 'll->l', 'LL->L',
     'qq->q', 'QQ->Q',
     ('ee->e', 'out0 = in0 / in1'),
     ('ff->f', 'out0 = in0 / in1'),
     ('dd->d', 'out0 = in0 / in1'),
     ('FF->F', 'out0 = in0 / in1'),
     ('DD->D', 'out0 = in0 / in1')),
    'out0 = in1 == 0 ? 0 : floor((double)in0 / (double)in1)',
    doc='''Divides arguments elementwise.

    .. seealso:: :data:`numpy.divide`

    ''')


power = create_ufunc(
    'cupy_power',
    ('??->b', 'bb->b', 'BB->B', 'hh->h', 'HH->H', 'ii->i', 'II->I', 'll->l',
     'LL->L', 'qq->q', 'QQ->Q',
     ('ee->e', 'out0 = powf(in0, in1)'),
     ('ff->f', 'out0 = powf(in0, in1)'),
     ('dd->d', 'out0 = pow(in0, in1)'),
     ('FF->F', 'out0 = pow(in0, in1)'),
     ('DD->D', 'out0 = pow(in0, in1)')),
    'out0 = rint(pow((double)in0, (double)in1))',
    doc='''Computes ``x1 ** x2`` elementwise.

    .. seealso:: :data:`numpy.power`

    ''')


subtract = create_arithmetic(
    'subtract', '-', '^',
    '''Subtracts arguments elementwise.

    .. seealso:: :data:`numpy.subtract`

    ''')


true_divide = create_ufunc(
    'cupy_true_divide',
    ('bb->d', 'BB->d', 'hh->d', 'HH->d', 'ii->d', 'II->d', 'll->d', 'LL->d',
     'qq->d', 'QQ->d', 'ee->e', 'ff->f', 'dd->d', 'FF->F', 'DD->D'),
    'out0 = (out0_type)in0 / (out0_type)in1',
    doc='''Elementwise true division (i.e. division as floating values).

    .. seealso:: :data:`numpy.true_divide`

    ''')


if six.PY3:
    divide = true_divide


floor_divide = create_ufunc(
    'cupy_floor_divide',
    ('bb->b', 'BB->B', 'hh->h', 'HH->H', 'ii->i', 'II->I', 'll->l', 'LL->L',
     'qq->q', 'QQ->Q', 'ee->e', 'ff->f', 'dd->d'),
    'out0 = _floor_divide(in0, in1)',
    doc='''Elementwise floor division (i.e. integer quotient).

    .. seealso:: :data:`numpy.floor_divide`

    ''')


remainder = create_ufunc(
    'cupy_remainder',
    ('bb->b', 'BB->B', 'hh->h', 'HH->H', 'ii->i', 'II->I', 'll->l', 'LL->L',
     'qq->q', 'QQ->Q',
     ('ee->e', 'out0 = in0 - _floor_divide(in0, in1) * in1'),
     ('ff->f', 'out0 = in0 - _floor_divide(in0, in1) * in1'),
     ('dd->d', 'out0 = in0 - _floor_divide(in0, in1) * in1')),
    'out0 = (in0 - _floor_divide(in0, in1) * in1) * (in1 != 0)',
    doc='''Computes the remainder of Python division elementwise.

    .. seealso:: :data:`numpy.remainder`

    ''')


absolute = create_ufunc(
    'cupy_absolute',
    (('?->?', 'out0 = in0'),
     'b->b', ('B->B', 'out0 = in0'), 'h->h', ('H->H', 'out0 = in0'),
     'i->i', ('I->I', 'out0 = in0'), 'l->l', ('L->L', 'out0 = in0'),
     'q->q', ('Q->Q', 'out0 = in0'),
     ('e->e', 'out0 = fabsf(in0)'),
     ('f->f', 'out0 = fabsf(in0)'),
     ('d->d', 'out0 = fabs(in0)'),
     ('F->f', 'out0 = abs(in0)'),
     ('D->d', 'out0 = abs(in0)')),
    'out0 = in0 > 0 ? in0 : -in0',
    doc='''Elementwise absolute value function.

    .. seealso:: :data:`numpy.absolute`

    ''')


sqrt = create_ufunc(
    'cupy_sqrt',
    ('e->e', 'f->f', 'd->d', 'F->F', 'D->D'),
    'out0 = sqrt(in0)',
    doc='''Elementwise square root function.

    .. seealso:: :data:`numpy.sqrt`

    ''')


_clip = create_ufunc(
    'cupy_clip',
    ('???->?', 'bbb->b', 'BBB->B', 'hhh->h', 'HHH->H', 'iii->i', 'III->I',
     'lll->l', 'LLL->L', 'qqq->q', 'QQQ->Q', 'eee->e', 'fff->f', 'ddd->d'),
    'out0 = in0 < in1 ? in1 : (in0 > in2 ? in2 : in0)')


# -----------------------------------------------------------------------------
# Statistics
# -----------------------------------------------------------------------------

cpdef ndarray _var(ndarray a, axis=None, dtype=None, out=None, ddof=0,
                   keepdims=False):
    assert a.dtype.kind != 'c', 'Variance for complex numbers is not ' \
                                'implemented. Current implemention does not ' \
                                'convert the dtype'
    if axis is None:
        axis = tuple(range(a.ndim))
    if not isinstance(axis, tuple):
        axis = (axis,)

    if dtype is None and a.dtype.kind in 'biu':
        dtype = 'd'

    shape = a.shape
    items = 1
    for ax in axis:
        items *= shape[ax]
    alpha = 1. / max(items - ddof, 0)
    arrmean = a.mean(axis=axis, dtype=dtype, keepdims=True)
    if out is None:
        return _var_core(a, arrmean, alpha, axis=axis, keepdims=keepdims)
    else:
        return _var_core_out(
            a, arrmean, alpha, out, axis=axis, keepdims=keepdims)


cpdef _std(a, axis=None, dtype=None, out=None, ddof=0, keepdims=False):
    ret = _var(a, axis=axis, dtype=dtype, ddof=ddof, keepdims=keepdims)
    return sqrt(ret, dtype=dtype, out=out)


cdef _var_core = ReductionKernel(
    'S x, T mean, T alpha', 'T out',
    '(x - mean) * (x - mean)',
    'a + b', 'out = alpha * a', '0', '_var_core')

cdef _var_core_out = ReductionKernel(
    'S x, T mean, T alpha', 'U out',
    '(x - mean) * (x - mean)',
    'a + b', 'out = alpha * a', '0', '_var_core')

# TODO(okuta) needs cast
cdef _mean = create_reduction_func(
    'cupy_mean',
    ('?->d', 'B->d', 'h->d', 'H->d', 'i->d', 'I->d', 'l->d', 'L->d',
     'q->d', 'Q->d',
     ('e->e', (None, None, None, 'float')),
     'f->f', 'd->d', 'F->F', 'D->D'),
    ('in0', 'a + b',
     'out0 = a / _type_reduce(_in_ind.size() / _out_ind.size())', None))


# -----------------------------------------------------------------------------
# scan
# -----------------------------------------------------------------------------

@util.memoize(for_each_device=True)
def _inclusive_scan_kernel(dtype, block_size):
    """return Prefix Sum(Scan) cuda kernel

    e.g
    if blocksize * 2 >= len(src)
    src [1, 2, 3, 4]
    dst [1, 3, 6, 10]

    if blocksize * 2 < len(src)
    block_size: 2
    src [1, 2, 3, 4, 5, 6]
    dst [1, 3, 6, 10, 5, 11]

    Args:
        dtype: src, dst array type
        block_size: block_size

    Returns:
         cupy.cuda.Function: cuda function
    """

    name = "inclusive_scan_kernel"
    dtype = _get_typename(dtype)
    source = string.Template("""
    extern "C" __global__ void ${name}(const CArray<${dtype}, 1> src,
        CArray<${dtype}, 1> dst){
        long long n = src.size();
        extern __shared__ ${dtype} temp[];
        unsigned int thid = threadIdx.x;
        unsigned int block = 2 * blockIdx.x * blockDim.x;

        unsigned int idx0 = thid + block;
        unsigned int idx1 = thid + blockDim.x + block;

        temp[thid] = (idx0 < n) ? src[idx0] : (${dtype})0;
        temp[thid + blockDim.x] = (idx1 < n) ? src[idx1] : (${dtype})0;
        __syncthreads();

        for(int i = 1; i <= ${block_size}; i <<= 1){
            int index = (threadIdx.x + 1) * i * 2 - 1;
            if (index < (${block_size} << 1)){
                temp[index] = temp[index] + temp[index - i];
            }
            __syncthreads();
        }

        for(int i = ${block_size} >> 1; i > 0; i >>= 1){
            int index = (threadIdx.x + 1) * i * 2 - 1;
            if(index + i < (${block_size} << 1)){
                temp[index + i] = temp[index + i] + temp[index];
            }
            __syncthreads();
        }

        if(idx0 < n){
            dst[idx0] = temp[thid];
        }
        if(idx1 < n){
            dst[idx1] = temp[thid + blockDim.x];
        }
    }
    """).substitute(name=name, dtype=dtype, block_size=block_size)
    module = compile_with_cache(source)
    return module.get_function(name)


@util.memoize(for_each_device=True)
def _add_scan_blocked_sum_kernel(dtype):
    name = "add_scan_blocked_sum_kernel"
    dtype = _get_typename(dtype)
    source = string.Template("""
    extern "C" __global__ void ${name}(CArray<${dtype}, 1> src_dst){
        long long n = src_dst.size();
        unsigned int idxBase = (blockDim.x + 1) * (blockIdx.x + 1);
        unsigned int idxAdded = idxBase + threadIdx.x;
        unsigned int idxAdd = idxBase - 1;

        if(idxAdded < n){
            src_dst[idxAdded] += src_dst[idxAdd];
        }
    }
    """).substitute(name=name, dtype=dtype)
    module = compile_with_cache(source)
    return module.get_function(name)


cdef _nonzero_kernel_1d = ElementwiseKernel(
    'T src, S index', 'raw S dst',
    'if (src != 0) dst[index - 1] = i',
    'nonzero_kernel_1d')


cdef _nonzero_kernel = ElementwiseKernel(
    'T src, S index', 'raw S dst',
    '''
    if (src != 0){
        for(int j = 0; j < _ind.ndim; j++){
            ptrdiff_t ind[] = {j, index - 1};
            dst[ind] = _ind.get()[j];
        }
    }''',
    'nonzero_kernel',
    reduce_dims=False)


cpdef ndarray scan(ndarray a, ndarray out=None):
    """Return the prefix sum(scan) of the elements.

    Args:
        a (cupy.ndarray): input array.
        out (cupy.ndarray): Alternative output array in which to place
         the result. The same size and same type as the input array(a).

    Returns:
        cupy.ndarray: A new array holding the result is returned.

    """
    if a._shape.size() != 1:
        raise TypeError("Input array should be 1D array.")

    cdef Py_ssize_t block_size = 256

    if out is None:
        out = ndarray(a.shape, dtype=a.dtype)
    else:
        if a.size != out.size:
            raise ValueError("Provided out is the wrong size")

    kern_scan = _inclusive_scan_kernel(a.dtype, block_size)
    kern_scan(grid=((a.size - 1) // (2 * block_size) + 1,),
              block=(block_size,),
              args=(a, out),
              shared_mem=a.itemsize * block_size * 2)

    if (a.size - 1) // (block_size * 2) > 0:
        blocked_sum = out[block_size * 2 - 1:None:block_size * 2]
        scan(blocked_sum, blocked_sum)
        kern_add = _add_scan_blocked_sum_kernel(out.dtype)
        kern_add(grid=((a.size - 1) // (2 * block_size),),
                 block=(2 * block_size - 1,),
                 args=(out,))
    return out


# -----------------------------------------------------------------------------
# partition
# -----------------------------------------------------------------------------

@util.memoize(for_each_device=True)
def _partition_kernel(dtype):
    name = 'partition_kernel'
    merge_kernel = 'partition_merge_kernel'
    dtype = _get_typename(dtype)
    source = string.Template('''
    template<typename T>
    __device__ void bitonic_sort_step(CArray<T, 1> a,
            ptrdiff_t x, ptrdiff_t y, int i, ptrdiff_t s, ptrdiff_t w) {
        for (ptrdiff_t j = i; j < (y - x) / 2; j += 32) {
            ptrdiff_t n = j + (j & -w);
            T v = a[n + x], u = a[n + w + x];
            if (n & s ? v < u : v > u) {
                a[n + x] = u;
                a[n + w + x] = v;
            }
        }
    }

    // Sort a[x:y].
    template<typename T>
    __device__ void bitonic_sort(
            CArray<T, 1> a, ptrdiff_t x, ptrdiff_t y, int i) {
        for (ptrdiff_t s = 2; s <= y - x; s *= 2) {
            for (ptrdiff_t w = s / 2; w >= 1; w /= 2) {
                bitonic_sort_step<T>(a, x, y, i, s, w);
            }
        }
    }

    // Merge first k elements and the next 32 times t elements.
    template<typename T>
    __device__ void merge(
            CArray<T, 1> a, int k, int i, ptrdiff_t x, ptrdiff_t z, int u) {
        for (int s = i; s < u; s += 32) {
            if (a[x + k - s - 1] > a[z + s]) {
                T tmp = a[x + k - s - 1];
                a[x + k - s - 1] = a[z + s];
                a[z + s] = tmp;
            }
        }

        // After merge step, the first k elements are already bitonic.
        // Therefore, we do not need to fully sort.
        for (int w = k / 2; w >= 1; w /= 2) {
            bitonic_sort_step<T>(a, x, k + x, i, k, w);
        }
    }

    extern "C" {
    // In this function, 32 threads handle one subarray. This number equals to
    // the warp size. The first k elements are always sorted and the next 32
    // times t elements stored values that have possibilities to be selected.
    __global__ void ${name}(
            CArray<${dtype}, 1> a, int k, ptrdiff_t n, int t, ptrdiff_t sz) {

        // This thread handles a[z:m].
        ptrdiff_t i = static_cast<ptrdiff_t>(blockIdx.x) * blockDim.x
            + threadIdx.x;
        ptrdiff_t z = i / 32 * n / sz;
        ptrdiff_t m = (i / 32 + 1) * n / sz;
        int id = i % 32;
        int x = 0;

        bitonic_sort<${dtype}>(a, z, k + z, id);
        ptrdiff_t j;
        for (j = k + id + z; j < m - (m - z) % 32; j += 32) {
            if (a[j] < a[k - 1 + z]) {
                ${dtype} tmp = a[k + 32 * x + id + z];
                a[k + 32 * x + id + z] = a[j];
                a[j] = tmp;
                ++x;
            }

            // If at least one thread in the warp has found t values that
            // can be selected, we update the first k elements.
    #if __CUDACC_VER_MAJOR__ >= 9
            if (__any_sync(0xffffffff, x >= t)) {
    #else
            if (__any(x >= t)) {
    #endif
                bitonic_sort<${dtype}>(a, k + z, 32 * t + k + z, id);
                merge<${dtype}>(a, k, id, z, k + z, min(k, 32 * t));
                x = 0;
            }
        }
        if (j < m && a[j] < a[k - 1 + z]) {
            ${dtype} tmp = a[k + 32 * x + id + z];
            a[k + 32 * x + id + z] = a[j];
            a[j] = tmp;
        }

        // Finally, we merge the first k elements and the remainders to be
        // stored.
        bitonic_sort<${dtype}>(a, k + z, 32 * t + k + z, id);
        merge<${dtype}>(a, k, id, z, k + z, min(k, 32 * t));
    }

    __global__ void ${merge_kernel}(
            CArray<${dtype}, 1> a, int k, ptrdiff_t n, int sz, int s) {
        ptrdiff_t i = static_cast<ptrdiff_t>(blockIdx.x) * blockDim.x
            + threadIdx.x;
        ptrdiff_t z = i / 32 * 2 * s * n / sz;
        ptrdiff_t m = (i / 32 * 2 + 1) * s * n / sz;
        int id = i % 32;
        merge<${dtype}>(a, k, id, z, m, k);
    }
    }
    ''').substitute(name=name, merge_kernel=merge_kernel, dtype=dtype)
    module = compile_with_cache(source)
    return module.get_function(name), module.get_function(merge_kernel)

# This file is a part of Julia. License is MIT: https://julialang.org/license

abstract type AbstractCartesianIndex{N} end # This is a hacky forward declaration for CartesianIndex
const ViewIndex = Union{Real, AbstractArray}
const ScalarIndex = Real

"""
    SubArray{T,N,P,I,L} <: AbstractArray{T,N}

`N`-dimensional view into a parent array (of type `P`) with an element type `T`, restricted by a tuple of indices (of type `I`). `L` is true for types that support fast linear indexing, and `false` otherwise.

Construct `SubArray`s using the [`view`](@ref) function.
"""
struct SubArray{T,N,P,I,L} <: AbstractArray{T,N}
    parent::P
    indices::I
    offset1::Int       # for linear indexing and pointer, only valid when L==true
    stride1::Int       # used only for linear indexing
    function SubArray{T,N,P,I,L}(parent, indices, offset1, stride1) where {T,N,P,I,L}
        @inline
        check_parent_index_match(parent, indices)
        new(parent, indices, offset1, stride1)
    end
end
# Compute the linear indexability of the indices, and combine it with the linear indexing of the parent
function SubArray(parent::AbstractArray, indices::Tuple)
    @inline
    SubArray(IndexStyle(viewindexing(indices), IndexStyle(parent)), parent, ensure_indexable(indices), index_dimsum(indices...))
end
function SubArray(::IndexCartesian, parent::P, indices::I, ::NTuple{N,Any}) where {P,I,N}
    @inline
    SubArray{eltype(P), N, P, I, false}(parent, indices, 0, 0)
end
function SubArray(::IndexLinear, parent::P, indices::I, ::NTuple{N,Any}) where {P,I,N}
    @inline
    # Compute the stride and offset
    stride1 = compute_stride1(parent, indices)
    SubArray{eltype(P), N, P, I, true}(parent, indices, compute_offset1(parent, stride1, indices), stride1)
end

check_parent_index_match(parent, indices) = check_parent_index_match(parent, index_ndims(indices...))
check_parent_index_match(parent::AbstractArray{T,N}, ::NTuple{N, Bool}) where {T,N} = nothing
check_parent_index_match(parent, ::NTuple{N, Bool}) where {N} =
    throw(ArgumentError("number of indices ($N) must match the parent dimensionality ($(ndims(parent)))"))

# This computes the linear indexing compatibility for a given tuple of indices
viewindexing(I::Tuple{}) = IndexLinear()
# Leading scalar indices simply increase the stride
viewindexing(I::Tuple{ScalarIndex, Vararg{Any}}) = (@inline; viewindexing(tail(I)))
# Slices may begin a section which may be followed by any number of Slices
viewindexing(I::Tuple{Slice, Slice, Vararg{Any}}) = (@inline; viewindexing(tail(I)))
# A UnitRange can follow Slices, but only if all other indices are scalar
viewindexing(I::Tuple{Slice, AbstractUnitRange, Vararg{ScalarIndex}}) = IndexLinear()
viewindexing(I::Tuple{Slice, Slice, Vararg{ScalarIndex}}) = IndexLinear() # disambiguate
# In general, scalar ranges are only fast if all other indices are scalar
# Other ranges, such as those of `CartesianIndex`es, are not fast even if these
# are followed by `ScalarIndex`es
viewindexing(I::Tuple{AbstractRange{<:ScalarIndex}, Vararg{ScalarIndex}}) = IndexLinear()
# All other index combinations are slow
viewindexing(I::Tuple{Vararg{Any}}) = IndexCartesian()
# Of course, all other array types are slow
viewindexing(I::Tuple{AbstractArray, Vararg{Any}}) = IndexCartesian()

# Simple utilities
size(V::SubArray) = (@inline; map(length, axes(V)))

similar(V::SubArray, T::Type, dims::Dims) = similar(V.parent, T, dims)

sizeof(V::SubArray) = length(V) * sizeof(eltype(V))
sizeof(V::SubArray{<:Any,<:Any,<:Array}) = length(V) * elsize(V.parent)

function Base.copy(V::SubArray)
    v = V.parent[V.indices...]
    ndims(V) == 0 || return v
    x = similar(V) # ensure proper type of x
    x[] = v
    return x
end

parent(V::SubArray) = V.parent
parentindices(V::SubArray) = V.indices

"""
    parentindices(A)

Return the indices in the [`parent`](@ref) which correspond to the view `A`.

# Examples
```jldoctest
julia> A = [1 2; 3 4];

julia> V = view(A, 1, :)
2-element view(::Matrix{Int64}, 1, :) with eltype Int64:
 1
 2

julia> parentindices(V)
(1, Base.Slice(Base.OneTo(2)))
```
"""
function parentindices end

parentindices(a::AbstractArray) = map(oneto, size(a))

## Aliasing detection
dataids(A::SubArray) = (dataids(A.parent)..., _splatmap(dataids, A.indices)...)
_splatmap(f, ::Tuple{}) = ()
_splatmap(f, t::Tuple) = (f(t[1])..., _splatmap(f, tail(t))...)
unaliascopy(A::SubArray) = typeof(A)(unaliascopy(A.parent), map(unaliascopy, A.indices), A.offset1, A.stride1)

# When the parent is an Array we can trim the size down a bit. In the future this
# could possibly be extended to any mutable array.
function unaliascopy(V::SubArray{T,N,A,I,LD}) where {T,N,A<:Array,I<:Tuple{Vararg{Union{ScalarIndex,AbstractRange{<:ScalarIndex},Array{<:Union{ScalarIndex,AbstractCartesianIndex}}}}},LD}
    dest = Array{T}(undef, _trimmedshape(V.indices...))
    trimmedpind = _trimmedpind(V.indices...)
    vdest = trimmedpind isa Tuple{Vararg{Union{Slice,Colon}}} ? dest : view(dest, trimmedpind...)
    copyto!(vdest, view(V, _trimmedvind(V.indices...)...))
    indices = map(_trimmedindex, V.indices)
    stride1 = LD ? compute_stride1(dest, indices) : 0
    offset1 = LD ? compute_offset1(dest, stride1, indices) : 0
    SubArray{T,N,A,I,LD}(dest, indices, offset1, stride1)
end
# Get the proper trimmed shape
_trimmedshape(::ScalarIndex, rest...) = (1, _trimmedshape(rest...)...)
_trimmedshape(i::AbstractRange, rest...) = (isempty(i) ? zero(eltype(i)) : maximum(i), _trimmedshape(rest...)...)
_trimmedshape(i::Union{UnitRange,StepRange,OneTo}, rest...) = (length(i), _trimmedshape(rest...)...)
_trimmedshape(i::AbstractArray{<:ScalarIndex}, rest...) = (length(i), _trimmedshape(rest...)...)
_trimmedshape(i::AbstractArray{<:AbstractCartesianIndex{0}}, rest...) = _trimmedshape(rest...)
_trimmedshape(i::AbstractArray{<:AbstractCartesianIndex{N}}, rest...) where {N} = (length(i), ntuple(Returns(1), Val(N - 1))..., _trimmedshape(rest...)...)
_trimmedshape() = ()
# We can avoid the repetition from `AbstractArray{CartesianIndex{0}}`
_trimmedpind(i, rest...) = (map(Returns(:), axes(i))..., _trimmedpind(rest...)...)
_trimmedpind(i::AbstractRange, rest...) = (i, _trimmedpind(rest...)...)
_trimmedpind(i::Union{UnitRange,StepRange,OneTo}, rest...) = ((:), _trimmedpind(rest...)...)
_trimmedpind(i::AbstractArray{<:AbstractCartesianIndex{0}}, rest...) = _trimmedpind(rest...)
_trimmedpind() = ()
_trimmedvind(i, rest...) = (map(Returns(:), axes(i))..., _trimmedvind(rest...)...)
_trimmedvind(i::AbstractArray{<:AbstractCartesianIndex{0}}, rest...) = (map(first, axes(i))..., _trimmedvind(rest...)...)
_trimmedvind() = ()
# Transform indices to be "dense"
_trimmedindex(i::ScalarIndex) = oftype(i, 1)
_trimmedindex(i::AbstractRange) = i
_trimmedindex(i::Union{UnitRange,StepRange,OneTo}) = oftype(i, oneto(length(i)))
_trimmedindex(i::AbstractArray{<:ScalarIndex}) = oftype(i, reshape(eachindex(IndexLinear(), i), axes(i)))
_trimmedindex(i::AbstractArray{<:AbstractCartesianIndex{0}}) = oftype(i, copy(i))
function _trimmedindex(i::AbstractArray{<:AbstractCartesianIndex{N}}) where {N}
    padding = ntuple(Returns(1), Val(N - 1))
    ax1 = eachindex(IndexLinear(), i)
    return oftype(i, reshape(CartesianIndices((ax1, padding...)), axes(i)))
end
## SubArray creation
# We always assume that the dimensionality of the parent matches the number of
# indices that end up getting passed to it, so we store the parent as a
# ReshapedArray view if necessary. The trouble is that arrays of `CartesianIndex`
# can make the number of effective indices not equal to length(I).
_maybe_reshape_parent(A::AbstractArray, ::NTuple{1, Bool}) = reshape(A, Val(1))
_maybe_reshape_parent(A::AbstractArray{<:Any,1}, ::NTuple{1, Bool}) = reshape(A, Val(1))
_maybe_reshape_parent(A::AbstractArray{<:Any,N}, ::NTuple{N, Bool}) where {N} = A
_maybe_reshape_parent(A::AbstractArray, ::NTuple{N, Bool}) where {N} = reshape(A, Val(N))
# The trailing singleton indices could be eliminated after bounds checking.
rm_singleton_indices(ndims::Tuple, J1, Js...) = (J1, rm_singleton_indices(IteratorsMD._splitrest(ndims, index_ndims(J1)), Js...)...)
rm_singleton_indices(::Tuple{}, ::ScalarIndex, Js...) = rm_singleton_indices((), Js...)
rm_singleton_indices(::Tuple) = ()

"""
    view(A, inds...)

Like [`getindex`](@ref), but returns a lightweight array that lazily references
(or is effectively a _view_ into) the parent array `A` at the given index or indices
`inds` instead of eagerly extracting elements or constructing a copied subset.
Calling [`getindex`](@ref) or [`setindex!`](@ref) on the returned value
(often a [`SubArray`](@ref)) computes the indices to access or modify the
parent array on the fly.  The behavior is undefined if the shape of the parent array is
changed after `view` is called because there is no bound check for the parent array; e.g.,
it may cause a segmentation fault.

Some immutable parent arrays (like ranges) may choose to simply
recompute a new array in some circumstances instead of returning
a `SubArray` if doing so is efficient and provides compatible semantics.

!!! compat "Julia 1.6"
    In Julia 1.6 or later, `view` can be called on an `AbstractString`, returning a
    `SubString`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Matrix{Int64}:
 1  2
 3  4

julia> b = view(A, :, 1)
2-element view(::Matrix{Int64}, :, 1) with eltype Int64:
 1
 3

julia> fill!(b, 0)
2-element view(::Matrix{Int64}, :, 1) with eltype Int64:
 0
 0

julia> A # Note A has changed even though we modified b
2×2 Matrix{Int64}:
 0  2
 0  4

julia> view(2:5, 2:3) # returns a range as type is immutable
3:4
```
"""
function view(A::AbstractArray, I::Vararg{Any,M}) where {M}
    @inline
    J = map(i->unalias(A,i), to_indices(A, I))
    @boundscheck checkbounds(A, J...)
    J′ = rm_singleton_indices(ntuple(Returns(true), Val(ndims(A))), J...)
    unsafe_view(_maybe_reshape_parent(A, index_ndims(J′...)), J′...)
end

# Ranges implement getindex to return recomputed ranges; use that for views, too (when possible)
function view(r1::AbstractUnitRange, r2::AbstractUnitRange{<:Integer})
    @_propagate_inbounds_meta
    getindex(r1, r2)
end
function view(r1::AbstractUnitRange, r2::StepRange{<:Integer})
    @_propagate_inbounds_meta
    getindex(r1, r2)
end
function view(r1::StepRange, r2::AbstractRange{<:Integer})
    @_propagate_inbounds_meta
    getindex(r1, r2)
end
function view(r1::StepRangeLen, r2::OrdinalRange{<:Integer})
    @_propagate_inbounds_meta
    getindex(r1, r2)
end
function view(r1::LinRange, r2::OrdinalRange{<:Integer})
    @_propagate_inbounds_meta
    getindex(r1, r2)
end

# getindex(r::AbstractRange, ::Colon) returns a copy of the range, and we may do the same for a view
function view(r1::AbstractRange, c::Colon)
    @_propagate_inbounds_meta
    getindex(r1, c)
end

function unsafe_view(A::AbstractArray, I::Vararg{ViewIndex,N}) where {N}
    @inline
    SubArray(A, I)
end
# When we take the view of a view, it's often possible to "reindex" the parent
# view's indices such that we can "pop" the parent view and keep just one layer
# of indirection. But we can't always do this because arrays of `CartesianIndex`
# might span multiple parent indices, making the reindex calculation very hard.
# So we use _maybe_reindex to figure out if there are any arrays of
# `CartesianIndex`, and if so, we punt and keep two layers of indirection.
unsafe_view(V::SubArray, I::Vararg{ViewIndex,N}) where {N} =
    (@inline; _maybe_reindex(V, I))
_maybe_reindex(V, I) = (@inline; _maybe_reindex(V, I, I))
_maybe_reindex(V, I, ::Tuple{AbstractArray{<:AbstractCartesianIndex}, Vararg{Any}}) =
    (@inline; SubArray(V, I))
# But allow arrays of CartesianIndex{1}; they behave just like arrays of Ints
_maybe_reindex(V, I, A::Tuple{AbstractArray{<:AbstractCartesianIndex{1}}, Vararg{Any}}) =
    (@inline; _maybe_reindex(V, I, tail(A)))
_maybe_reindex(V, I, A::Tuple{Any, Vararg{Any}}) = (@inline; _maybe_reindex(V, I, tail(A)))
function _maybe_reindex(V, I, ::Tuple{})
    @inline
    @inbounds idxs = to_indices(V.parent, reindex(V.indices, I))
    SubArray(V.parent, idxs)
end

## Re-indexing is the heart of a view, transforming A[i, j][x, y] to A[i[x], j[y]]
#
# Recursively look through the heads of the parent- and sub-indices, considering
# the following cases:
# * Parent index is array  -> re-index that with one or more sub-indices (one per dimension)
# * Parent index is Colon  -> just use the sub-index as provided
# * Parent index is scalar -> that dimension was dropped, so skip the sub-index and use the index as is

AbstractZeroDimArray{T} = AbstractArray{T, 0}

reindex(::Tuple{}, ::Tuple{}) = ()

# Skip dropped scalars, so simply peel them off the parent indices and continue
reindex(idxs::Tuple{ScalarIndex, Vararg{Any}}, subidxs::Tuple{Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1], reindex(tail(idxs), subidxs)...))

# Slices simply pass their subindices straight through
reindex(idxs::Tuple{Slice, Vararg{Any}}, subidxs::Tuple{Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (subidxs[1], reindex(tail(idxs), tail(subidxs))...))

# Re-index into parent vectors with one subindex
reindex(idxs::Tuple{AbstractVector, Vararg{Any}}, subidxs::Tuple{Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1][subidxs[1]], reindex(tail(idxs), tail(subidxs))...))

# Parent matrices are re-indexed with two sub-indices
reindex(idxs::Tuple{AbstractMatrix, Vararg{Any}}, subidxs::Tuple{Any, Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1][subidxs[1], subidxs[2]], reindex(tail(idxs), tail(tail(subidxs)))...))

# In general, we index N-dimensional parent arrays with N indices
@generated function reindex(idxs::Tuple{AbstractArray{T,N}, Vararg{Any}}, subidxs::Tuple{Vararg{Any}}) where {T,N}
    if length(subidxs.parameters) >= N
        subs = [:(subidxs[$d]) for d in 1:N]
        tail = [:(subidxs[$d]) for d in N+1:length(subidxs.parameters)]
        :(@_propagate_inbounds_meta; (idxs[1][$(subs...)], reindex(tail(idxs), ($(tail...),))...))
    else
        :(throw(ArgumentError("cannot re-index SubArray with fewer indices than dimensions\nThis should not occur; please submit a bug report.")))
    end
end

# In general, we simply re-index the parent indices by the provided ones
SlowSubArray{T,N,P,I} = SubArray{T,N,P,I,false}
function getindex(V::SubArray{T,N}, I::Vararg{Int,N}) where {T,N}
    @inline
    @boundscheck checkbounds(V, I...)
    @inbounds r = V.parent[reindex(V.indices, I)...]
    r
end

# But SubArrays with fast linear indexing pre-compute a stride and offset
FastSubArray{T,N,P,I} = SubArray{T,N,P,I,true}
# We define a convenience functions to compute the shifted parent index
# This differs from reindex as this accepts the view directly, instead of its indices
@inline _reindexlinear(V::FastSubArray, i::Int) = V.offset1 + V.stride1*i
@inline _reindexlinear(V::FastSubArray, i::AbstractUnitRange{Int}) = V.offset1 .+ V.stride1 .* i

function getindex(V::FastSubArray, i::Int)
    @inline
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[_reindexlinear(V, i)]
    r
end

# For vector views with linear indexing, we disambiguate to favor the stride/offset
# computation as that'll generally be faster than (or just as fast as) re-indexing into a range.
function getindex(V::FastSubArray{<:Any, 1}, i::Int)
    @inline
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[_reindexlinear(V, i)]
    r
end

# We can avoid a multiplication if the first parent index is a Colon or AbstractUnitRange,
# or if all the indices are scalars, i.e. the view is for a single value only
FastContiguousSubArray{T,N,P,I<:Union{Tuple{AbstractUnitRange, Vararg{Any}},
                                      Tuple{Vararg{ScalarIndex}}}} = SubArray{T,N,P,I,true}

@inline _reindexlinear(V::FastContiguousSubArray, i::Int) = V.offset1 + i
@inline _reindexlinear(V::FastContiguousSubArray, i::AbstractUnitRange{Int}) = V.offset1 .+ i

"""
An internal type representing arrays stored contiguously in memory.
"""
const DenseArrayType{T,N} = Union{
    DenseArray{T,N},
    <:FastContiguousSubArray{T,N,<:DenseArray},
}

"""
An internal type representing mutable arrays stored contiguously in memory.
"""
const MutableDenseArrayType{T,N} = Union{
    Array{T, N},
    Memory{T},
    FastContiguousSubArray{T,N,<:Array},
    FastContiguousSubArray{T,N,<:Memory}
}

# parents of FastContiguousSubArrays may support fast indexing with AbstractUnitRanges,
# so we may just forward the indexing to the parent
# This may only be done for non-offset ranges, as the result would otherwise have offset axes
const _OneBasedRanges = Union{OneTo{Int}, UnitRange{Int}, Slice{OneTo{Int}}, IdentityUnitRange{OneTo{Int}}}
function getindex(V::FastContiguousSubArray, i::_OneBasedRanges)
    @inline
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[_reindexlinear(V, i)]
    r
end

@inline getindex(V::FastContiguousSubArray, i::Colon) = getindex(V, to_indices(V, (:,))...)

# Indexed assignment follows the same pattern as `getindex` above
function setindex!(V::SubArray{T,N}, x, I::Vararg{Int,N}) where {T,N}
    @inline
    @boundscheck checkbounds(V, I...)
    @inbounds V.parent[reindex(V.indices, I)...] = x
    V
end
function setindex!(V::FastSubArray, x, i::Int)
    @inline
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[_reindexlinear(V, i)] = x
    V
end
function setindex!(V::FastSubArray{<:Any, 1}, x, i::Int)
    @inline
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[_reindexlinear(V, i)] = x
    V
end

function setindex!(V::FastSubArray, x, i::AbstractUnitRange{Int})
    @inline
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[_reindexlinear(V, i)] = x
    V
end

@inline setindex!(V::FastSubArray, x, i::Colon) = setindex!(V, x, to_indices(V, (i,))...)

function isassigned(V::SubArray{T,N}, I::Vararg{Int,N}) where {T,N}
    @inline
    @boundscheck checkbounds(Bool, V, I...) || return false
    @inbounds r = isassigned(V.parent, reindex(V.indices, I)...)
    r
end
function isassigned(V::FastSubArray, i::Int)
    @inline
    @boundscheck checkbounds(Bool, V, i) || return false
    @inbounds r = isassigned(V.parent, _reindexlinear(V, i))
    r
end
function isassigned(V::FastSubArray{<:Any, 1}, i::Int)
    @inline
    @boundscheck checkbounds(Bool, V, i) || return false
    @inbounds r = isassigned(V.parent, _reindexlinear(V, i))
    r
end

IndexStyle(::Type{<:FastSubArray}) = IndexLinear()

# Strides are the distance in memory between adjacent elements in a given dimension
# which we determine from the strides of the parent
strides(V::SubArray) = substrides(strides(V.parent), V.indices)

substrides(strds::Tuple{}, ::Tuple{}) = ()
substrides(strds::NTuple{N,Int}, I::Tuple{ScalarIndex, Vararg{Any}}) where N = (substrides(tail(strds), tail(I))...,)
substrides(strds::NTuple{N,Int}, I::Tuple{Slice, Vararg{Any}}) where N = (first(strds), substrides(tail(strds), tail(I))...)
substrides(strds::NTuple{N,Int}, I::Tuple{AbstractRange, Vararg{Any}}) where N = (first(strds)*step(I[1]), substrides(tail(strds), tail(I))...)
substrides(strds, I::Tuple{Any, Vararg{Any}}) = throw(ArgumentError(
    LazyString("strides is invalid for SubArrays with indices of type ", typeof(I[1]))))

stride(V::SubArray, d::Integer) = d <= ndims(V) ? strides(V)[d] : strides(V)[end] * size(V)[end]

compute_stride1(parent::AbstractArray, I::NTuple{N,Any}) where {N} =
    (@inline; compute_stride1(1, fill_to_length(axes(parent), OneTo(1), Val(N)), I))
compute_stride1(s, inds, I::Tuple{}) = s
compute_stride1(s, inds, I::Tuple{Vararg{ScalarIndex}}) = s
compute_stride1(s, inds, I::Tuple{ScalarIndex, Vararg{Any}}) =
    (@inline; compute_stride1(s*length(inds[1]), tail(inds), tail(I)))
compute_stride1(s, inds, I::Tuple{AbstractRange, Vararg{Any}}) = s*step(I[1])
compute_stride1(s, inds, I::Tuple{Slice, Vararg{Any}}) = s
compute_stride1(s, inds, I::Tuple{Any, Vararg{Any}}) = throw(ArgumentError(LazyString("invalid strided index type ", typeof(I[1]))))

elsize(::Type{<:SubArray{<:Any,<:Any,P}}) where {P} = elsize(P)

iscontiguous(A::SubArray) = iscontiguous(typeof(A))
iscontiguous(::Type{<:SubArray}) = false
iscontiguous(::Type{<:FastContiguousSubArray}) = true

first_index(V::FastSubArray) = V.offset1 + V.stride1 * firstindex(V) # cached for fast linear SubArrays
first_index(V::SubArray) = compute_linindex(parent(V), V.indices)

# Computing the first index simply steps through the indices, accumulating the
# sum of index each multiplied by the parent's stride.
# The running sum is `f`; the cumulative stride product is `s`.
# If the parent is a vector, then we offset the parent's own indices with parameters of I
compute_offset1(parent::AbstractVector, stride1::Integer, I::Tuple{AbstractRange}) =
    (@inline; first(I[1]) - stride1*first(axes1(I[1])))
# If the result is one-dimensional and it's a Colon, then linear
# indexing uses the indices along the given dimension.
# If the result is one-dimensional and it's a range, then linear
# indexing might be offset if the index itself is offset
# Otherwise linear indexing always matches the parent.
compute_offset1(parent, stride1::Integer, I::Tuple) =
    (@inline; compute_offset1(parent, stride1, find_extended_dims(1, I...), find_extended_inds(I...), I))
compute_offset1(parent, stride1::Integer, dims::Tuple{Int}, inds::Tuple{Slice}, I::Tuple) =
    (@inline; compute_linindex(parent, I) - stride1*first(axes(parent, dims[1])))  # index-preserving case
compute_offset1(parent, stride1::Integer, dims, inds::Tuple{AbstractRange}, I::Tuple) =
    (@inline; compute_linindex(parent, I) - stride1*first(axes1(inds[1]))) # potentially index-offsetting case
compute_offset1(parent, stride1::Integer, dims, inds, I::Tuple) =
    (@inline; compute_linindex(parent, I) - stride1)
function compute_linindex(parent, I::NTuple{N,Any}) where N
    @inline
    IP = fill_to_length(axes(parent), OneTo(1), Val(N))
    compute_linindex(first(LinearIndices(parent)), 1, IP, I)
end
function compute_linindex(f, s, IP::Tuple, I::Tuple{Any, Vararg{Any}})
    @inline
    Δi = first(I[1])-first(IP[1])
    compute_linindex(f + Δi*s, s*length(IP[1]), tail(IP), tail(I))
end
compute_linindex(f, s, IP::Tuple, I::Tuple{}) = f

find_extended_dims(dim, ::ScalarIndex, I...) = (@inline; find_extended_dims(dim + 1, I...))
find_extended_dims(dim, i1, I...) = (@inline; (dim, find_extended_dims(dim + 1, I...)...))
find_extended_dims(dim) = ()
find_extended_inds(::ScalarIndex, I...) = (@inline; find_extended_inds(I...))
find_extended_inds(i1, I...) = (@inline; (i1, find_extended_inds(I...)...))
find_extended_inds() = ()

pointer(V::FastSubArray, i::Int) = pointer(V.parent, V.offset1 + V.stride1*i)
pointer(V::FastContiguousSubArray, i::Int) = pointer(V.parent, V.offset1 + i)

function pointer(V::SubArray{<:Any,<:Any,<:Array,<:Tuple{Vararg{RangeIndex}}}, is::AbstractCartesianIndex{N}) where {N}
    index = first_index(V)
    strds = strides(V)
    for d = 1:N
        index += (is[d]-1)*strds[d]
    end
    return pointer(V.parent, index)
end

# indices are taken from the range/vector
# Since bounds-checking is performance-critical and uses
# indices, it's worth optimizing these implementations thoroughly
axes(S::SubArray) = (@inline; _indices_sub(S.indices...))
_indices_sub(::Real, I...) = (@inline; _indices_sub(I...))
_indices_sub() = ()
function _indices_sub(i1::AbstractArray, I...)
    @inline
    (axes(i1)..., _indices_sub(I...)...)
end

axes1(::SubArray{<:Any,0}) = OneTo(1)
axes1(S::SubArray) = (@inline; _axes1_sub(S.indices...))
_axes1_sub() = ()
_axes1_sub(::Real, I...) = (@inline; _axes1_sub(I...))
_axes1_sub(::AbstractArray{<:Any,0}, I...) = _axes1_sub(I...)
function _axes1_sub(i1::AbstractArray, I...)
    @inline
    axes1(i1)
end

has_offset_axes(S::SubArray) = has_offset_axes(S.indices...)

function replace_in_print_matrix(S::SubArray{<:Any,2,<:AbstractMatrix}, i::Integer, j::Integer, s::AbstractString)
    replace_in_print_matrix(S.parent, to_indices(S.parent, reindex(S.indices, (i,j)))..., s)
end
function replace_in_print_matrix(S::SubArray{<:Any,1,<:AbstractVector}, i::Integer, j::Integer, s::AbstractString)
    replace_in_print_matrix(S.parent, to_indices(S.parent, reindex(S.indices, (i,)))..., j, s)
end

# XXX: this is considerably more unsafe than the other similarly named methods
unsafe_wrap(::Type{Vector{UInt8}}, s::FastContiguousSubArray{UInt8,1,Vector{UInt8}}) = unsafe_wrap(Vector{UInt8}, pointer(s), size(s))

using HDF5
using LibDeflate

function mergechunks(addrs, sizes)
    if length(addrs) != length(sizes)
        throw(ArgumentError("Lengths of addrs and sizes don't match: $(length(addrs)) and $(length(sizes))"))
    end

    merged_addrs = Vector{UInt64}([addrs[1]])
    merged_sizes = Vector{UInt64}([sizes[1]])
    sizehint!(merged_addrs, length(addrs) ÷ 10)
    sizehint!(merged_sizes, length(addrs) ÷ 10)

    @views for (addr, size) in Iterators.zip(addrs[2:end], sizes[2:end])
        if merged_addrs[end] + merged_sizes[end] == addr
            merged_sizes[end] += size
        else
            push!(merged_addrs, addr)
            push!(merged_sizes, size)
        end
    end

    return (merged_addrs, merged_sizes)
end

function getchunkaddrs(ds::HDF5.Dataset)
    n_chunks = HDF5.get_num_chunks(ds)
    addrs = Vector{UInt64}(undef, n_chunks)
    sizes = Vector{UInt64}(undef, n_chunks)

    for i in 1:n_chunks
        info = HDF5.API.h5d_get_chunk_info(ds, i - 1)
        addrs[i] = info.addr
        sizes[i] = info.size
    end

    return (addrs, sizes)
end

function deshuffle(data, out, eltype_size=4)
    byte_stride = length(out) ÷ eltype_size
    for i in 1:byte_stride
        out_i = 1 + (i - 1) * eltype_size

        for j in 0:eltype_size - 1
            out[out_i + j] = data[i + (j * byte_stride)]
        end
    end
end

function decompress_chunk(compressed_chunk, codec, out, decompression_tmp)
    unsafe_zlib_decompress!(Base.HasLength(), codec,
                            pointer(decompression_tmp), length(decompression_tmp),
                            pointer(compressed_chunk), length(compressed_chunk))

    deshuffle(decompression_tmp, out, 2)
end

function loadchunks(ds::HDF5.Dataset, mapped_file::Vector{UInt8},
                    addrs, sizes,
                    dest=nothing)
    n_bytes::Int64 = prod(size(ds)) * sizeof(eltype(ds))
    if dest === nothing
        dest = Vector{UInt8}(undef, n_bytes)
    end

    if length(dest) != n_bytes
        throw(ArgumentError("dest buffer can only hold $(length(dest)) elements, but it must have at least $(n_bytes)"))
    end

    ds_properties = HDF5.get_create_properties(ds)
    chunk_size::Int64 = prod(ds_properties.chunk) * sizeof(eltype(ds))

    codec = Decompressor()
    is_compressed = false
    filters = ds_properties.filters
    if length(filters) > 0
        filter_types = typeof.(filters)
        if length(filters) != 2 || !(Filters.Shuffle in filter_types && Filters.Deflate in filter_types)
            error("Dataset $(HDF5.name(ds)) has filters enabled, which are not currently supported")
        else
            is_compressed = true
        end
    end

    chunks_dest = if is_compressed
        Vector{UInt8}(undef, sum(sizes))
    else
        dest
    end
    decompression_tmp = Vector{UInt8}(undef, chunk_size)

    dest_offset = UInt64(1)
    for (i, (addr, size)) in enumerate(Iterators.zip(addrs, sizes))
        copyto!(chunks_dest, dest_offset, mapped_file, addr + 1, size)

        if is_compressed
            compressed_chunk = @view chunks_dest[dest_offset:dest_offset + size - 1]
            final_dest_addr = 1 + (i - 1) * chunk_size
            final_dest = @view dest[final_dest_addr:final_dest_addr + chunk_size - 1]

            decompress_chunk(compressed_chunk, codec, final_dest, decompression_tmp)
        end

        dest_offset += size
    end

    return dest
end

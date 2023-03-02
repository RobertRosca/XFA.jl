using HDF5
using Hwloc
using LibDeflate
using ThreadPinning


function mergechunks(addrs, sizes)
    if length(addrs) != length(sizes)
        throw(ArgumentError("Lengths of addrs and sizes don't match: $(length(addrs)) and $(length(sizes))"))
    end

    merged_addrs = UInt64[addrs[1]]
    merged_sizes = UInt64[sizes[1]]
    group_start_chunks = Int32[1]
    group_sizes = Int32[1]

    n_groups_guess = length(addrs) ÷ 10
    for x in [merged_addrs, merged_sizes, group_start_chunks, group_sizes]
        sizehint!(x, n_groups_guess)
    end

    @views for (addr, size) in Iterators.zip(addrs[2:end], sizes[2:end])
        if merged_addrs[end] + merged_sizes[end] == addr
            merged_sizes[end] += size
            group_sizes[end] += 1
        else
            push!(group_start_chunks, group_start_chunks[end] + group_sizes[end])
            push!(group_sizes, 1)
            push!(merged_addrs, addr)
            push!(merged_sizes, size)
        end
    end

    return (merged_addrs, merged_sizes, group_start_chunks, group_sizes)
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

    @simd for i in 1:byte_stride
        out_i = 1 + (i - 1) * 2 # eltype_size

        Base.Cartesian.@nexprs 2 j -> @inbounds out[out_i + j - 1] = data[i + ((j - 1) * byte_stride)]
    end
end

function loadchunks(ds::HDF5.Dataset, mapped_file::Vector{UInt8},
                    addrs, sizes, dest=nothing;
                    n_readers::Int=-1)
    n_threads = Threads.nthreads(:default)
    if n_readers == -1
        n_readers = max(1, n_threads ÷ 2)
    end

    merged_addrs, merged_sizes, group_start_chunks, group_sizes = mergechunks(addrs, sizes)

    if n_threads < n_readers
        error("Only $(n_threads) threads configured, must be at least $(n_readers) to match the requested number of reader threads")
    end

    eltype_size::Int = sizeof(eltype(ds))
    n_bytes::Int = prod(size(ds)) * eltype_size

    if dest === nothing
        dest = Vector{UInt8}(undef, n_bytes)
    end

    if length(dest) != n_bytes
        throw(ArgumentError("dest buffer can only hold $(length(dest)) elements, but it must have at least $(n_bytes)"))
    end

    ds_properties = HDF5.get_create_properties(ds)
    chunk_size::Int = prod(ds_properties.chunk) * sizeof(eltype(ds))

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

    chunk_chnl = Channel{Tuple{Int, UInt64, UInt64}}(1000)

    dest_offsets = 1 .+ circshift(cumsum(sizes), 1)
    dest_offsets[1] = 1
    chunk_groups = collect(Iterators.partition(1:length(merged_addrs),
                                               max(1, length(merged_addrs) ÷ n_readers)))

    decompression_buffers = [Vector{UInt8}(undef, chunk_size) for _ in 1:length(chunk_groups)]
    # Check that the buffers are allocated at least a cacheline away
    buffer_addrs = map(pointer, decompression_buffers)
    buffer_shares_cacheline = [buffer_addrs[i] - buffer_addrs[i - 1] < cachelinesize().L1
                               for i in 2:length(buffer_addrs)]
    if any(buffer_shares_cacheline)
        error("Decompression buffers sharing a cacheline")
    end

    reader_tasks = [@tspawnat thread_id let thread_id = thread_id
                        for i in group
                            if is_compressed
                                chunks_in_group = group_sizes[i]
                                first_chunk = group_start_chunks[i]
                                decompression_tmp::Vector{UInt8} = decompression_buffers[thread_id]

                                c_offset = merged_addrs[i] + 1
                                for group_chunk_idx in 1:chunks_in_group
                                    global_chunk_idx = first_chunk + (group_chunk_idx - 1)
                                    c_size = sizes[global_chunk_idx]

                                    compressed_chunk = @view mapped_file[c_offset:c_offset + c_size - 1]
                                    final_dest_addr = 1 + (global_chunk_idx - 1) * chunk_size
                                    final_dest = @view dest[final_dest_addr:final_dest_addr + chunk_size - 1]

                                    unsafe_zlib_decompress!(Base.HasLength(), codec,
                                                            pointer(decompression_tmp), length(decompression_tmp),
                                                            pointer(compressed_chunk), length(compressed_chunk))

                                    deshuffle(decompression_tmp, final_dest, eltype_size)

                                    c_offset += sizes[global_chunk_idx]
                                end

                            else
                                offset = dest_offsets[i]
                                csize = merged_sizes[i]

                                copyto!(chunks_dest, offset, mapped_file, merged_addrs[i] + 1, csize)
                            end
                            # put!(chunk_chnl, (i, offset, csize))
                        end
                    end
                    for (thread_id, group) in enumerate(chunk_groups)]
    fetcher = Threads.@spawn begin
        try
            foreach(fetch, reader_tasks)
        catch e
            throw(e)
        finally
            close(chunk_chnl)
        end
    end

    # decompression_tmp = Vector{UInt8}(undef, chunk_size)
    # for (i, dest_offset, size) in chunk_chnl
    #     if is_compressed
    #         chunks_in_group = group_sizes[i]
    #         first_chunk = group_start_chunks[i]

    #         c_offset = dest_offset
    #         for group_chunk_idx in 1:chunks_in_group
    #             global_chunk_idx = first_chunk + (group_chunk_idx - 1)
    #             c_size = sizes[global_chunk_idx]

    #             compressed_chunk = @view chunks_dest[c_offset:c_offset + c_size - 1]
    #             final_dest_addr = 1 + (global_chunk_idx - 1) * chunk_size
    #             final_dest = @view dest[final_dest_addr:final_dest_addr + chunk_size - 1]

    #             unsafe_zlib_decompress!(Base.HasLength(), codec,
    #                                     pointer(decompression_tmp), length(decompression_tmp),
    #                                     pointer(compressed_chunk), length(compressed_chunk))

    #             deshuffle(decompression_tmp, final_dest, eltype_size)

    #             c_offset += sizes[global_chunk_idx]
    #         end
    #     end
    # end

    fetch(fetcher)

    return dest
end

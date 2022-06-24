export Trainmatcher, match_train

mutable struct Trainmatcher
    max_train_latency::Int
    sources::Set{String}
    train_data::Dict{Int}
    latest_trainid::Int

    """
        Trainmatcher(sources, max_train_latency::Int)

    Create a Trainmatcher object, which tries to match `sources` coming from a
    Karabo bridge. `sources` is some iterable of `String`'s. The matching is
    'greedy', which means that if not all sources have been received for a certain
    train after `max_train_latency` trains, then the incomplete train data will be
    returned.
    """
    function Trainmatcher(sources, max_train_latency::Int)
        new(max_train_latency, Set(sources), Dict{Int, Any}(), -1)
    end
end

"""
    match_train(tm::Trainmatcher, data::Dict, metadata::Dict)

Match incoming `data` and `metadata` from a Karabo bridge to `tm`. Returns
a `Dict` of matched trains where the keys are the train IDs and the values are
tuples of `(data, metadata)` for the matched train.

Note that this function does not require that all data sources passed in a
single call are from the same train. Each source is handled separately based on
the train ID in its metadata.
"""
function match_train(tm::Trainmatcher, data::Dict, metadata::Dict)
    if keys(data) != keys(metadata)
        error("data and metadata have different sources for the same train, " *
              "these cannot be trainmatched")
    end

    # Update cached data
    for source in keys(data)
        tid = metadata[source]["timestamp.tid"]
        tm.latest_trainid = max(tm.latest_trainid, tid)

        train_data, train_meta = get!(tm.train_data, tid, (Dict(), Dict()))

        train_data[source] = data[source]
        train_meta[source] = metadata[source]
    end

    matched_trains = Dict()

    # Pop trains that are too old, or fully matched
    for tid in collect(keys(tm.train_data))
        if (tm.latest_trainid - tid > tm.max_train_latency ||
            tm.sources ⊆ keys(tm.train_data[tid][1]))

            matched_trains[tid] = pop!(tm.train_data, tid)
        end
    end

    return matched_trains
end

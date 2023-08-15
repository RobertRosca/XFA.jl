# Archive
This directory contains random experiments that either didn't work out or just
don't fit in XFA. They may be in a semi-broken state.

## Run streamer
[run_streamer.jl](run_streamer.jl) was an attempt at creating a high-performance
streamer for streaming runs from files on the AGIPD. In practice it was more of
a testbed for an alternative way of reading data from HDF5 by getting the chunk
offsets/sizes and reading straight from the file with mmap, it was later decided
to implement the run streamer in Python for better usability for folks not using
Julia.

Takeaways: memory mapping on network filesystems is a terrible idea, stick to
`read(2)`.

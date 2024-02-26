# XfelAnalyserEngine

This is the server component of XFA, which owns all of the Distributed.jl
workers and runs the actual analysis. It's intended to be spawned and run
independently without the need for any supervisor daemon using the
[`launcher.jl`](src/launcher.jl) script.

The launcher script will:
1. Initialize a logger to save all logs to a file named `xfa-engine-yyyy-mm.log`
   (rotated monthly) in the working directory, and all stdout/stderr output from
   the process to a file named `worker-1-stdio.log`.
1. Add a bunch of Distributed.jl workers and redirect their stdout/stderr to
   `worker-<n>-stdio.log`.
1. Call `XfelAnalyserEngine.main()` to start the server and block until it
   completes.

When the server starts the first thing it does is begin listening for client
requests on a websocket, then it writes all connection/workers information to a
TOML file named `worker-info.toml` to be picked up by a client. Soon support
will be added for a Karabo bridge server to send analysis results.

# RemoteObjects.jl

RemoteObjects provides an easy way to work with objects in remote Julia
sessions. Objects can be instantiated in a remote session with `@remote`, and
then the object can be manipulated remotely, without ever needing to
instantiate it on the local session.

Additionally, `run_server` can be used to run a server in the
background which listens on a user-specified port for commands from another
Julia session. `connect_remote` can connect to such a session,
and its result can then be passed to `@remote` to instantiate remote objects.
This mechanism allows remote control of a Julia session without the local and
remote sessions being part of a `Distributed` cluster.

### An example using `Distributed` workers, using ROCArrays

```julia
using RemoteObjects
using ROCArrays

using Distributed
addprocs(["myserver"]) # myserver has an AMD GPU, and RemoteObjects and ROCArrays

# For some reason this is required on my machine...
@everywhere [2] using RemoteObjects
@everywhere [2] using ROCArrays

# Mimic some methods that dispatch on ROCArray
@everywhere mimic(ROCArray; debug=true)

r = @remote ROCArray(rand(Float32, 4, 4))
@show fetch(size(r))
```

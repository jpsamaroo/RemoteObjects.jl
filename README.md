# RemoteObjects.jl

### An example, using ROCArrays

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

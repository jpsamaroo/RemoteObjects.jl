module RemoteObjects

using Distributed, UUIDs, InteractiveUtils, Sockets, Serialization

export RemoteObject, mimic, @remote

const DEFAULT_WORKER = Ref(2)
const LOCALS = Dict{UUID,Any}()
const CONNS_CTR = Ref{Int}(0)
const CONNS = Dict{Int,TCPSocket}()
const FINALIZER_QUEUE = Channel{Tuple{Int,UUID}}(Inf)

mutable struct RemoteObject{T}
    rtype::Type{T}
    uuid::UUID
    id::Int
end
# FIXME: Allow specifying worker id
function RemoteObject(::Type{T}, #=id::Int,=# x...; kwargs...) where T
    id = DEFAULT_WORKER[]
    uuid = remotecall_fetch(init_object, id, T, x...; kwargs...)
    robj = RemoteObject(T, uuid, id)
    finalizer(robj) do _
        put!(FINALIZER_QUEUE, (id, uuid))
    end
    return robj
end

include("remoteserver.jl")

function init_object(::Type{T}, x...; kwargs...) where T
    uuid = uuid4()
    object = T(x...; kwargs...)
    LOCALS[uuid] = object
    return uuid
end

finalize_object(uuid::UUID) = delete!(LOCALS, uuid)

macro remote(ex)
    remotecall_fetch(remote, DEFAULT_WORKER[], ex)
end
function remote(ex)
    obj = Main.eval(ex)
    uuid = uuid4()
    LOCALS[uuid] = obj
    return RemoteObject(typeof(obj), uuid, myid())
end
function remote(f, x...)
    obj = f(x...)
    uuid = uuid4()
    LOCALS[uuid] = obj
    return RemoteObject(typeof(obj), uuid, myid())
end

function Base.fetch(robj::RemoteObject)
    if robj.id > 0
        return remotecall_fetch(RemoteObjects._unwrap, robj.id, robj.uuid)
    else
        conn = CONNS[-robj.id]
        serialize(conn, (cmd=:get, data=robj.uuid))
        blob = deserialize(conn)
        return blob.result
    end
end
_unwrap(robj::RemoteObject) = _unwrap(robj.uuid)
_unwrap(uuid::UUID) = LOCALS[uuid]

### Mimicry

"""
    mimic(::Type{T}) where T

Reads all methods defined on T, and defines those for RemoteObject{T} such that
they call the original method on the target object remotely. If the `force`
kwarg is `true`, then a failure to mimic a method will throw an error.
"""
function mimic(::Type{T}; force=false, debug=false) where T
    for method in methodswith(T)
        try
            debug && @show method
            f = method.sig.parameters[1]
            mod = method.module
            name = Symbol(string(f.instance))
            syms = Symbol.(split(method.slot_syms, '\0')[2:end-1])
            params = method.sig.parameters[2:end]
            args = [Expr(:(::), syms[idx], x===T ? RemoteObject : x) for (idx,x) in enumerate(params)]
            cargs = [x===T ? :(RemoteObjects._unwrap($(syms[idx]))) : syms[idx] for (idx,x) in enumerate(params)]
            if myid() == 1
                ex = :($mod.$name($(args...)) = remotecall_fetch($(f.instance), $(DEFAULT_WORKER[]), $(syms...)))
            else
                ex = :($mod.$name($(args...)) = RemoteObjects.remote($(f.instance), $(cargs...)))
            end
            debug && @show ex
            Main.eval(ex)
            debug && @info "Mimicked $method"
        catch err
            if force
                println("Error during mimic($T):")
                rethrow(err)
            else
                debug && @warn "Failed to mimic $method"
            end
        end
    end
end

### Convenience methods

struct RemoteIO <: IO
    chan::RemoteChannel
end
RemoteIO(id::Int) =
    RemoteIO(RemoteChannel(()->Channel(typemax(Int)), id))
Base.write(rio::RemoteIO, x::UInt8) = (put!(rio.chan, x); 1)
Base.take!(rio::RemoteIO) = take!(rio.chan)
Base.isready(rio::RemoteIO) = isready(rio.chan)

function Base.show(io::IO, r::RemoteObject)
    if myid() == 1
        rio = RemoteIO(r.id)
        remotecall_wait(Base.show, r.id, rio, r)
        # TODO: This is pretty inefficient, instead send whole strings
        buf = UInt8[]
        while isready(rio)
            push!(buf, take!(rio))
        end
        print(io, String(buf))
    else
        print(io, "RemoteObject (worker $(myid())): ")
        try
            Base.show(io, _unwrap(r))
        catch err
            print(io, "Error during show")
        end
    end
end

function __init__()
    @async begin
        while true
            id, uuid = take!(FINALIZER_QUEUE)
            try
                if id > 0
                    # Distributed worker
                    id in workers() || continue
                    remotecall_fetch(finalize_object, id, uuid)
                else
                    # RemoteServer
                    conn = CONNS[-id]
                    serialize(conn, (cmd=:finalize, data=uuid))
                    result = deserialize(conn)
                end
            catch err
                #@warn "Failed to finalize RemoteObject on $id: $uuid"
                showerror(stderr, err, catch_backtrace())
            end
        end
    end
end

end # module

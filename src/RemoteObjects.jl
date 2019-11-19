module RemoteObjects

using Distributed, UUIDs, InteractiveUtils

export RemoteObject, @mimic, mimic, @remote

const DEFAULT_WORKER = Ref(2)
const LOCALS = Dict{UUID,Any}()

abstract type AbstractRemoteObject{T} end
mutable struct RemoteObject{T} <: AbstractRemoteObject{T}
    uuid::UUID
    id::Int
end
# FIXME: Allow specifying worker id
function RemoteObject(::Type{T}, #=id::Int,=# x...; kwargs...) where T
    id = DEFAULT_WORKER[]
    uuid = remotecall_fetch(init_object, id, T, x...; kwargs...)
    robj = RemoteObject{T}(uuid, id)
    finalizer(robj) do _
        if id in workers()
            remotecall_fetch(finalize_object, id, uuid)
        end
    end
    return robj
end

# _remote is overriden for each <:AbstractRemoteObject
_remote(x, uuid) = RemoteObject{typeof(x)}(uuid, myid())

function init_object(::Type{T}, x...; kwargs...) where T
    uuid = uuid4()
    object = T(x...; kwargs...)
    LOCALS[uuid] = object
    return uuid
end

function finalize_object(uuid::UUID)
    delete!(LOCALS, uuid)
end

# Gets a subtype-able supertype of `x`
getsuper(x::UnionAll) = getsuper(x.body)
getsuper(x::DataType) = x

"""
    RT = @mimic T

Creates an `RT <: AbstractRemoteObject` which mimics `T`, and is a supertype of `T`s supertype (allowing `RT` to be passed to methods which don't directly dispatch on `T`).
"""
macro mimic(T, kwargs=NamedTuple())
    RT = Symbol("RemoteObject_$T")
    ex = quote
        @everywhere begin
        mutable struct $RT <: RemoteObjects.getsuper(supertype($T))
            uuid::RemoteObjects.UUIDs.UUID
            id::Int
        end
        RemoteObjects._remote(x::$T, uuid) = $RT{typeof(x)}(uuid, myid())
        RemoteObjects.mimic($T, $RT; $(kwargs)...) # Mimic RT -> T
        end
        Main.$RT
    end
    @show ex
    ex
end

"""
    ro = @remote ex

Evaluates `ex` on a worker, and returns a `<:AbstractRemoteObject` reference
to it.
"""
macro remote(ex)
    @show methods(_remote)
    remotecall_fetch(remote, DEFAULT_WORKER[], ex)
end
function remote(ex::Union{Expr,Symbol})
    obj = Main.eval(ex)
    uuid = uuid4()
    LOCALS[uuid] = obj
    @show methods(_remote)
    return _remote(obj, uuid)
end
function remote(f, x...)
    obj = f(x...)
    uuid = uuid4()
    LOCALS[uuid] = obj
    return _remote(obj, uuid)
end

function Base.fetch(robj::RemoteObject)
    remotecall_fetch(RemoteObjects._unwrap, robj.id, robj.uuid)
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
function mimic(::Type{T}, ::Type{RT}; force=false, debug=false) where {T,RT}
    for method in methodswith(T)
        try
            debug && @show method
            f = method.sig.parameters[1]
            mod = method.module
            name = Symbol(string(f.instance))
            syms = Symbol.(split(method.slot_syms, '\0')[2:end-1])
            params = method.sig.parameters[2:end]
            args = [Expr(:(::), syms[idx], x===T ? RT : x) for (idx,x) in enumerate(params)]
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
mimic(::Type{T}; kwargs...) where T = mimic(T, RemoteObject; kwargs...)

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

end # module

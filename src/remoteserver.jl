export connect_remote, run_server

struct RemoteServer
    host::String
    port::Int
    conn::TCPSocket
end

const CONNS_CTR = Ref{Int}(0)
const CONNS = Dict{Int,RemoteServer}()

function connect_remote(host, port)
    conn = connect(host, port)
    return RemoteServer(string(host), port, conn)
end

run_server(port=rand(1024:65535)) = run_server(Sockets.localhost, port)
function run_server(host, port)
    srv = listen(host, port)
    while true
        conn = accept(srv)
        @async _run_server(conn)
    end
end
function _run_server(conn)
    while true
        try
            blob = deserialize(conn)
            cmd, data = blob.cmd, blob.data
            handle_cmd(conn, Val(Symbol(cmd)), data)
        catch err
            showerror(stderr, err)
            Base.show_backtrace(stderr, catch_backtrace())
            # TODO: Write stacktrace
            serialize(conn, (err=err))
            try
                close(conn)
            finally
                break
            end
        end
    end
end

function handle_cmd(conn, ::Val{:eval}, ex)
    robj = remote(ex)
    serialize(conn, (result=(uuid=robj.uuid,rtype=robj.rtype),))
end
function handle_cmd(conn, ::Val{:get}, uuid)
    robj = _unwrap(uuid)
    serialize(conn, (result=robj,))
end
function handle_cmd(conn, ::Val{:show}, uuid)
    iob = IOBuffer()
    robj = _unwrap(uuid)
    Base.show(iob, robj)
    serialize(conn, (result=String(take!(iob)),))
end

macro remote(conn, ex)
    quote
        serialize($(esc(conn)).conn, (cmd=:eval, data=$ex))
        blob = deserialize($(esc(conn)).conn)
        if haskey(blob, :result)
            T = eval(Symbol(blob.result.rtype))
            uuid = blob.result.uuid
            id = CONNS_CTR[]+1
            CONNS[id] = $(esc(conn))
            RemoteObject(T, uuid, -id)
        else
            err = blob.err
            # FIXME: Wrap with own exception type
            throw(err)
        end
    end
end

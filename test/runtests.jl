using Distributed; addprocs(1)
@everywhere using RemoteObjects
using Sockets
using Test

@everywhere begin
    struct MyStruct
        x
    end
    mycall(m::MyStruct) = m.x
end
@everywhere mimic(MyStruct; force=true)

@testset "Basics" begin

r = RemoteObject(MyStruct, 1)
@test r isa RemoteObject{MyStruct}
x = mycall(r)
@test x isa RemoteObject{Int}
@test r.uuid != x.uuid
@test Base.fetch(x) == 1
iob = IOBuffer()
Base.show(iob, r)
str = String(take!(iob))
@test str == "RemoteObject (worker 2): MyStruct(1)"

r = @remote MyStruct(2)
@test r isa RemoteObject{MyStruct}
x = Base.fetch(r)
@test x.x == 2

end

@testset "Remote Server" begin

port = rand(20000:30000)
tsk = @async run_server(port)
yield()
conn = connect_remote(Sockets.localhost, port)

# FIXME: Set timedwait in case server hangs

r = @remote conn rand(Float32)
@test r isa RemoteObject{Float32}
x = Base.fetch(r)
@test x isa Float32

@test_throws UndefVarError @remote conn lol()

sleep(1)

end

using Distributed; addprocs(1)
@everywhere using RemoteObjects
using UUIDs
using Test

@everywhere begin
    abstract type AbstractMyStruct end
    struct MyStruct <: AbstractMyStruct
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

@testset "Mimicry" begin

RT = @mimic(MyStruct, (force=true,))
@test RT <: AbstractMyStruct
@test RemoteObjects._remote(MyStruct(3), uuid4()) isa RT
r = @remote MyStruct(4)
@show typeof(r)
@show RT
@show typeof(r) === RT
@test r isa RT

end

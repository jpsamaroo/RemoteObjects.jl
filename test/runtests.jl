using Distributed; addprocs(1)
@everywhere using RemoteObjects
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

r = @remote MyStruct(2)
@test r isa RemoteObject{MyStruct}
x = Base.fetch(r)
@test x.x == 2

end

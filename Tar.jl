@use "github.com/jkroso/URI.jl/FSPath.jl" FSPath
@use Tar

@kwdef struct TarBuffer <: IO
  io::IOBuffer=PipeBuffer()
end
Base.eof(io::TarBuffer) = eof(io.io)
Base.readbytes!(io::TarBuffer, b::AbstractVector) = readbytes!(io.io, b)
Base.readavailable(io::TarBuffer) = readavailable(io.io)
Base.read(io::TarBuffer, T::Type{UInt8}) = read(io.io, T)
Base.skip(io::TarBuffer, n) = skip(io.io, n)

function writefile(io::TarBuffer, path::FSPath, data::Vector{UInt8})
  Tar.write_header(io.io, Tar.Header(string(path), :file, 0o644, length(data), ""))
  tail = write(io.io, data) % 512
  tail > 0 && write(io.io, zeros(UInt8, 512 - tail)) # finish the tail chunk with zeros
  nothing
end

finish(io::TarBuffer) = write(io.io, fill(0x00, 1024)) # 2 empty blocks marks the end of the tarfile

function untar(tar::IO)
  data = Dict{String, Vector{UInt8}}()
  buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
  io = IOBuffer()
  Tar.read_tarball(x->true, tar; buf=buf) do hdr, _
    hdr.type == :file || return nothing
    Tar.read_data(tar, io; size=hdr.size, buf=buf)
    data[hdr.path] = take!(io)
  end
  data
end

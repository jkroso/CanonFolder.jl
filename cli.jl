#!/usr/bin/env julia --color=yes --startup-file=no
using Kip
@use "github.com/jkroso/URI.jl/FSPath" FSPath FileType RelativePath
@use "github.com/jkroso/HTTP.jl/server" handle_requests Request Response ["logger" logger]
@use "github.com/jkroso/SimpleCLI.jl" @cli
@use "./compile" compile
@use "./Tar" untar
@use MIMEs: mime_from_extension
@use Sockets: localhost, IPAddr, listen, listenany
@use AWSS3...
@use Dates

"Serve a directory over TCP on a localhost port"
@cli serve(directory::String=pwd(); port::Integer=get(ENV,"PORT",0), addr::String="localhost") = begin
  host = addr == "localhost" ? localhost : parse(IPAddr, addr)
  basedir = FSPath(abspath(directory))

  p, server = if port != 0
    port, listen(host, port)
  else
    listenany(host, 3000)
  end

  domain = host == localhost ? "localhost" : host
  run(`open http://$domain:$p/`)

  function respond(r::Request{:GET})
    path = basedir * RelativePath(r.uri.path)
    if path.exists
      tar = compile(path, followlinks=false, basedir=basedir)
      file, data = first(untar(tar))
      mime = mime_from_extension(FSPath(file).extension, MIME("text/plain"))
      Response(Dict("Content-Type" => string(mime)), data)
    else
      Response(404)
    end
  end

  handle_requests(logger(respond), server)
end

"Compile <file/folder> and write it to an AWS S3 bucket"
@cli deploy(path::String, bucket::String) = begin
  base = abs(FSPath(path))
  tracker = (base*"tracker.html").exists ? read(base*"tracker.html", String) : ""
  S3 = S3Path("s3://$bucket/")
  for (path, data) in untar(compile(base, tracker=tracker))
    @info "uploading" path length(data)
    write(joinpath(S3, path), data)
  end
end

"Compile <file/folder> to a tarball that can be thrown up on a static web server"
@cli main(path::String) = write(stdout, compile(abs(FSPath(path))))

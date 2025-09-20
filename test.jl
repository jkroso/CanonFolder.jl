@use "github.com/jkroso/Rutherford.jl/test" @test
@use "." compile @fs_str icon_folder untar
@use Tar

@test startswith(String(untar(compile(icon_folder, false))["index.html"]), "<html>")
@test any(h->h.path == "index.html", Tar.list(compile(icon_folder)))

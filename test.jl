@use "./compile.jl" compile @fs_str icon_folder 
@use "./Tar.jl" untar
@use Test...
@use Tar

@test startswith(String(untar(compile(icon_folder, followlinks=false))["index.html"]), "<html>")
@test any(h->h.path == "index.html", Tar.list(IOBuffer(take!(compile(icon_folder).io.io))))

let html = String(untar(compile(icon_folder, followlinks=false))["index.html"])
  style = join(m.captures[1] for m in eachmatch(r"<style[^>]*>(.*?)</style>"s, html))
  classes = [m.captures[1] for m in eachmatch(r"class=\"([^\"]+)\"", html)]
  for cls in Iterators.flatmap(split, classes)
    occursin(r"^[a-z0-9]{12,13}$", cls) || continue # only check generated class names
    @test occursin(cls, style)
  end
end

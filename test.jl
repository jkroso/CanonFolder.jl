@use "./compile.jl" compile @fs_str icon_folder 
@use "./Tar.jl" untar
@use Test...
@use Tar

@test startswith(String(untar(compile(icon_folder, followlinks=false))["index.html"]), "<!DOCTYPE html><html>")
@test any(h->h.path == "index.html", Tar.list(IOBuffer(take!(compile(icon_folder).io.io))))

let html = String(untar(compile(icon_folder, followlinks=false))["index.html"])
  style = join(m.captures[1] for m in eachmatch(r"<style[^>]*>(.*?)</style>"s, html))
  classes = [m.captures[1] for m in eachmatch(r"class=\"([^\"]+)\"", html)]
  for cls in Iterators.flatmap(split, classes)
    occursin(r"^[a-z0-9]{12,13}$", cls) || continue # only check generated class names
    @test occursin(cls, style)
  end
end

# With markdown, each page made from Markdown goes in with its Markdown, and each folder as a Markdown table
@use "github.com/jkroso/URI.jl/FSPath.jl" FSPath
mktempdir() do dir
  write(joinpath(dir, "Readme.md"), "+++\ndescription=\"A test\"\n+++\n\nHello.\n")
  write(joinpath(dir, "An essay.md"), "+++\ndescription=\"Either a | b\"\n+++\n\nText.\n")
  write(joinpath(dir, "Why?.md"), "+++\ncomplete=false\n+++\n\nNot done.\n")
  mkdir(joinpath(dir, "Sub folder"))
  write(joinpath(dir, "Sub folder", "Readme.md"), "+++\ndescription=\"Inside\"\n+++\n")
  files = untar(compile(FSPath(dir), markdown=true))
  @test files["An essay.md"] == read(joinpath(dir, "An essay.md"))
  @test haskey(files, "An essay.html")
  @test !haskey(files, "Readme.md")
  index = String(files["index.md"])
  @test startswith(index, "+++\ndescription=\"A test\"\n+++\n\nHello.\n\n| Name | Description | Created | Modified |\n")
  @test occursin(r"\n\| \[An essay\.md\]\(An%20essay\.html\) \| Either a \\\| b \| \d{4}-\d\d-\d\d \| \d{4}-\d\d-\d\d \|\n", index)
  @test occursin("| [Why?.md](Why%3F.html) (draft) |  | ", index)
  @test occursin("| [Sub folder](Sub%20folder/) | Inside |", index)
  @test !occursin("Readme", index)
  @test startswith(String(files["Sub folder/index.md"]), "+++\ndescription=\"Inside\"\n+++\n\n| Name |")
  @test !any(endswith(".md"), keys(untar(compile(FSPath(dir)))))
end

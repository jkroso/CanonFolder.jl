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

# With markdown, a folder's .ladder file goes in beside its page, for Ladder to ask for
mktempdir() do dir
  write(joinpath(dir, ".ladder"), "```julia\nLadder.BlogDirectory\n```\n")
  mkdir(joinpath(dir, "essay"))
  write(joinpath(dir, "essay", ".ladder"), "Its own.\n")
  write(joinpath(dir, "essay", "index.md"), "# An essay\n")
  mkdir(joinpath(dir, "plain"))
  write(joinpath(dir, "plain", "a.md"), "A\n")
  files = untar(compile(FSPath(dir), markdown=true))
  @test String(files[".ladder"]) == "```julia\nLadder.BlogDirectory\n```\n"
  @test String(files["essay/.ladder"]) == "Its own.\n"
  @test !haskey(files, "plain/.ladder")
  @test !haskey(untar(compile(FSPath(dir))), ".ladder")
end

# A folder with its own index.md is that page, with no list to replace it
mktempdir() do dir
  mkdir(joinpath(dir, "essay"))
  write(joinpath(dir, "essay", "index.md"), "# A folder's own page\n\n![](./picture.png)\n")
  write(joinpath(dir, "essay", "picture.png"), UInt8[1, 2, 3])
  write(joinpath(dir, "essay", "unused.bin"), UInt8[4])
  files = untar(compile(FSPath(dir), markdown=true))
  page = String(files["essay/index.html"])
  @test occursin("A folder&#39;s own page", page) || occursin("A folder's own page", page)
  @test !occursin("class=\"listing\"", page)
  @test occursin("<title>essay</title>", page)
  @test files["essay/picture.png"] == UInt8[1, 2, 3]
  @test !haskey(files, "essay/unused.bin")
  @test String(files["essay/index.md"]) == "# A folder's own page\n\n![](./picture.png)\n"
  @test occursin("href=\"essay/index.html\"", String(files["index.html"]))
end

# A link to a page whose name has a character that a URL can't hold, such as a ?, has that character %-coded
mktempdir() do dir
  write(joinpath(dir, "Why not?.md"), "Because.\n")
  files = untar(compile(FSPath(dir)))
  @test occursin("href=\"Why%20not%3F.html\"", String(files["index.html"]))
  @test haskey(files, "Why not?.html")
end

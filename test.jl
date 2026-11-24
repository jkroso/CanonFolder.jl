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
  @test occursin(r"\n\| \[An essay\.md\]\(An%20essay\.md\) \| Either a \\\| b \| \d{4}-\d\d-\d\d \| \d{4}-\d\d-\d\d \|\n", index)
  @test occursin("| [Why?.md](Why%3F.md) (draft) |  | ", index)
  @test haskey(files, "Why?.md")   # each Markdown page that the table links to goes out beside its page
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

# A folder whose .ladder page names Ladder's BookReviewDirectory holds book reviews: each Markdown file in it is one,
# and a link to one, with spaces in its path, goes to its page
mktempdir() do dir
  reviews = joinpath(dir, "Book Reviews")
  mkdir(reviews)
  write(joinpath(reviews, ".ladder"), "Reviews.\n\n```julia\nLadder.BookReviewDirectory\n```\n")
  write(joinpath(reviews, "Readme.md"), "+++\ndescription=\"Books\"\n+++\n")
  review = "+++\ntitle = \"Red Plenty\"\nlink = \"https://en.wikipedia.org/wiki/Red_Plenty\"\nrating = 4\npubDate = 2010-01-01\ndescription = \"Plans\"\n+++\n\nWords.\n"
  write(joinpath(reviews, "Red Plenty.md"), review)
  mkdir(joinpath(dir, "Humans"))
  write(joinpath(dir, "Humans", "Genes.md"), "Read [the review](<../Book Reviews/Red Plenty.md>) and [its page](<./Its page.html>).\n")
  write(joinpath(dir, "Humans", "Its page.md"), "A page.\n")
  write(joinpath(dir, "Plain.md"), "+++\ntitle = \"Not a review\"\n+++\n\nWords.\n")
  files = untar(compile(FSPath(dir), markdown=true))
  page = String(files["Book Reviews/Red Plenty.html"])
  @test occursin("class=\"review\"", page) && occursin("4 stars", page) && occursin("en.wikipedia.org", page)
  @test String(files["Book Reviews/Red Plenty.md"]) == review
  @test !occursin("class=\"review\"", String(files["Plain.html"]))
  genes = String(files["Humans/Genes.html"])
  # A link to the page that canon makes of a file is left as it is
  @test occursin("href=\"../Book%20Reviews/Red%20Plenty.html\"", genes) && occursin("href=\"Its%20page.html\"", genes)
  @test occursin("| [Red Plenty.md](Red%20Plenty.md) | Plans |", String(files["Book Reviews/index.md"]))
  @test String(files["Book Reviews/.ladder"]) == "Reviews.\n\n```julia\nLadder.BookReviewDirectory\n```\n"
end

# A page of Ladder's (a Markdown page with sums, sheets, charts or views) is made with Ladder's own code: each sum shows
# what it came to, a sheet is a table, a chart is a picture, and a view of a Julia file shows what its `view` makes.
# The page is a link to a page in another folder, and its view finds the Julia file beside the page itself.
mktempdir() do top
  pages, dir = mkpath(joinpath(top, "pages")), mkpath(joinpath(top, "site"))
  write(joinpath(pages, "model.jl"), """
    # The bytes of a .glb file, with what the page gives it after them
    view(sums) = vcat(Vector{UInt8}("glTF"), zeros(UInt8, 16), Vector{UInt8}(string(sums["watts"])))
    """)
  write(joinpath(pages, "sums.md"), """
    ---
    title: Sums on a page
    about: Prices and *watts*
    ---

    # Sums

    Each watt is !`price = 25USD/W`, and there are !`watts = 2kW`. That's !`price * watts`.[^a] This one fails: !`nope + 1`.

    ```sheet
    Triple = watts * 3
    ```

    ## Parts

    | Part | Cost |
    |---|---|
    | Cells | !`cells = 30USD` |
    | Frame | !`frame = 10USD` |

    ```chart
    kind: bars
    title: What the parts cost
    ```

    ```columns
    2
    ```

    ```view
    design.sc
    ```

    ```view
    model.jl
    ```

    [^a]: A note.
    """)
  symlink(joinpath(pages, "sums.md"), joinpath(dir, "sums.md"))
  write(joinpath(dir, "plain.md"), "Some `code`!\n")
  files = untar(compile(FSPath(dir)))
  page = String(files["sums.html"])
  @test occursin("<title>Sums on a page</title>", page)
  @test occursin("<span class=\"sum\" title=\"price = 25USD/W\">25USD/W</span>", page)
  @test occursin("<span class=\"sum\" title=\"price * watts\">50,000 USD</span>", page)
  @test occursin(r"<span class=\"sum failed\" title=\"nope \+ 1\">[^<]*nope", page)
  @test occursin(r"<th>Triple</th><td><code>watts \* 3</code></td><td class=\"result\">6,?000W|6kW", page)
  @test occursin("<figcaption>What the parts cost</figcaption>", page)
  @test occursin("<svg class=\"wide\"", page) && occursin("<svg class=\"narrow\"", page) && occursin("30 USD", page)
  @test occursin("class=\"footnote-ref\"", page) && occursin("<div class=\"footnote-def\" id=\"fn-a\"><p>A note.</p></div>", page)
  # The view of the design can't go on the site, so the columns have one column left, and are no columns
  @test !occursin("class=\"columns\"", page) && occursin("<model-viewer class=\"view\" src=\"model.glb\"", page)
  @test String(files["model.glb"][21:end]) == "2000.0"   # 2kW, in SI units
  @test occursin("model-viewer.min.js", page) && !occursin("mermaid.esm", page)
  @test occursin("Prices and <em>watts</em>", String(files["index.html"]))
  # Any other page is CommonMark's, as before
  @test !occursin("class=\"sum", String(files["plain.html"]))
end

@use "github.com/jkroso/URI.jl" ["FSPath" FSPath @fs_str RelativePath] ["FS" Directory File FSObject]
@use "github.com/jkroso/Prospects.jl" assoc need @field_str flatten
@use "github.com/jkroso/JSON.jl/read"
@use "github.com/jkroso/Units.jl" B Magnitude abbr Byte
@use "github.com/jkroso/DOM.jl" => DOM css @dom @css_str ["html"]
@use "./load" Compilable MarkdownDocument BookReview
@use "./Tar" TarBuffer writefile
@use Dates: unix2datetime, format, @dateformat_str, Date
@use MIMEs: mime_from_extension, extension_from_mime
@use NodeJS: nodejs_cmd, npm_cmd
@use Glob: FilenameMatch

const emptydeps = Dict{RelativePath,Compilable}()
const icon_folder = FSPath(joinpath(@dirname, "zed-modern-icons"))
const theme = parse(MIME("application/json"), read(icon_folder * "icon_themes/vscode-icons-theme.json"))["themes"][2]
const folder_icon = parse(MIME("text/html"), read(icon_folder * theme["directory_icons"]["collapsed"]))
const book_review_icon = parse(MIME("text/html"), read(joinpath(@dirname, "book-review.svg")))
const draft = parse(MIME("text/html"), read(joinpath(@dirname, "draft.svg")))

fileicon(::Directory) = folder_icon
fileicon(::File{:review}) = book_review_icon
fileicon((;path)::File) = begin
  name = get(theme["file_suffixes"], path.extension, "binary")
  rel = theme["file_icons"][name]["path"]
  parse(MIME("text/html"), read(icon_folder * rel, String))
end

function compile(c::Compilable; tracker="", followlinks=true, basedir=dirname(c.source))
  io = IOContext(TarBuffer(), :tracker => tracker,
                              :seen => Set{RelativePath}(),
                              :followlinks => followlinks,
                              :basedir => basedir,
                              :currentdir => relpath(basedir, c.source.path))
  compile(io, c.source, c.value, c.dependencies)
  io
end

# must use invokelatest because loading in the Compilable probably defined some new methods in the process
compile(path::FSPath; kwargs...) = invokelatest(compile, Compilable(path); kwargs...)
compile(io::IO, c::Compilable) = compile(io, c.source, c.value, c.dependencies)

function compile(io::IO, dir::Directory, children, deps)
  i = findfirst(x->occursin(r"readme\..+"i, x), map(field"name", children))
  readme = if !isnothing(i)
    @dom[:div css"""
      width: 100%
      background: white
      border: 1px solid #A4A4A4
      border-radius: 12px
      box-shadow: 0 2px 10px rgba(0,0,0,0.1)
      margin: 1em 0
      padding: 1em
      box-sizing: border-box
      line-height: 1.5em
      font-size: 14pt
      font-family: sans-serif
      font-weight: 100
      """
      html(deps[FSPath(children[i].name)].value)]
  end
  dom = @dom[:html
    [:head [:title dir.path.name] [:meta charset="UTF-8"] need(css[])]
    [:body css"margin: 1em auto; max-width: 75em"
      [:div css"""
        display: flex
        flex-direction: column
        align-items: center
        justify-content: space-around
        """
        readme
        directory(dir.path, children, io, deps)]]]
  dom = compile_dependencies(subctx(io, dir), dom, deps)
  insert_tracker!(dom, io)
  writefile(io, dir, MIME("text/html"), dom)
end

function directory(dir::FSPath, children, io, deps)
  firstrow = if dir.parent ⊆ io[:basedir]
    [@dom[:div class="cell" [:a href="../" folder_icon ".."]], fill(@dom[:div class="cell"], 4)...]
  else
    []
  end
  ignores = getignores(dir)
  rows = flatten([
    (let mime = mime_type(entry)
         complete = iscomplete(entry)
         icon = fileicon(entry.source)
      [@dom[:div class="cell" css"> a > span {display: flex; align-items: center}"
         @dom[:a href=href(path, entry) (complete ? icon : draft) entry.source.path.name]],
       @dom[:div class="cell" invokelatest(describe, entry)],
       @dom[:div class="cell" showsize(entry.source.size)],
       @dom[:div class="cell" showdate(entry.btime)],
       @dom[:div class="cell" showdate(entry.mtime)],]
     end)
   for (path,entry) in deps if !shouldignore(path, ignores)])
  @dom[:div css"""
    width: 100%
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif
    border: 1px solid #A4A4A4
    border-radius: 12px
    box-shadow: 0 2px 10px rgba(0,0,0,0.1)
    display: grid
    grid-template-columns: 2fr 4fr 1fr 1fr 1fr
    overflow: hidden
    .header
      background: #f8f9fa
      padding: 16px 20px
      font-weight: 600
      color: #374151
      border-bottom: 1px solid #A4A4A4
    .cell
      padding: 12px 20px
      border-bottom: 1px solid rgb(225,225,225)
      display: flex
      align-items: center
    .cell:nth-last-child(-n+5)
      border-bottom: none
    a
      display: inline-flex
      align-items: center
      color: #2563eb
      text-decoration: none
      font-weight: 500
      svg {width: 2em; margin-right: 1em; flex: none}
    a:hover
      text-decoration: underline
    """
    [:div class="header" "Name"]
    [:div class="header" "Description"]
    [:div class="header" "Size"]
    [:div class="header" "Created"]
    [:div class="header" "Modified"]
    firstrow...
    rows...]
end

href(path::RelativePath, c::Compilable) = isdir(c.source) ? path.name * "/" : path.name

describe(c::Compilable) = @dom[:div class="summary" describe(c.source, c.value, c.dependencies)]
describe(value) = ""
describe(source, value) = describe(value)
describe(source, value, deps) = describe(source, value)
describe(::File{:md}, md::MarkdownDocument) = get(md.meta, "description", "")
describe(::File{:review}, br::BookReview) = br.description
describe(d::Directory, value, deps) = haskey(deps, fs"Readme.md") ? describe(deps[fs"Readme.md"]) : ""

iscomplete(c::Compilable) = iscomplete(c.source, c.value)
iscomplete(source, value) = true
iscomplete(source::File{:md}, md::MarkdownDocument) = get(md.meta, "complete", true)

showdate(unixtime) = format(unix2datetime(unixtime), dateformat"dd/mm/yy")
showdate(date::Date) = format(date, dateformat"dd/mm/yy")

showsize(n::Byte{m}) where m = begin
  mag = m.value
  while n.value > 999
    mag += 3
    n = convert(Byte{Magnitude(mag)}, n)
  end
  x = round(n.value, digits=2)
  string(isinteger(x) ? round(Int, x) : x, ' ', abbr(typeof(n)))
end

const binary_mime = MIME("application/octet-stream")
mime_type(f::FSPath) = isdir(f) ? MIME("inode/directory") : mime_from_extension(f.extension, binary_mime)
mime_type(f::File) = mime_from_extension(f.path.extension, binary_mime)
mime_type(f::Directory) = MIME("inode/directory")
mime_type(c::Compilable) = mime_type(c.source)

html(x::DOM.Node) = x
html(x) = convert(DOM.Node, x)
html(md::MarkdownDocument) = @dom[:div css"max-width: 39em; margin: auto" md.content]

function compile(io::IO, file::Union{File{:jl},File{:md},File{:review}}, obj, deps)
  mime = invokelatest(compiled_type, file, obj)
  doc = invokelatest(todocument, file, obj)
  doc = compile_dependencies(subctx(io, file), doc, deps)
  insert_tracker!(doc, io)
  writefile(io, file, mime, doc)
end

subctx(io, fs::FSObject) = IOContext(io, :currentdir => relpath(io[:basedir], dirname(fs)))

compile(io::IO, file::File, data::Vector{UInt8}, deps) = writefile(io, file, mime_type(file), data) # just passes through unchanged

function todocument(file, object)
  object isa DOM.Container{:html} && return object
  @dom[:html
    [:head
      [:title file.path.name]
      [:meta charset="UTF-8"]
      need(DOM.css[])
      # move footnotes into correct location
      [:script raw"""
      document.addEventListener('DOMContentLoaded', () => {
        colors = [
          "#FF6B6B", /* Coral Red */
          "#4ECDC4", /* Turquoise */
          "#FFD166", /* Golden Yellow */
          "#FF8C00", /* Dark Orange */
          "#8338EC", /* Vibrant Purple */
          "#EF476F", /* Bright Pink */
          "#118AB2", /* Deep Blue */
          "#F4A261", /* Peach */
          "#073B4C", /* Dark Teal */
          "#D00000", /* Crimson */
          "#C9ADA7", /* Soft Mauve */
          "#06D6A0", /* Mint Green */
        ]
        var i = 0
        document.querySelectorAll('.footnote-def').forEach((def)=>{
          color = colors[i++ % 12]
          ref = document.querySelector(`.footnote-ref[href="#${def.id}"]`)
          def.style.top = ref.getBoundingClientRect().top
          def.style.borderColor = color
          ref.style.backgroundColor = color
          def.classList.add(i%2 ? "right" : "left")
        })
      })
      """]]
    [:body css"""
      margin: 0 auto
      font: lighter 1.2em/1.5em sans-serif;
      div.md { position: relative; margin: 1em 0 }
      .highlight > pre
        font: 1em SourceCodePro-light
        padding: 1em
      li > *
        margin-top: 0
        margin-bottom: 0
      li
        margin: 0.2em 0
      section
        display: flex
        justify-content: center
      h1
        text-align: center
        margin-bottom: 1em
        line-height: 1.2em
      blockquote
        margin: 2rem 0
        padding: 1.5rem 2rem
        background-color: #f8f9fa
        border-left: 6px solid #007bff
        border-radius: 8px
        box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1)
        font-family: 'Georgia', serif
        font-style: italic
        color: #333
        position: relative
        overflow: hidden
      blockquote::before
        content: '“'
        position: absolute
        top: -0.5rem
        left: 0.5rem
        font-size: 6rem
        color: rgba(0, 123, 255, 0.2);
        line-height: 1
      blockquote::after
        content: '”'
        position: absolute
        bottom: -1.5rem
        right: 0.5rem
        font-size: 6rem
        color: rgba(0, 123, 255, 0.2)
        line-height: 1
      blockquote p
        margin: 0
        font-size: 1.1rem
        line-height: 1.6
      blockquote cite
        display: block
        margin-top: 1rem
        font-style: normal
        font-size: 0.9rem
        color: #6c757d
        text-align: right
      .footnote-ref
        color: transparent
        position: absolute
        border-radius: 50%
        height: .4em
        width: .4em
      .footnote-def
        position: absolute
        width: 20em
        padding: .1em 1em
        font-size: 0.65em
        line-height: 1.3em
        border-radius: 1em
        border-left: 1px solid
        border-top: 1px solid
        box-sizing: border-box
      .footnote-def.left { left: -24em }
      .footnote-def.right { right: -24em }
      """
      html(object)]]
end

compiled_type(_) = MIME("text/html")
compiled_type(::Directory, _) = MIME("text/html")
compiled_type(::File{x}, value) where x = mime_from_extension(string(x), binary_mime)
compiled_type(::File{:jl}, value) = compiled_type(value) # julia can produce objects that compile to anything
compiled_type(::File{:md}, value) = compiled_type(value)
compiled_type(::File{:review}, value) = MIME("text/html")
compiled_type(::File{:less}, value) = MIME("text/css")
encode(mime, data) = convert(Vector{UInt8}, codeunits(sprint(show, mime, data)))
encode(mime, data::Vector{UInt8}) = data

function compile(io::IOContext, file::File{:less}, data, deps)
  css = cd(@dirname) do
    ispath("node_modules/.bin/lessc") || run(`$(npm_cmd()) install --no-save less`)
    read(`$(nodejs_cmd()) ./node_modules/.bin/lessc $(string(from.path))`, String)
  end
  if io[:followlinks]
    ctx = subctx(io, file)
    css = replace(css, r"url\([^)]+\)" => m->compilelink(m[5:end-1], subctx, deps))
  end
  writefile(io, file, MIME("text/css"), convert(Vector{UInt8}, codeunits(css)))
end

writefile(io::IOContext{TarBuffer}, infile::FSObject, mime::MIME, data) = begin
  writefile(io.io, outpath(io, infile, mime), invokelatest(encode, mime, data))
end

outpath(io::IOContext, d::Directory, mime) = relpath(io[:basedir], d.path) * "index.html"
outpath(io::IOContext, f::File, mime) = setext(relpath(io[:basedir], f.path), extension(mime))
outpath(io::IOContext, f::File{Symbol("")}, mime) = setext(relpath(io[:basedir], f.path), mime == binary_mime ? "" : extension(mime))

extension(m::MIME) = let e = extension_from_mime(m); startswith(e, '.') ? e[2:end] : e end
setext(s::FSPath, ext) = s.parent * string(splitext(s.name)[1], isempty(ext) ? "" : '.', ext)

compile_dependencies(io, object, deps) = object
compile_dependencies(io, dom::DOM.Node, deps) = io[:followlinks] ? crawl(dom, io, deps) : dom

crawl(node, io, deps) = node
crawl(dom::DOM.Container, io, deps) = begin
  assoc(dom, :attrs, crawl_attrs(dom.attrs, io, deps),
             :children, map(c->crawl(c, io, deps), dom.children))
end
crawl(c::DOM.Container{:style}, io, deps) = begin
  assoc(c, :children, [DOM.Text(crawl_string(string(map(field"value", c.children)...), io, deps))])
end

crawl_attrs(attrs, io, deps) = Dict{Symbol,Any}([crawl_attr(Val(k), v, io, deps) for (k,v) in attrs])
crawl_attr(::Val{key}, value, io, deps) where key = key => value
crawl_attr(::Val{:href}, value, io, deps) = :href => compilelink(value, io, deps)
crawl_attr(::Val{:src}, value, io, deps) = :src => compilelink(value, io, deps)
crawl_attr(::Val{:style}, style, io, deps) = :style => Dict{Symbol,Any}([k=>crawl_string(v, io, deps) for (k,v) in style])

const relative_path = r"(?:\.{1,2}/)+(?:[-_a-zA-Z ]+/)*[-_a-zA-Z ]+\.[a-z]+"
crawl_string(str, io, deps) = replace(str, relative_path => (m)->compilelink(m, io, deps))

compilelink(src::AbstractString, io::IOContext, deps) = begin
  isempty(src) || occursin(r"^(\w+?:|#)", src) && return src # ignore remote URLs
  compilelink(FSPath(src), io, deps)
end

compilelink(path::FSPath, io::IOContext, deps) = begin
  haskey(deps, path) || return string(path) # anything not in deps wont be compiled
  child = io[:currentdir] * path
  @assert (io[:basedir] * child) ⊆ io[:basedir] "$path reaches out of the base directory"
  dep = deps[path]
  if !(child in io[:seen])
    push!(io[:seen], child)
    compile(subctx(io, dep.source), dep)
  end
  mime = invokelatest(compiled_type, dep.source, dep.value)
  string(isdir(dep.source) ? path * "index.html" : setext(path, extension(mime)))
end

getignores(dir::FSPath) = ispath(dir * ".canonignore") ? map(FilenameMatch, readlines(dir * ".canonignore")) : Any[]
shouldignore(path::FSPath, ignores) = begin
  occursin(r"^readme\.\w+$"i, path.name) && return true
  any(pattern->occursin(pattern, path.name), ignores)
end

function html(review::BookReview)
  @dom[:article css"""
    max-width: 800px
    margin: 2rem auto
    padding: 2rem
    background-color: #ffffff
    border-radius: 12px
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1)
    font-family: sans-serif
    line-height: 1.6
    color: #333
    h1
      font-size: 2.5rem
      margin-bottom: 1rem
      color: #1a1a1a
      border-bottom: 2px solid #eee
      padding-bottom: 0.5rem
    > div
      display: flex
      align-items: center
      gap: 1rem
      margin-bottom: 1.5rem
      font-size: 0.9rem
      color: #666
    > div a
      text-decoration: none
      color: #007bff
      font-weight: bold
      transition: color 0.3s ease
    > div a:hover
      color: #0056b3
    > div span:first-of-type
      color: #ffd700
      font-size: 1.2rem
    > div span:nth-of-type(2) { flex-grow: 1 }
    > div > div
      background-color: #f0f0f0
      padding: 0.3rem 0.8rem
      border-radius: 20px
      font-weight: bold
      color: #444
    > div.md { flex-wrap: wrap }
    > div.md > p
      align-self: self-start
      width: calc(33.3% - 0.8rem)
    div.md:has(> :nth-child(2)):not(:has(> :nth-child(3))) > p { width: calc(50% - 0.5rem)}
    div.md:not(:has(> :nth-child(2))) > p { width: 100% }
    p { margin-bottom: 1rem }
    a
      color: #007bff;
      text-decoration: underline
    a:hover { text-decoration: none }
    """
    [:h1 review.title]
    [:div
      [:a href=string(review.link) review.link.host]
      [:span string(fill('★', review.rating)...)]
      [:span review.description]
      [:div format(review.pubDate, dateformat"yyyy")]]
    review.content]
end

function insert_tracker!(_, _) end
function insert_tracker!(dom::DOM.Container{:html}, io::IOContext)
  head = dom.children[1]
  head isa DOM.Container{:head} || return nothing
  pushfirst!(head.children, DOM.Literal(io[:tracker]))
end

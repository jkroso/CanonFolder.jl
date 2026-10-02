@use "github.com/jkroso/URI.jl" ["FSPath" FSPath @fs_str RelativePath] ["FS" Directory File FSObject]
@use "github.com/jkroso/Prospects.jl" assoc need @field_str flatten
@use "github.com/jkroso/JSON.jl/read"
@use "github.com/jkroso/Units.jl" B Magnitude abbr Byte
@use "github.com/jkroso/DOM.jl" => DOM css @dom @css_str ["html"]
@use "./load" Compilable MarkdownDocument BookReview inline_md
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

# Every page is set in Literata, a book face drawn for reading on screens, on cream paper with warm ink. Links are
# the one colour: a rubric red.
const fonts_url = "https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,400..700;1,7..72,400..700&display=swap"
const page_head = [@dom[:meta charset="UTF-8"],
                   @dom[:meta name="viewport" content="width=device-width, initial-scale=1"],
                   @dom[:meta name="color-scheme" content="light"],
                   @dom[:link rel="preconnect" href="https://fonts.googleapis.com"],
                   @dom[:link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous"],
                   @dom[:link rel="stylesheet" href=fonts_url]]

const paper_css = raw"""
:root {
  --paper: #f5efe1;
  --paper-raised: #faf6ec;
  --paper-sunk: #ece3cf;
  --ink: #2b2620;
  --ink-2: #574e41;
  --ink-3: #6e6352;
  --rule: #ddd1b8;
  --rule-strong: #c4b391;
  --accent: #963820;
  --accent-soft: rgba(150, 56, 32, 0.34);
  --select: #ecd3be;
  --serif: "Literata", "Iowan Old Style", Charter, Georgia, serif;
  --mono: ui-monospace, "SF Mono", "Source Code Pro", Menlo, Consolas, monospace;
  --measure: 33.5em;
  color-scheme: light;
}
html { background: var(--paper); -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
body {
  margin: 0;
  padding: 0 1.25rem;
  background: var(--paper);
  color: var(--ink);
  font-family: var(--serif);
  font-size: clamp(1.0625rem, 0.95rem + 0.4vw, 1.1875rem);
  line-height: 1.62;
  font-optical-sizing: auto;
  font-kerning: normal;
  font-variant-ligatures: common-ligatures;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
  hanging-punctuation: first;
}
::selection { background: var(--select); color: var(--ink); }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 2px; }
a {
  color: var(--accent);
  text-decoration: underline;
  text-decoration-color: var(--accent-soft);
  text-decoration-thickness: 1px;
  text-underline-offset: 0.2em;
  transition: text-decoration-color 0.15s ease-out, color 0.15s ease-out;
}
a:hover { text-decoration-color: currentColor; }

/* the reading column */
.essay, .review { max-width: var(--measure); margin: 0 auto; padding: clamp(2.5rem, 7vw, 4.5rem) 0 5rem; }
.md { position: relative; }
h1, h2, h3, h4 { color: var(--ink); line-height: 1.15; text-wrap: balance; font-variant-numeric: lining-nums; }
h1 { font-size: 2.3em; font-weight: 640; letter-spacing: -0.02em; line-height: 1.08; text-align: center; margin: 0 0 1.1em; }
h2 { font-size: 1.4em; font-weight: 620; letter-spacing: -0.01em; margin: 2.1em 0 0.55em; }
h3 { font-size: 1.12em; font-weight: 620; margin: 1.8em 0 0.45em; }
h4 { font-size: 1em; font-weight: 560; font-style: italic; margin: 1.6em 0 0.4em; }
h1 + h2, h2 + h3 { margin-top: 0.6em; }
p { margin: 0 0 1.05em; }
p, li { text-wrap: pretty; hyphens: auto; -webkit-hyphens: auto; }
ul, ol { margin: 0 0 1.05em; padding-left: 1.4em; }
li { margin: 0.3em 0; }
li > * { margin-top: 0; margin-bottom: 0; }
li::marker { color: var(--ink-3); }
strong, b { font-weight: 640; }
em, i { font-style: italic; }
hr { border: 0; width: 5em; height: 1px; margin: 2.6em auto; background: var(--rule-strong); }
img, video, svg { max-width: 100%; height: auto; }
section { display: flex; justify-content: center; }
sup, sub { line-height: 0; }
blockquote { position: relative; margin: 1.9em 0; padding: 0 0 0 1.6em; color: var(--ink-2); font-style: italic; }
blockquote::before {
  content: "\201C"; position: absolute; left: -0.06em; top: -0.18em;
  font-size: 2.9em; line-height: 1; font-style: normal; color: var(--accent); opacity: 0.4;
}
blockquote p { margin: 0 0 0.7em; }
blockquote p:last-child { margin-bottom: 0; }
blockquote cite { display: block; margin-top: 0.7em; font-style: normal; font-size: 0.9em; color: var(--ink-3); text-align: right; }
code { font-family: var(--mono); font-size: 0.84em; background: var(--paper-sunk); padding: 0.12em 0.32em; border-radius: 3px; }
pre, .highlight > pre {
  font: 0.84em/1.6 var(--mono); background: var(--paper-raised); color: var(--ink);
  border: 1px solid var(--rule); border-radius: 4px; padding: 1em 1.2em; overflow-x: auto; margin: 1.5em 0;
}
pre code { background: none; padding: 0; font-size: 1em; }
table { border-collapse: collapse; width: 100%; margin: 1.6em 0; font-size: 0.92em; font-variant-numeric: lining-nums tabular-nums; }
th, td { text-align: left; vertical-align: top; padding: 0.45em 1em 0.45em 0; border-bottom: 1px solid var(--rule); }
th { color: var(--ink-2); font-weight: 600; border-bottom-color: var(--rule-strong); }

/* footnotes: notes in the margin beside the line that calls them, or gathered at the end when there's no margin */
.footnote-ref {
  position: absolute; width: 0.42em; height: 0.42em; margin: 0.36em 0 0 0.1em;
  border-radius: 50%; background: var(--accent); color: transparent; text-decoration: none;
}
.footnote-def {
  position: absolute; width: 13.5rem; box-sizing: border-box;
  font-size: 0.8em; line-height: 1.45; color: var(--ink-2);
  padding: 0.1em 0 0.1em 0.9em; border-left: 1px solid var(--rule-strong);
}
.footnote-def.right { right: -16.5rem; }
.footnote-def.left { left: -16.5rem; }
.footnote-def p { margin: 0 0 0.5em; hyphens: manual; }
.footnote-def p:last-child { margin: 0; }
@media (max-width: 77rem) {
  .footnote-ref {
    position: static; width: auto; height: auto; margin: 0 0 0 0.05em;
    background: none !important; color: var(--fn, var(--accent)); font-size: 0.85em; font-variant-numeric: lining-nums;
  }
  .footnote-def {
    position: static; width: auto; font-size: 0.86em; margin: 0; padding: 0.7em 0 0.7em 1.8em;
    border-left: 0; border-top: 1px solid var(--rule); position: relative;
  }
  .footnote-def.left, .footnote-def.right { left: auto; right: auto; }
  .footnote-def::before { content: attr(data-n); position: absolute; left: 0; color: var(--fn, var(--accent)); font-variant-numeric: lining-nums; }
}

/* book reviews */
.review .meta {
  display: flex; flex-wrap: wrap; justify-content: center; align-items: baseline; gap: 0.3em 1.1em;
  margin: -0.4em 0 1.3em; font-size: 0.9em; color: var(--ink-3); font-variant-numeric: lining-nums;
}
.review .stars { color: #8f6516; letter-spacing: 0.12em; }
.review .standfirst {
  max-width: 28em; margin: 0 auto 2.4em; text-align: center; font-style: italic;
  font-size: 1.12em; line-height: 1.45; color: var(--ink-2); text-wrap: balance;
}

/* folders: a preface from the readme, then the listing */
.index { max-width: 52rem; margin: 0 auto; padding: clamp(2rem, 6vw, 4rem) 0 4rem; }
.preface { display: block; margin: 0 0 2.6rem; }
.preface .essay { max-width: none; }
.preface .essay { padding: 0; }
.preface .md > :last-child { margin-bottom: 0; }
.listing {
  display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 4fr) auto auto auto;
  font-size: 0.8em; line-height: 1.45; font-variant-numeric: lining-nums tabular-nums;
}
.listing .header {
  padding: 0 1.1rem 0.45em 0; border-bottom: 1px solid var(--rule-strong);
  font-size: 0.78em; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--ink-3);
}
.listing .cell { display: flex; align-items: center; min-width: 0; padding: 0.45em 1.1rem 0.45em 0; border-bottom: 1px solid var(--rule); }
.listing .header:nth-child(5n), .listing .cell:nth-child(5n) { padding-right: 0; }
.listing .cell:nth-last-child(-n+5) { border-bottom: none; }
.listing .header:nth-child(5n+3), .listing .header:nth-child(5n+4), .listing .header:nth-child(5n),
.listing .cell:nth-child(5n+3), .listing .cell:nth-child(5n+4), .listing .cell:nth-child(5n) { justify-content: flex-end; text-align: right; }
.listing .cell:nth-child(5n+3), .listing .cell:nth-child(5n+4), .listing .cell:nth-child(5n) { color: var(--ink-3); font-size: 0.9em; white-space: nowrap; }
.listing a { display: inline-flex; align-items: center; color: var(--ink); font-weight: 560; text-decoration: none; }
.listing a:hover { color: var(--accent); }
.listing a:hover > span:last-child, .listing a:hover { text-decoration: underline; text-decoration-color: var(--accent-soft); text-underline-offset: 0.2em; }
.listing a svg { flex: none; width: 1.3em; height: auto; margin-right: 0.6em; }
.listing .summary { color: var(--ink-2); font-style: italic; }
@media (max-width: 44rem) {
  .listing { grid-template-columns: minmax(0, 1fr); }
  .listing .header, .listing .cell:nth-child(5n+3), .listing .cell:nth-child(5n+4), .listing .cell:nth-child(5n) { display: none; }
  .listing .cell:nth-child(5n+1) { border-bottom: none; padding-bottom: 0.1em; }
  .listing .cell:nth-child(5n+2) { padding: 0 0 0.55em 1.9em; font-size: 0.95em; }
  .listing .cell:nth-child(5n+2):empty { padding-bottom: 0.6em; }
}

@media print {
  @page { size: A4; margin: 1.6cm; }
  html, body { background: #fff; }
  body { font-size: 10.5pt; padding: 0; }
  .essay, .review { max-width: 32em; padding: 0; }
  .footnote-def { width: 12em; font-size: 0.78em; }
  .footnote-def.left { left: -13em; }
  .footnote-def.right { right: -13em; }
  h1, h2, h3, h4 { break-after: avoid; }
  pre, blockquote, table, img { break-inside: avoid; }
}
"""

# Places each footnote in the margin beside the line that calls it, alternating sides, keeping notes on the same side
# from overlapping. Where there's no margin the CSS gathers them at the end, numbered.
const sidenotes_js = raw"""
document.addEventListener('DOMContentLoaded', () => {
  const colors = ['#a84a2b', '#386e68', '#8a6214', '#685892', '#4a6e37', '#a14760', '#3b6795', '#86663b', '#2e685a', '#973b2a', '#605c87', '#55712d']
  const notes = []
  document.querySelectorAll('.footnote-def').forEach((def, i) => {
    const ref = document.querySelector(`.footnote-ref[href="#${def.id}"]`)
    if (!ref) return
    const color = colors[i % colors.length]
    def.style.borderColor = color
    def.style.setProperty('--fn', color)
    ref.style.backgroundColor = color
    ref.style.setProperty('--fn', color)
    def.dataset.n = ref.textContent.trim()
    def.classList.add(i % 2 ? 'left' : 'right')
    notes.push({ def, ref })
  })
  const wide = matchMedia('(min-width: 77.0625rem)')
  const place = () => {
    const end = { left: -Infinity, right: -Infinity }
    const byPosition = notes.slice().sort((a, b) => a.ref.getBoundingClientRect().top - b.ref.getBoundingClientRect().top)
    for (const { def, ref } of byPosition) {
      if (!wide.matches) { def.style.top = ''; continue }
      const host = def.offsetParent || def.parentElement
      const side = def.classList.contains('left') ? 'left' : 'right'
      let top = ref.getBoundingClientRect().top - host.getBoundingClientRect().top - 3
      top = Math.max(top, end[side] + 14)
      def.style.top = top + 'px'
      end[side] = top + def.offsetHeight
    }
  }
  place()
  if (document.fonts) document.fonts.ready.then(place)
  wide.addEventListener('change', place)
  addEventListener('resize', place)
})
"""

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
    @dom[:section class="preface" html(deps[FSPath(children[i].name)].value)]
  end
  body = @dom[:body [:div class="index" readme directory(dir.path, children, io, deps)]]
  dom = @dom[:html
    [:head [:title dir.path.name] page_head... invokelatest(need, css[]) [:style paper_css]]
    body]
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
  @dom[:div class="listing"
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
describe(::File{:md}, md::MarkdownDocument) = inline_md(get(md.meta, "description", ""))
describe(::File{:review}, br::BookReview) = inline_md(br.description)
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
html(md::MarkdownDocument) = @dom[:article class="essay" md.content]

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
      [:title splitext(file.path.name)[1]]
      page_head...
      need(DOM.css[])
      [:style paper_css]
      [:script sidenotes_js]]
    [:body html(object)]]
end

compiled_type(_) = MIME("text/html")
compiled_type(::Directory, _) = MIME("text/html")
compiled_type(::File{x}, value) where x = mime_from_extension(string(x), binary_mime)
compiled_type(::File{:jl}, value) = compiled_type(value) # julia can produce objects that compile to anything
compiled_type(::File{:md}, value) = compiled_type(value)
compiled_type(::File{:review}, value) = MIME("text/html")
compiled_type(::File{:less}, value) = MIME("text/css")
encode(mime, data) = convert(Vector{UInt8}, codeunits(sprint(show, mime, data)))
encode(mime::MIME"text/html", data::DOM.Container{:html}) = convert(Vector{UInt8}, codeunits("<!DOCTYPE html>" * sprint(show, mime, data)))
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
  @dom[:article class="review"
    [:h1 review.title]
    [:div class="meta"
      [:a href=string(review.link) review.link.host]
      [:span class="stars" title="$(review.rating) stars" string(fill('★', review.rating)...)]
      [:span class="year" format(review.pubDate, dateformat"yyyy")]]
    [:div class="standfirst" inline_md(review.description)]
    review.content]
end

function insert_tracker!(_, _) end
function insert_tracker!(dom::DOM.Container{:html}, io::IOContext)
  head = dom.children[1]
  head isa DOM.Container{:head} || return nothing
  pushfirst!(head.children, DOM.Literal(io[:tracker]))
end

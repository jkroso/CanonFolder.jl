@use "github.com/jkroso/URI.jl" URI ["FSPath.jl" FSPath @fs_str] ["FS.jl" File Directory FSObject]
@use "github.com/jkroso/Prospects.jl" @field_str @def @property @lazyprop
@use "github.com/jkroso/Sequences.jl" Cons push ["collections/Map" Map]
@use "github.com/jkroso/DOM.jl" => DOM @dom
@use Glob: FilenameMatch
@use CommonMark
@use Dates...
@use TOML

const relative_path = r"(?:\.{1,2}/)+(?:[-_a-zA-Z ]+/)*[-_a-zA-Z ]+\.[a-z]+"

struct MacOSStat
  st_dev::UInt32           # ID of device containing file
  st_mode::UInt16          # Mode of file
  st_nlink::UInt16         # Number of hard links
  st_ino::UInt64           # File serial number
  st_uid::UInt32           # User ID of the file
  st_gid::UInt32           # Group ID of the file
  st_rdev::UInt32          # Device ID
  st_atimespec::NTuple{2, Int64}     # time of last access (tv_sec, tv_nsec)
  st_mtimespec::NTuple{2, Int64}     # time of last data modification
  st_ctimespec::NTuple{2, Int64}     # time of last status change
  st_birthtimespec::NTuple{2, Int64} # time of file creation (birth)
  st_size::Int64           # file size, in bytes
  st_blocks::Int64         # blocks allocated for file
  st_blksize::Int32        # optimal blocksize for I/O
  st_flags::UInt32         # user defined flags for file
  st_gen::UInt32           # file generation number
  st_lspare::Int32         # RESERVED
  st_qspare::NTuple{2, Int64} # RESERVED
end

function birthtime(path)
  buf = Ref{MacOSStat}()
  rc = ccall(:stat, Cint, (Cstring, Ptr{MacOSStat}), string(path), buf)
  if rc != 0
    throw(SystemError("stat failed", errno()))
  end
  sec, nsec = buf[].st_birthtimespec
  unix_time = sec + nsec / 1_000_000_000.0
  unix2datetime(unix_time)
end

"""
Couples a source file and the value the file evauluates to so they can be passed
through the compiler together
"""
@def mutable struct Compilable
  source::FSObject
  btime::Date
  mtime::Float64
  value::Any
  dependencies::Map{FSPath,Compilable}
  Compilable(source::FSPath) = Compilable(get(abs(source)))
  Compilable(source::FSObject) = Compilable(source, readin(source))
  Compilable(source::FSObject, value) = new(source, birthtime(source.path), mtime(source.path), value)
end

@lazyprop Compilable.dependencies = begin
  path = dirname(self.source)
  deps = dependencies(self.source, self.value)
  nodes = (Compilable(path * dep) for dep in deps)
  Map{FSPath,Compilable}(map(kv->kv[1]=>kv[2], zip(deps, nodes))...)
end

dependencies(x) = Cons{FSPath}()
dependencies(file, object) = dependencies(object)
dependencies((;path)::Directory, files) = begin
  patterns = getignores(path)
  convert(Cons{FSPath}, (FSPath(f.name) for f in files if !shouldignore(f, patterns)))
end

function dependencies(c::DOM.Container)
  deps = reduce(c.attrs, init=Cons{FSPath}()) do out, (k, v)
    k in (:href, :src) && return isrelative(v) ? push(out, FSPath(v)) : out
    k == :style && return cat(out, style_dependencies(v))
    out
  end
  mapreduce(dependencies, cat, c.children, init=deps)
end

function style_dependencies(s::AbstractString)
  matches = map(field"match", eachmatch(relative_path, v))
  convert(Cons{FSPath}, map(FSPath, matches))
end

function style_dependencies(d::AbstractDict)
  reduce(values(d), init=Cons{FSPath}()) do out, v
    m = match(relative_path, v)
    isnothing(m) ? out : Cons(FSPath(m.match), out)
  end
end

function dependencies(c::DOM.Container{:style})
  css = string(map(field"value", c.children)...)
  matches = map(field"match", eachmatch(relative_path, css))
  convert(Cons{FSPath}, map(FSPath, matches))
end

isrelative(url) = occursin(relative_path, url)

struct MarkdownDocument
  meta::Dict
  content::DOM.Node
end

dependencies(md::MarkdownDocument) = dependencies(md.content)

const md_parser = CommonMark.Parser()
CommonMark.enable!(md_parser, CommonMark.FrontMatterRule(toml=TOML.parse))
CommonMark.enable!(md_parser, CommonMark.MathRule())
CommonMark.enable!(md_parser, CommonMark.TableRule())
CommonMark.enable!(md_parser, CommonMark.FootnoteRule())

"""
Convert a CommonMark AST node to a DOM.jl node representation.
"""
const md_simple_tags = Dict(
  CommonMark.Paragraph => :p,
  CommonMark.Strong => :strong,
  CommonMark.Emph => :em,
  CommonMark.BlockQuote => :blockquote,
  CommonMark.Item => :li,
  CommonMark.LineBreak => :br,
  CommonMark.ThematicBreak => :hr,
  CommonMark.Table => :table,
  CommonMark.TableHeader => :thead,
  CommonMark.TableBody => :tbody,
  CommonMark.TableRow => :tr,
)

function ast_to_dom(node)
  element_type = typeof(node.t)

  # Helper function to get children as array
  function collect_children()
    children = []
    child = node.first_child
    while !CommonMark.isnull(child)
      push!(children, ast_to_dom(child))
      child = child.nxt
    end
    children
  end

  if haskey(md_simple_tags, element_type)
    DOM.Container{md_simple_tags[element_type]}(DOM.empty_dict, collect_children())

  elseif element_type == CommonMark.Document
    children = collect_children()
    @dom[:div class="md" children...]

  elseif element_type == CommonMark.Heading
    level = node.t.level
    tag = level <= 6 ? Symbol("h$level") : :h6
    DOM.Container{tag}(DOM.empty_dict, collect_children())

  elseif element_type == CommonMark.Text
    DOM.Text(node.literal)

  elseif element_type == CommonMark.Code
    @dom[:code node.literal]

  elseif element_type == CommonMark.Link
    children = collect_children()
    if !isempty(node.t.title)
      @dom[:a href=node.t.destination title=node.t.title children...]
    else
      @dom[:a href=node.t.destination children...]
    end

  elseif element_type == CommonMark.Image
    # Extract alt text from children
    alt_texts = []
    child = node.first_child
    while !CommonMark.isnull(child)
      if typeof(child.t) == CommonMark.Text
        push!(alt_texts, child.literal)
      end
      child = child.nxt
    end
    alt_text = join(alt_texts, "")

    if !isempty(node.t.title) && !isempty(alt_text)
      @dom[:img src=node.t.destination alt=alt_text title=node.t.title]
    elseif !isempty(node.t.title)
      @dom[:img src=node.t.destination alt="" title=node.t.title]
    elseif !isempty(alt_text)
      @dom[:img src=node.t.destination alt=alt_text]
    else
      @dom[:img src=node.t.destination alt=""]
    end

  elseif element_type == CommonMark.List
    children = collect_children()
    if node.t.list_data.type == :ordered
      if node.t.list_data.start != 1
        @dom[:ol start=string(node.t.list_data.start) children...]
      else
        @dom[:ol children...]
      end
    else
      @dom[:ul children...]
    end

  elseif element_type == CommonMark.CodeBlock
    if !isnothing(node.t.info) && !isempty(node.t.info)
      lang_class = "language-" * split(node.t.info)[1]
      @dom[:pre [:code class=lang_class node.literal]]
    else
      @dom[:pre [:code node.literal]]
    end

  elseif element_type == CommonMark.SoftBreak
    DOM.Text(" ")  # Convert soft breaks to spaces

  elseif element_type == CommonMark.TableCell
    children = collect_children()
    if node.t.header
      if node.t.align != :left
        @dom[:th style="text-align: $(node.t.align)" children...]
      else
        @dom[:th children...]
      end
    else
      if node.t.align != :left
        @dom[:td style="text-align: $(node.t.align)" children...]
      else
        @dom[:td children...]
      end
    end

  elseif element_type == CommonMark.Math
    @dom[:span class="math-inline" "\$$(node.literal)\$"]
  elseif element_type == CommonMark.DisplayMath
    @dom[:div class="math-display" "\$\$$(node.literal)\$\$"]

  elseif element_type == CommonMark.FootnoteLink
    @dom[:a href="#fn-$(node.t.id)" class="footnote-ref" [:sup string(node.t.id)]]
  elseif element_type == CommonMark.FootnoteDefinition
    @dom[:div id="fn-$(node.t.id)" class="footnote-def" collect_children()...]
  elseif element_type == CommonMark.FrontMatter
    DOM.Text("")
  elseif element_type == CommonMark.HtmlBlock
    parse(MIME("text/html"), node.literal)
  elseif element_type == CommonMark.Backslash
    DOM.Text(node.literal)
  else
    # Fallback for unknown node types
    @info "Unknown CommonMark AST node type: $element_type, falling back to children processing"
    if !CommonMark.isnull(node.first_child)
      children = collect_children()
      @dom[:span children...]
    else
      DOM.Text(get(node, :literal, ""))
    end
  end
end

parsemd(str) = begin
  md = md_parser(str)
  doc = ast_to_dom(md)
  MarkdownDocument(CommonMark.frontmatter(md), doc)
end

Base.show(io::IO, M::MIME"text/html", md::MarkdownDocument) = show(io, M, md.content)

readin((;path)::File{:md}) = parsemd(read(path, String))
readin((;path)::File{:jl}) = cd(()->Kip.eval_module(string(path)), path.parent)
readin((;path)::File) = read(path)
readin((;path)::Directory) = readdir(path)

readin(file::File{:review}) = begin
  (;meta, content) = parsemd(read(file.path, String))
  BookReview(meta["title"],
             URI(meta["link"]),
             get(meta, "description", ""),
             get(meta, "rating", 1),
             get(meta, "pubDate", Date(0)),
             content)
end

struct BookReview
  title::String
  link::URI
  description::String
  rating::Int8
  pubDate::Date
  content::DOM.Node
end

getignores(dir::FSPath) = begin
  patterns = Any[r"^\.|^favicon\.ico$|^tracker\.html$"] # defaults to ignoring favicons and anything begining with a .
  ispath(dir * ".gitignore") && push!(patterns, map(FilenameMatch, readlines(dir * ".gitignore"))...)
  patterns
end

shouldignore(path::FSPath, ignores) = any(pattern->occursin(pattern, path.name), ignores)

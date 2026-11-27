# A page made in Ladder (github.com/jkroso/Ladder), the Markdown editor whose pages work things out, as a page of the
# site. canon reads the page with Ladder's own code, so the site shows what Ladder shows:
#
#   - !`code` is a sum. Each one runs from the top of the page down, in one module that has the units of Units.jl, and
#     the page shows what it came to: !`chip_bill = chip_price * compute` shows "25 billion USD". The mouse on a
#     number shows the code that made it.
#   - A `sheet` block works out its rows, with the sums over it. It shows as a table of each row's name, its
#     expression, and what that comes to.
#   - A `chart` block draws the table over it, or the tables that its `from` names, as a picture in SVG.
#   - A `mermaid` block is a diagram, which the browser draws with Mermaid.
#   - A `columns` block puts the blocks after it side by side.
#   - A `view` block of a Julia file shows what the file's function `view` makes of the page's sums. The bytes of a
#     .glb file show as a model that the mouse turns. A view of a picture shows the picture. The file that a view
#     names goes beside the page as it is, so that Ladder, which reads the page's Markdown from the site, shows it.
#   - Formulas between $ and $$ go in as MathML, a callout like > [!NOTE] is a note in a box, and the footnotes go in
#     the margin, as on the rest of the site.
#
# The numbers are the ones that the page starts with. On the site they don't change: a reader can't drag them.
#
# Ladder's files come from its folder beside canon's, ../Ladder, and load.jl loads this file only when canon first
# meets a Ladder page.

@use "../Ladder/markdown" Kind Line classify spans tablecells isdivider front_matter
@use "../Ladder/html" html escape
@use "../Ladder/sheet" tally cases shown units parts ident Given SHEET folded
@use "../Ladder/chart" => Charts
@use "../Ladder/columns" => Columns
@use "github.com/jkroso/Units.jl" => Units
@use "github.com/jkroso/Units.jl/Money" => Cash
@use "github.com/jkroso/JSON.jl/read"
@use TOML

"What a sum came to: the text that the page shows for it, true when that text says what went wrong, and the value"
struct Sum
  code::String
  text::String
  failed::Bool
  value::Any
end

"A table of the page, for a chart to draw: the lines it's on, the heading it's under, the text of each cell, and the amount of each cell that is one sum"
struct Table
  first::Int
  last::Int
  under::String
  rows::Vector{Vector{String}}
  headed::Bool
  ranged::Bool
  values::Union{Nothing,Vector{Vector{Any}}}
end

"A Ladder page as canon makes it into HTML"
mutable struct Page
  path::String                      # the page's file, by its real path, so that a view finds a file beside it
  lines::Vector{String}
  kinds::Vector{Line}
  mod::Module                       # where the page's sums and code run
  sums::Vector{Sum}                 # each sum of the page, from the top down
  given::Vector{Tuple{String,Any}}  # the names that a sheet has from the parts of the page over it
  named::Dict{String,Any}           # what each sum that gives a name came to, for a view's function
  tables::Vector{Table}
  blocks::Dict{Int,String}          # the HTML of each block, by the line that opens it
  files::Dict{String,Vector{UInt8}} # files that go beside the page, like a model that a view shows
  scripts::Set{Symbol}              # the scripts that the page needs: :mermaid, :model
end

"""
The page of the Markdown `text` of the file at `path`: what its front matter says, the HTML of the page, without the
page round it, and the files that go beside it, by name
"""
page(path::AbstractString, text::AbstractString) = begin
  lines = String.(split(replace(text, "\r\n" => "\n"), '\n'))
  p = Page(realpath(path), lines, classify(lines), newmodule(), Sum[], Tuple{String,Any}[], Dict{String,Any}(), Table[],
           Dict{Int,String}(), Dict{String,Vector{UInt8}}(), Set{Symbol}())
  cd(() -> run!(p), dirname(p.path))
  for (i, k) in enumerate(p.kinds)
    k.kind == Kind.fence && k.level == 0 && k.lang == "view" && (p.blocks[i] = view_html(p, i))
    k.kind == Kind.fence && k.level == 0 && k.lang == "mermaid" && (p.blocks[i] = mermaid_html(p, i))
    k.kind == Kind.fence && k.level == 0 && k.lang in Columns.LANGS && (p.blocks[i] = "")
  end
  cols = columns(p)
  for (i, k) in enumerate(p.kinds)
    k.kind == Kind.fence && k.level == 0 && k.lang == "chart" && (p.blocks[i] = chart_html(p, i, share(cols, i)))
  end
  out = html(lines, block=(lang, s, t) -> get(p.blocks, s, nothing), value=sum_marker(p), columns=cols)
  body = match(r"<body>\n(.*)</body>"s, out)[1]
  (meta(lines), scripts(p, sidenotes(sums_shown(p, body))), p.files)
end

# --- the sums ----------------------------------------------------------------------------

"A module for the page's code, with the units that a sheet has, like m, kg, GW, USD and Percent"
newmodule() = begin
  m = Module(:LadderPage)
  Core.eval(m, :(const SheetUnits = $(units())))
  Core.eval(m, :(using .SheetUnits))
  Core.eval(m, :(const Kip = $Kip))
  Core.eval(m, :(using .Kip))
  m
end

"""
Run the page from the top down: each sum in a line of text, each sheet with the names over it, and each `julia`
block. Keep each table, with what its sums came to, for the charts.
"""
run!(p::Page) = begin
  lines, ks = p.lines, p.kinds
  under = ""
  i = 1
  while i <= length(lines)
    k, text = ks[i], lines[i]
    if k.kind == Kind.fence && k.level == 0
      t = something(findnext(l -> l.kind == Kind.fence && l.level == 1, ks, i + 1), length(lines) + 1)
      body = lines[i+1:min(t - 1, end)]
      k.lang == SHEET && (p.blocks[i] = sheet!(p, i, t, under, body))
      k.lang == "julia" && runcode!(p, join(body, '\n'), i)
      i = t + 1
      continue
    elseif k.kind == Kind.heading
      at = length(p.sums) + 1
      sums!(p, chop(text, head=k.prefix, tail=0))
      under = plain(p, chop(text, head=k.prefix, tail=0), at)
    elseif k.kind == Kind.table
      j = i
      while j < length(lines) && ks[j+1].kind == Kind.table; j += 1 end
      if j > i && isdivider(lines[i+1])
        table!(p, i, j, under)
      else
        foreach(r -> sums!(p, lines[r]), i:j)
      end
      i = j + 1
      continue
    elseif k.kind in (Kind.bullet, Kind.ordered, Kind.todo, Kind.blockquote)
      sums!(p, chop(text, head=k.prefix, tail=0))
    elseif k.kind == Kind.paragraph
      m = match(r"^\[\^([^\]\s]+)\]:\s*", text)   # a footnote's text
      sums!(p, m === nothing ? text : chop(text, head=length(m.match), tail=0))
    end
    i += 1
  end
end

"Run each sum of the text `text`, which is part of a line, in the order that the page shows them"
sums!(p::Page, text::AbstractString) = for s in spans(text)
  s.live && !s.comment && push!(p.sums, runsum(p, s.text))
end

"Run the code of one sum, in the page's module, and keep what it came to"
runsum(p::Page, code::String) = begin
  name = sum_name(code)
  try
    value = Base.invokelatest(Core.eval, p.mod, Meta.parse(code))
    if name !== nothing
      p.named[string(name)] = value
      push!(p.given, (replace(string(name), '_' => ' '), Given(value)))
    end
    Sum(code, said(value), false, value)
  catch err
    err = err isa LoadError ? err.error : err
    problem = String(first(split(sprint(showerror, err), '\n')))
    @warn "A sum of $(basename(p.path)) went wrong" code problem
    name === nothing || push!(p.given, (replace(string(name), '_' => ' '), code[nextind(code, findfirst('=', code)):end]))
    Sum(code, said(problem), true, nothing)
  end
end

"The name that the code of a sum gives, like `:farm` for `farm = 2GW`, or nothing"
sum_name(code::AbstractString) = begin
  ex = try Meta.parse(code, raise=false) catch; nothing end
  ex isa Expr && ex.head == :(=) && length(ex.args) == 2 && ex.args[1] isa Symbol ? ex.args[1] : nothing
end

"The code of a `julia` block, run in the page's module. Its names are the page's, so the sums under it can use them."
runcode!(p::Page, code::AbstractString, line::Int) = try
  Base.invokelatest(include_string, p.mod, "\n"^line * code, p.path)
catch err
  @warn "The code on line $line of $(basename(p.path)) went wrong" exception=err
end

const LONGEST_VALUE = 200   # characters of a value that a sum shows, as in Ladder

"A value as the text that a sum shows for it, as Ladder shows it: 28.8 and not 28.799999999999997, with its unit"
said(value) = begin
  text = value isa AbstractString ? String(value) : value === nothing ? "nothing" : Base.invokelatest(shown, value)
  text = replace(text, r"\s*\n\s*" => " ")
  length(text) > LONGEST_VALUE ? first(text, LONGEST_VALUE) * "…" : text
end

# Ladder's `html` writes what a sum shows as text, and escapes it. So each sum goes in as a mark that stands for it,
# which nothing escapes, and `sums_shown` puts the sum's HTML in its place.
const MARK = Regex("\ue000(\\d+)\ue001")

"What Ladder's `html` puts in place of each sum: a mark with the sum's place among the page's sums"
sum_marker(p::Page) = begin
  next = Ref(1)
  code -> begin
    k = next[]
    if k <= length(p.sums) && p.sums[k].code == code
      next[] += 1
    else
      k = something(findfirst(s -> s.code == code, p.sums), 0)
      k == 0 && return nothing
    end
    "\ue000$(k)\ue001"
  end
end

"`body` with the HTML of each sum in place of its mark: what it came to, with its code for the mouse to show"
sums_shown(p::Page, body::AbstractString) = replace(body, MARK => m -> begin
  s = p.sums[parse(Int, match(MARK, m)[1])]
  "<span class=\"sum$(s.failed ? " failed" : "")\" title=\"$(escape(s.code))\">$(escape(s.text))</span>"
end)

# --- tables, sheets and charts -----------------------------------------------------------

"The cells of a row of a table, as text, as Ladder's `html` reads them"
cells(text) = [strip(String(collect(text)[c.lo+1:c.hi])) for c in tablecells(text)]

"""
The text of `text` without its markup, and with what each sum in it came to in place of its code. `k` is the place of
its first sum among the page's sums.
"""
plain(p::Page, text::AbstractString, k::Int) = begin
  out = IOBuffer()
  for s in spans(text)
    (s.markup || s.comment) && continue
    if s.live
      k <= length(p.sums) && print(out, p.sums[k].failed ? "" : p.sums[k].text)
      k += 1
    else
      print(out, s.text)
    end
  end
  String(strip(String(take!(out))))
end

"Run the sums of the table on lines `i` to `j`, and keep the table for the charts"
table!(p::Page, i::Int, j::Int, under::String) = begin
  rows, values = Vector{String}[], Vector{Any}[]
  for r in i:j
    r == i + 1 && continue   # the line of dashes
    row, amounts = String[], Any[]
    for cell in cells(p.lines[r])
      k = length(p.sums) + 1
      sums!(p, cell)
      push!(row, plain(p, cell, k))
      # A cell that is one sum is read as the amount it came to, with its unit
      one = length(p.sums) == k && occursin(r"^!`[^`]+`$", cell) && !p.sums[k].failed ? folded(p.sums[k].value) : nothing
      push!(amounts, one isa Units.Unit ? one : nothing)
    end
    push!(rows, row)
    push!(values, amounts)
  end
  push!(p.tables, Table(i, j, under, rows, true, false, values))
end

"""
The HTML of the sheet whose block is lines `i` to `t`, as a table of each row's name, its expression and what it came
to. It keeps the sheet for the charts: a sheet with a row over a range is a table with a row for each value of that row.
"""
sheet!(p::Page, i::Int, t::Int, under::String, body) = begin
  texts = [parts(l) for l in body]
  given = copy(p.given)
  results = tally(texts; given)
  over = cases(texts; given)
  if over === nothing
    push!(p.tables, Table(i, t, under, [String[strip(name), results[r].failed ? "" : results[r].text] for (r, (name, _)) in enumerate(texts)],
                          false, false, nothing))
  else
    push!(p.tables, Table(i, t, under, over.table, true, true, nothing))
  end
  # The rows that have a name give it to the sheets under this one
  append!(p.given, (row for row in texts if !isempty(ident(row[1]))))
  for (r, (name, expr)) in enumerate(texts)
    results[r].failed && @warn "A row of a sheet in $(basename(p.path)) went wrong" row=name problem=results[r].text
  end
  rows = map(enumerate(texts)) do (r, (name, expr))
    result = results[r]
    "<tr><th>$(escape(strip(name)))</th><td><code>$(escape(strip(expr)))</code></td>" *
    "<td class=\"result$(result.failed ? " failed" : "")\">$(escape(result.text))</td></tr>"
  end
  "<div class=\"sheet\"><table>\n" * join(rows, "\n") * "\n</table></div>"
end

"The table that `name` names, as Ladder finds it: the first under a heading of that name, or the nth with a number after the name"
named_table(p::Page, name::AbstractString) = begin
  name = String(strip(name))
  isempty(name) && return nothing
  k = findfirst(t -> Charts.same(t.under, name), p.tables)
  k === nothing || return k
  m = match(r"^(.*\S)\s+(\d+)$", name)
  base, n = m === nothing ? (name, 1) : (String(m[1]), parse(Int, m[2]))
  ks = [k for (k, t) in enumerate(p.tables) if Charts.same(t.under, base)]
  1 <= n <= length(ks) ? ks[n] : nothing
end

"What the chart `c`, whose block is lines `s` to `t`, draws: its own rows, or a table of the page, or several"
chart_data(p::Page, c, s::Int, t::Int) = begin
  isempty(c.rows) || return Charts.data(c, c.rows)
  data(k; part=false) = (x = p.tables[k]; Charts.data(c, x.rows, headed=x.headed, by_first=x.ranged, part=part, values=x.values))
  k = isempty(c.from) ? something(findlast(x -> x.last < s, p.tables), findfirst(x -> x.first > t, p.tables), 0) :
                        something(named_table(p, c.from), 0)
  k == 0 || return data(k)
  names = Charts.listed(c.from)
  if length(names) > 1
    parts = map(names) do name
      k = named_table(p, name)
      k === nothing ? Charts.nothing_to_draw("This page has no table called “$(name)”.") : data(k, part=true)
    end
    return Charts.joined(c, parts, names)
  end
  Charts.nothing_to_draw(isempty(c.from) ? "This page has no table for the chart to draw." : "This page has no table called “$(c.from)”.")
end

# The colours of a chart's columns of numbers: those of the footnotes, which go with the paper
const SERIES = ["#a84a2b", "#386e68", "#8a6214", "#685892", "#4a6e37", "#a14760", "#3b6795", "#86663b"]
const WIDE = 760.0    # how wide a chart is when it has the whole column, in the units of its picture
const PLOT_H, PIE_H = 260.0, 220.0   # how tall bars and lines are, and a pie, as in Ladder

"""
About how wide `text` is at the size `size` in Literata, the site's font, which the words of a chart are in. It's a
little too wide, if anything, so that the words that a chart fits in a space aren't cut.
"""
measure(text, size) = size * sum(advance, text; init=0.0)
advance(c::Char) = c == ' ' ? 0.26 : c in ".,:;'’!|ilj·" ? 0.3 : isdigit(c) ? 0.58 : c in "MW%—@" ? 0.95 :
                   c in "mw" ? 0.84 : isuppercase(c) ? 0.72 : islowercase(c) ? 0.54 : 0.62

"The chart whose block opens on line `s`, as HTML: its title, and a picture of it. `part` is its share of the column's width."
chart_html(p::Page, s::Int, part::Real) = begin
  t = something(findnext(l -> l.kind == Kind.fence && l.level == 1, p.kinds, s + 1), length(p.lines) + 1)
  c = Charts.chart(p.lines[s+1:t-1])
  d = chart_data(p, c, s, t)
  if !isempty(d.problem)
    @warn "A chart of $(basename(p.path)) has nothing to draw" line=s problem=d.problem
    return ""
  end
  # Bars and lines get more room for the names of their axes, so the plot stays as tall
  tall = (c.kind == :pie ? PIE_H : PLOT_H) + Charts.axis_room(d, c.kind)
  # A phone shows a picture laid out for a narrow page, with its words as big as the wide one's
  pictures = [chart_svg(d, c.kind, max(WIDE * part, NARROW), tall, "wide"), chart_svg(d, c.kind, NARROW, tall, "narrow")]
  title = isempty(c.title) ? "" : "<figcaption>$(escape(c.title))</figcaption>\n"
  "<figure class=\"chart\">\n$title$(join(pictures, '\n'))\n</figure>"
end

const NARROW = 360.0   # how wide a chart is on a phone, in the units of its picture

"A picture in SVG of what a chart shows, `wide` by `tall`, with the class `class`, as wide as the space it's in"
chart_svg(d, kind, wide, tall, class) = begin
  marks = Charts.plot(d, kind, wide, tall, measure)
  svg = Charts.svg(marks, wide, tall, colours=SERIES, ink="#2b2620", dim="#6e6352", line="#ddd1b8", surface="#f5efe1",
                   family="Literata, Georgia, serif")
  replace(replace(svg, r" width=\"[\d.]+\"" => "", count=1), "<svg " => "<svg class=\"$class\" ", count=1)
end

# --- diagrams and views ------------------------------------------------------------------

"The lines of the block that opens on line `s`, without the lines that open and close it"
block_lines(p::Page, s::Int) = begin
  t = something(findnext(l -> l.kind == Kind.fence && l.level == 1, p.kinds, s + 1), length(p.lines) + 1)
  p.lines[s+1:t-1]
end

"The diagram of the `mermaid` block that opens on line `s`, for Mermaid to draw in the browser"
mermaid_html(p::Page, s::Int) = begin
  push!(p.scripts, :mermaid)
  "<div class=\"diagram\"><pre class=\"mermaid\">$(escape(join(block_lines(p, s), '\n')))</pre></div>"
end

const PICTURES = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".avif")

"""
The `view` block that opens on line `s`, as HTML. A view of a Julia file shows what its function `view` makes of the
page's sums. A view of a picture shows the picture, and a view of a web page shows the page. Anything else, like a
SolidCraft design, can't be shown on the site, so the block shows nothing. The file that the block names goes beside
the page as it is, at the same place from the page, so that Ladder, which reads the page's Markdown, shows it.
"""
view_html(p::Page, s::Int) = begin
  lines = filter(l -> !isempty(strip(l)), block_lines(p, s))
  isempty(lines) && return ""
  target = String(strip(lines[1]))
  aspects = filter(!isnothing, [match(r"^\s*aspect\s*:\s*(\d+(?:\.\d+)?)\s*[:/]\s*(\d+(?:\.\d+)?)\s*$", l) for l in lines[2:end]])
  aspect = isempty(aspects) ? nothing : aspects[1]
  shape = aspect === nothing ? "aspect-ratio: 16 / 9" : "aspect-ratio: $(aspect[1]) / $(aspect[2])"
  occursin(r"^https?://", target) && return "<iframe class=\"view\" src=\"$(escape(target))\" style=\"$shape\"></iframe>"
  file = joinpath(dirname(p.path), target)
  beside(target) && isfile(file) && (p.files[target] = read(file))
  if lowercase(splitext(target)[2]) in PICTURES && isfile(file)
    p.files[basename(file)] = read(file)
    return "<p><img src=\"$(escape(basename(file)))\" alt=\"\"></p>"
  end
  if endswith(target, ".jl") && isfile(file)
    made = try
      m = Kip.require(file)
      Base.invokelatest(isdefined, m, :view) ? Base.invokelatest(getglobal(m, :view), view_sums(p)) : nothing
    catch err
      @warn "The view of $target on line $s of $(basename(p.path)) went wrong" exception=err
      nothing
    end
    made isa Vector{UInt8} && isglb(made) && return model_html(p, splitext(basename(file))[1], made, shape)
  end
  @info "The view of $target on line $s of $(basename(p.path)) can't go on the web, so the page leaves it out"
  ""
end

"True when the name `target` of a view's file is in the page's folder, or a folder in it, so that it can go beside the page"
beside(target::AbstractString) = !isabspath(target) && !startswith(target, "~") && !any(==(".."), splitpath(target))

"True when `bytes` are a .glb file: a 3D model in the binary form of glTF"
isglb(bytes) = length(bytes) >= 20 && bytes[1:4] == codeunits("glTF")

"""
A model that the mouse turns, from the bytes of a .glb file, which go beside the page as `name`.glb. A picture of the
sky in the file, as satellite.jl puts one there, is the sky behind the model, and lights it.
"""
model_html(p::Page, name::AbstractString, bytes, shape) = begin
  push!(p.scripts, :model)
  p.files["$name.glb"] = bytes
  sky = glb_picture(bytes, "sky")
  sky === nothing || (p.files["$name-sky.jpg"] = sky)
  # It starts turned a little and seen from a little above, as a thing is easiest to make out
  "<model-viewer class=\"view\" src=\"$(escape(name)).glb\" camera-controls touch-action=\"pan-y\" interaction-prompt=\"none\"" *
  " camera-orbit=\"35deg 65deg 85%\"" *
  (sky === nothing ? "" : " skybox-image=\"$(escape(name))-sky.jpg\"") *
  " alt=\"A model of $(escape(name)) that turns as you drag it\" style=\"$shape\"></model-viewer>"
end

"The bytes of the picture called `name` in the .glb file `bytes`, or nothing"
glb_picture(bytes, name) = try
  json_size = Int(reinterpret(UInt32, bytes[13:16])[1])
  doc = parse(MIME("application/json"), String(bytes[21:20+json_size]))
  i = findfirst(im -> get(im, "name", "") == name, get(doc, "images", []))
  i === nothing && return nothing
  # JSON's numbers are read as floats
  v = doc["bufferViews"][Int(doc["images"][i]["bufferView"])+1]
  from = 20 + json_size + 8 + Int(get(v, "byteOffset", 0))   # after the header, the text and the head of the bytes
  bytes[from+1:from+Int(v["byteLength"])]
catch
  nothing
end

"The SI units that a view's function gets amounts in, as Ladder gives them, with the kilogram for mass"
const SI_UNITS = ((Units.Length, Units.m), (Units.Mass, Units.kg), (Units.Time, Units.s), (Units.Current, Units.A),
                  (Units.Temperature, Units.K))

"""
What a view's function gets for the value `x` of a sum, as Ladder gives it: a number, true or false, or words. An
amount is a number in SI units: 70m is 70, 150kW is 150000 and 98% is 0.98. Money is a number of its currency.
"""
script_value(x::Bool) = x
script_value(x::AbstractString) = String(x)
script_value(x::Real) = Float64(x)
script_value(x::Units.Unit) = try
  bits, _ = Units.flatten_units(typeof(x))
  i = findfirst(u -> Units.unwrap(u) <: Cash.Money, bits)
  i === nothing || (x = x / Units.unwrap(bits[i])(1))
  x isa Units.Unit || return Float64(x)
  si = nothing
  for d in Units.dimensions(typeof(x))
    D = Units.unwrap(d)
    D <: Units.NullDimension && continue
    j = findfirst(((kind, _),) -> D <: kind, SI_UNITS)
    j === nothing && return nothing
    u = SI_UNITS[j][2]^Units.power(d)
    si = si === nothing ? u : si * u
  end
  si === nothing ? convert(Float64, x) : Float64(convert(si, x).value)
catch
  nothing
end
script_value(x) = nothing

"The sums of the page that give a name, as a view's function gets them: each name with its value in SI units"
view_sums(p::Page) = Dict{String,Any}(name => v for (name, v) in ((n, script_value(x)) for (n, x) in p.named) if v !== nothing)

# --- columns -----------------------------------------------------------------------------

"A line that holds only a picture or a formula, which is a block of its own in a column"
alone(p::Page, i::Int) = p.kinds[i].kind == Kind.paragraph &&
  (occursin(r"^\s*!\[[^\]]*\]\([^)]*\)\s*$", p.lines[i]) || occursin(r"^\s*\$\$.*\$\$\s*$", p.lines[i]))

"""
The lines that show side by side, for Ladder's `html`: for each group of columns, the first and last line of each
column and its share of the width. A column whose block shows nothing on the site is left out, and so is a group with
one column left.
"""
columns(p::Page) = begin
  groups = Columns.groups(p.lines, p.kinds, alone=i -> alone(p, i))
  out = []
  for g in groups
    isempty(g.spans) && continue
    cols = map(eachindex(g.shares)) do k
      k <= length(g.spans) || return (last(g.spans[end]) + 1, last(g.spans[end]), g.shares[k])
      (first(Columns.reach(g, k)), last(Columns.reach(g, k)), g.shares[k])
    end
    filter!(((from, to, _),) -> !empty_column(p, from, to), cols)
    length(cols) > 1 && push!(out, cols)
  end
  out
end

"True when the column of lines `from` to `to` shows nothing: it's a block that shows nothing, and empty lines"
empty_column(p::Page, from::Int, to::Int) =
  get(p.blocks, from, nothing) == "" && all(i -> isempty(strip(p.lines[i])), block_end(p, from)+1:to)

"The line that closes the block that opens on line `s`, or `s` for a line that opens no block"
block_end(p::Page, s::Int) = p.kinds[s].kind == Kind.fence && p.kinds[s].level == 0 ?
  something(findnext(l -> l.kind == Kind.fence && l.level == 1, p.kinds, s + 1), length(p.lines)) : s

"The share of the page's width that line `i` has: its column's share, or all of it"
share(cols, i::Int) = begin
  for group in cols, (from, to, part) in group
    from <= i <= to && return part / sum(c -> c[3], group)
  end
  1.0
end

# --- the page round it -------------------------------------------------------------------

"""
What the front matter of the page says, as canon's other pages have it: YAML between lines of ---, or TOML between
lines of +++. A page's `about` is its description, which the list of its folder shows.
"""
meta(lines) = begin
  t = front_matter(lines)
  out = Dict{String,Any}()
  t > 0 || return out
  if strip(lines[1]) == "+++"
    merge!(out, TOML.parse(join(lines[2:t-1], '\n')))
  else
    for l in lines[2:t-1]
      m = match(r"^([\w\-]+)\s*:\s*(.*?)\s*$", l)
      m === nothing || (out[m[1]] = strip(m[2], ['"', '\'']))
    end
  end
  haskey(out, "about") && !haskey(out, "description") && (out["description"] = out["about"])
  out
end

"""
`body` with its footnotes as the site's other pages have them, for the site's script to put in the margin: each
number links to its note, and each note is a block of its own at the end of the text
"""
sidenotes(body::AbstractString) = begin
  body = replace(body, r"<sup><a href=\"#fn-([^\"]+)\" id=\"fnref-([^\"]+)\">([^<]*)</a></sup>" =>
                       s"<a href=\"#fn-\1\" id=\"fnref-\2\" class=\"footnote-ref\"><sup>\3</sup></a>")
  replace(body, r"<section class=\"footnotes\">\n<ol>\n(.*?)</ol>\n</section>\n?"s => section -> begin
    notes = match(r"<section class=\"footnotes\">\n<ol>\n(.*?)</ol>"s, section)[1]
    replace(notes, r"<li id=\"fn-([^\"]+)\" value=\"\d+\">(.*) <a href=\"#fnref-[^\"]+\">↩</a></li>" =>
                   s"<div class=\"footnote-def\" id=\"fn-\1\"><p>\2</p></div>")
  end)
end

const MERMAID = raw"""
<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"
mermaid.initialize({ startOnLoad: false, theme: "base", themeVariables: {
  background: "#f5efe1", primaryColor: "#faf6ec", primaryBorderColor: "#c4b391", primaryTextColor: "#2b2620",
  secondaryColor: "#ece3cf", tertiaryColor: "#ece3cf", lineColor: "#6e6352", textColor: "#2b2620",
  edgeLabelBackground: "#f5efe1", fontFamily: "Literata, Georgia, serif", fontSize: "15px" } })
await document.fonts.ready
await mermaid.run({ querySelector: "pre.mermaid" })
// A wide diagram scrolls sideways, so that its words are never less than about two thirds of their size
document.querySelectorAll("pre.mermaid").forEach(pre => {
  const svg = pre.querySelector("svg")
  if (svg && svg.viewBox.baseVal) svg.style.minWidth = Math.round(0.65 * svg.viewBox.baseVal.width) + "px"
  pre.classList.add("drawn")
})
// The diagrams change how tall the page is, so the notes in the margin find their lines again
dispatchEvent(new Event("resize"))
</script>
"""

const MODEL_VIEWER = raw"""
<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer@4/dist/model-viewer.min.js"></script>
<script>
// The wheel scrolls the page past a model. A pinch, or the wheel with ⌘ held, brings the model nearer, as in Ladder.
addEventListener("wheel", e => {
  if (!e.ctrlKey && !e.metaKey && e.target.closest && e.target.closest("model-viewer")) e.stopPropagation()
}, { capture: true, passive: true })
</script>
"""

"`body` with the scripts that the page needs at its end"
scripts(p::Page, body::AbstractString) = string(body, :mermaid in p.scripts ? MERMAID : "", :model in p.scripts ? MODEL_VIEWER : "")

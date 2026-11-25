@use "github.com/jkroso/DOM.jl" => DOM @dom
@use "github.com/jkroso/URI.jl" ["FSPath" FSPath] ["FS" File]
@use "./compile" compiled_type todocument describe pagetitle pagelink ownpage iscomplete rawdescription urlpath getignores shouldignore html outpath
@use "./load" Compilable BookReview inline_md
@use Dates: DateTime, unix2datetime, format, @dateformat_str

"""
A site's feed, as a Julia file at the top of the site gives it: `SiteFeed(title, link, description)`, where `link` is
the site's address. canon fills it with each page that a folder's list shows, apart from drafts, newest first. Each
page is dated by the first commit that has it on the site and not as a draft (see `published`)
"""
struct SiteFeed
  title::String
  link::String
  description::String
end

struct RSSItem
  title::String
  link::String
  description::String
  pubDate::DateTime # in UTC
end

struct RSSChannel
  title::String
  link::String
  description::String
  self::String # the address of the feed itself
  items::Vector{RSSItem}
end

compiled_type(::SiteFeed) = MIME("application/rss+xml")
compiled_type(::RSSChannel) = MIME("application/rss+xml")
describe(::Union{SiteFeed,RSSChannel}) = "An RSS Feed. Right click and copy the URL into your feed reader"
todocument(_, rss::RSSChannel) = rss

todocument(io::IO, file, feed::SiteFeed) = begin
  site = rstrip(feed.link, '/')
  root = something(get(io, :root, nothing), Compilable(io[:basedir]))
  git = ingit(root.source.path)
  items = [RSSItem(itemtitle(entry), string(site, '/', urlpath(path)), summary(entry), published(entry, git))
           for (path, entry) in listedpages(root) if ispage(entry)]
  sort!(items, by=item->item.pubDate, rev=true)
  self = string(site, '/', urlpath(string(outpath(io, file, MIME("application/rss+xml")))))
  RSSChannel(feed.title, site, feed.description, self, items)
end

"""
Each entry that the list of a folder shows, from the folder `c` down, as its page's path from the top of the site =>
the entry. A folder with its own page, like an index.md, is that page, as the folder has no list
"""
function listedpages(c::Compilable, at::String="")
  page = ownpage(c.dependencies)
  isnothing(page) || return [at => page]
  ignores = getignores(c.source.path)
  pages = Pair{String,Compilable}[]
  for (path, entry) in c.dependencies
    shouldignore(path, ignores) && continue
    if isdir(entry.source)
      append!(pages, listedpages(entry, string(at, path.name, '/')))
    else
      push!(pages, string(at, pagelink(path, entry)) => entry)
    end
  end
  pages
end

"True when `c` is a finished web page, not a draft, a picture or a file that goes out as it is"
ispage(c::Compilable) = invokelatest(compiled_type, c.source, c.value) == MIME("text/html") && iscomplete(c)

"The title of the page that `c` makes"
itemtitle(c::Compilable) = itemtitle(c.source, c.value)
itemtitle(file, value) = replace(pagetitle(file, value), r"\.dom$" => "") # a page drawn by Julia is named like name.dom.jl
itemtitle(::File, review::BookReview) = review.title
itemtitle(file::File{:html}, bytes::Vector{UInt8}) = begin
  m = match(r"<title[^>]*>\s*(.*?)\s*</title>"is, String(copy(bytes)))
  isnothing(m) ? pagetitle(file) : plaintext(m[1])
end

"""
What a feed reader shows of the page that `c` makes, as plain text: its description, or else the first paragraph of
its text, cut to about 400 characters
"""
summary(c::Compilable) = begin
  description = rawdescription(c)
  text = isempty(description) ? firstparagraph(pagehtml(c.value)) : plaintext(sprint(show, MIME("text/html"), inline_md(description)))
  shorten(text, 400)
end

pagehtml(bytes::Vector{UInt8}) = String(copy(bytes))
pagehtml(value) = sprint(show, MIME("text/html"), invokelatest(html, value))

"The first paragraph of a page that has three words or more, as a line like \"Greeks\" is a label, not the start of the text"
firstparagraph(page::AbstractString) = begin
  for m in eachmatch(r"<p\b[^>]*>(.*?)</p>"s, page)
    text = plaintext(m[1])
    count(' ', text) >= 2 && return text
  end
  ""
end

"The text of some HTML, without its tags or the marks that call its footnotes"
plaintext(html::AbstractString) = begin
  html = replace(html, r"<a\b[^>]*\bclass=\"footnote-ref\"[^>]*>.*?</a>"s => "")
  text = replace(html, r"<[^>]*>" => "")
  text = replace(text, "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'", "&nbsp;" => " ", "&amp;" => "&")
  String(strip(replace(text, r"\s+" => " ")))
end

shorten(text::AbstractString, n::Integer) = begin
  length(text) <= n && return text
  cut = first(text, n)
  i = findlast(' ', cut)
  string(rstrip(isnothing(i) ? cut : cut[1:prevind(cut, i)], [',', ';', ':', '.', ' ']), '…')
end

"""
When `c` went on the site: the time of the first commit that has its file outside any hidden folder and not as a
draft, following the file through renames. Before a commit has it like that, as with a new essay, it's when the file
was last saved. The times a file keeps, like its creation time, change when a file is copied, moved or checked out,
which would date an old page as new
"""
published(c::Compilable, git::Bool) = something(git ? firstcommit(c.source.path) : nothing, unix2datetime(c.mtime))

"True when the folder `dir` is in a git repository"
ingit(dir::FSPath) = success(pipeline(`git -C $(string(dir)) rev-parse --git-dir`, stdout=devnull, stderr=devnull))

# git runs in the file's own folder, as the path of the repository can differ from the file's path by a symlink, like
# /private/var and /var on a Mac. The paths that git gives are from the top of the repository, as `git show` takes them
firstcommit(path::FSPath) = begin
  dir = string(path.parent)
  log = read(`git -C $dir -c core.quotePath=false log --follow --format=%x00%H%x09%at --name-only -- $(path.name)`, String)
  for commit in reverse(split(log, '\0', keepempty=false)) # oldest first
    lines = split(strip(commit), '\n', keepempty=false)
    length(lines) < 2 && continue # a merge
    hash, time = split(lines[1], '\t')
    file = strip(lines[end])
    any(startswith('.'), split(file, '/')) && continue # in a hidden folder
    isdraft(read(`git -C $dir show $hash:$file`, String)) && continue
    return unix2datetime(parse(Int, time))
  end
  nothing
end

"True when the Markdown `text` has front matter that says `complete = false`"
isdraft(text::AbstractString) = begin
  m = match(r"\A\s*\+\+\+[^\n]*\n(.*?)\n\+\+\+"s, text)
  !isnothing(m) && occursin(r"^\s*complete\s*=\s*false\s*$"m, m[1])
end

"A time as RSS writes it (RFC 822), like Wed, 25 Nov 2026 04:21:18 GMT"
rfc822(t::DateTime) = format(t, dateformat"e, dd u yyyy HH:MM:SS") * " GMT"

xml(item::RSSItem) = @dom[:item
  [:title item.title]
  [:link item.link]
  [:guid isPermaLink="true" item.link]
  [:description item.description]
  [:pubDate rfc822(item.pubDate)]]

xml(channel::RSSChannel) = begin
  self = DOM.Container{Symbol("atom:link")}(Dict{Symbol,Any}(:href => channel.self, :rel => "self", :type => "application/rss+xml"), [])
  # the time of the newest page, not of the build, so that the feed only changes when a page is added
  built = isempty(channel.items) ? [] : [@dom[:lastBuildDate rfc822(first(channel.items).pubDate)]]
  @dom[:channel
    [:title channel.title]
    [:link channel.link]
    [:description channel.description]
    self
    built...
    map(xml, channel.items)...]
end

Base.show(io::IO, ::MIME"application/rss+xml", channel::RSSChannel) = begin
  write(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">")
  show(io, MIME("application/xml"), xml(channel))
  write(io, "</rss>\n")
end

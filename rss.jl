@use "github.com/jkroso/DOM.jl" @dom
@use "./compile" compiled_type todocument describe
@use TimeZones...
@use Dates...

struct RSSItem
  title::String
  link::String
  description::String
  pubDate::ZonedDateTime
end

struct RSSChannel
  title::String
  link::String
  description::String
  items::Vector{RSSItem}
end

function xml(item::RSSItem)
  @dom[:item
    [:title item.title]
    [:link item.link]
    [:description item.description]
    [:pubDate Dates.format(item.pubDate, dateformat"e, dd u yyyy H:M:S zzzz")]]
end

function xml(channel::RSSChannel)
  @dom[:channel
    [:title channel.title]
    [:link channel.link]
    [:description channel.description]
    map(xml, channel.items)...]
end

Base.show(io::IO, ::MIME"application/rss+xml", channel::RSSChannel) = begin
  write(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\">")
  show(io, MIME("application/xml"), xml(channel))
  write(io, "</rss>")
end

compiled_type(::RSSChannel) = MIME("application/rss+xml")
todocument(_, rss::RSSChannel) = rss
describe(::RSSChannel) = "An RSS Feed. Right click and copy the URL into your feed reader"

#!/usr/bin/env ruby
# frozen_string_literal: true

# Downloads an OPML file, fetches every feed in it, rejects feeds that
# fail to download or whose most recent item is older than 2 years,
# then writes a cleaned OPML to output.opml.
#
# Usage: ruby filter_opml.rb <opml_url>

require "net/http"
require "uri"
require "rexml/document"
require "rss"
require "time"
require "fileutils"

FETCH_TIMEOUT = 15
MAX_REDIRECTS = 5
USER_AGENT = "PlanetRuby/1.0 (+https://planetruby.org)"
TWO_YEARS = 2 * 365.25 * 86_400
OUTPUT_FILE = File.join(__dir__, "feeds.opml")

def fetch_url(url, redirect_limit = MAX_REDIRECTS)
  raise "Too many redirects" if redirect_limit.zero?

  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = FETCH_TIMEOUT
  http.read_timeout = FETCH_TIMEOUT

  request = Net::HTTP::Get.new(uri.request_uri)
  request["User-Agent"] = USER_AGENT

  response = http.request(request)

  case response
  when Net::HTTPSuccess
    response.body
  when Net::HTTPRedirection
    location = response["location"]
    location = URI.join(url, location).to_s unless location.start_with?("http")
    fetch_url(location, redirect_limit - 1)
  else
    raise "HTTP #{response.code}: #{response.message}"
  end
end

def most_recent_date(feed)
  dates = feed.items.filter_map do |item|
    date = if item.respond_to?(:pubDate) && item.pubDate
             item.pubDate
           elsif item.respond_to?(:date) && item.date
             item.date
           elsif item.respond_to?(:updated) && item.updated
             u = item.updated
             u.respond_to?(:content) ? u.content : u
           elsif item.respond_to?(:published) && item.published
             p = item.published
             p.respond_to?(:content) ? p.content : p
           end

    next unless date

    date.is_a?(Time) ? date : Time.parse(date.to_s)
  rescue
    nil
  end

  dates.max
end

def extract_feeds(opml_xml)
  doc = REXML::Document.new(opml_xml)
  feeds = []

  doc.elements.each("//outline") do |outline|
    xml_url = outline.attributes["xmlUrl"]
    next unless xml_url && !xml_url.strip.empty?

    feeds << {
      title: outline.attributes["title"] || outline.attributes["text"] || "",
      xml_url: xml_url.strip,
      html_url: (outline.attributes["htmlUrl"] || "").strip,
      type: (outline.attributes["type"] || "rss").strip
    }
  end

  feeds
end

def build_opml(feeds)
  doc = REXML::Document.new
  doc << REXML::XMLDecl.new("1.0", "UTF-8")

  opml = doc.add_element("opml", "version" => "2.0")
  head = opml.add_element("head")
  head.add_element("title").text = "Planet Ruby - Filtered Feeds"
  head.add_element("dateCreated").text = Time.now.utc.strftime("%a, %d %b %Y %H:%M:%S GMT")

  body = opml.add_element("body")

  feeds.each do |feed|
    attrs = {
      "type" => feed[:type],
      "text" => feed[:title],
      "title" => feed[:title],
      "xmlUrl" => feed[:xml_url]
    }
    attrs["htmlUrl"] = feed[:html_url] unless feed[:html_url].empty?
    body.add_element("outline", attrs)
  end

  output = String.new
  formatter = REXML::Formatters::Pretty.new(2)
  formatter.compact = true
  formatter.write(doc, output)
  output
end

# --- Main ---

url = ARGV[0]
unless url
  warn "Usage: ruby filter_opml.rb <opml_url>"
  exit 1
end

puts "Downloading OPML from #{url}..."
opml_xml = fetch_url(url)

feeds = extract_feeds(opml_xml)
puts "Found #{feeds.length} feeds in OPML\n\n"

cutoff = Time.now.utc - TWO_YEARS
kept = []
skipped = 0

feeds.each do |feed|
  print "  #{feed[:title]}... "

  begin
    xml = fetch_url(feed[:xml_url])
    parsed = RSS::Parser.parse(xml, false)

    unless parsed
      puts "SKIP (unparseable)"
      skipped += 1
      next
    end

    latest = most_recent_date(parsed)

    if latest.nil?
      puts "SKIP (no dates found)"
      skipped += 1
    elsif latest < cutoff
      puts "SKIP (last post #{latest.strftime('%Y-%m-%d')})"
      skipped += 1
    else
      puts "OK (last post #{latest.strftime('%Y-%m-%d')})"
      kept << feed
    end
  rescue => e
    puts "SKIP (#{e.message})"
    skipped += 1
  end
end

File.write(OUTPUT_FILE, build_opml(kept))

puts
puts "Done. Kept #{kept.length} feeds, skipped #{skipped}."
puts "Written to #{OUTPUT_FILE}"

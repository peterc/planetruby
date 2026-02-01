#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "uri"
require "rss"
require "json"
require "fileutils"
require "time"
require "rexml/document"

OPML_FILE    = File.join(__dir__, "feeds.opml")
DATA_DIR     = File.join(__dir__, "data")
OUTPUT_FILE  = File.join(DATA_DIR, "items.json")
ETAG_FILE    = File.join(DATA_DIR, "etags.json")

FETCH_TIMEOUT = 15 # seconds
MAX_REDIRECTS = 5
USER_AGENT = "PlanetRuby/1.0"
EXCERPT_LENGTH = 1000
MAX_AGE_DAYS = 30

def fetch_url(url, headers: {}, redirect_limit: MAX_REDIRECTS)
  raise "Too many redirects" if redirect_limit == 0

  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = FETCH_TIMEOUT
  http.read_timeout = FETCH_TIMEOUT

  request = Net::HTTP::Get.new(uri.request_uri)
  request["User-Agent"] = USER_AGENT
  headers.each { |k, v| request[k] = v }

  response = http.request(request)

  case response
  when Net::HTTPNotModified
    nil
  when Net::HTTPSuccess
    response
  when Net::HTTPRedirection
    location = response["location"]
    location = URI.join(url, location).to_s unless location.start_with?("http")
    fetch_url(location, headers: headers, redirect_limit: redirect_limit - 1)
  else
    raise "HTTP #{response.code}: #{response.message}"
  end
end

def strip_html(html)
  return "" if html.nil? || html.empty?
  text = html.gsub(/<[^>]+>/, " ")
  text = text.gsub(/&[a-zA-Z]+;/, " ")
  text = text.gsub(/&#?\w+;/, " ")
  text.gsub(/\s+/, " ").strip
end

def excerpt(text, length = EXCERPT_LENGTH)
  return "" if text.nil? || text.empty?
  clean = strip_html(text)
  return clean if clean.length <= length
  truncated = clean[0, length]
  # Try to break at a word boundary
  last_space = truncated.rindex(" ")
  truncated = truncated[0, last_space] if last_space && last_space > length * 0.6
  "#{truncated}..."
end

def feed_site_url(feed)
  candidates = []

  # Atom feeds: look for rel="alternate" link, then others
  if feed.respond_to?(:links) && feed.links&.any?
    alt = feed.links.find { |l| l.rel == "alternate" }
    candidates << alt.href.to_s.strip if alt&.respond_to?(:href)
    feed.links.each do |l|
      candidates << l.href.to_s.strip if l.respond_to?(:href)
    end
  end

  # RSS feeds: channel-level <link>
  if feed.respond_to?(:channel) && feed.channel&.respond_to?(:link)
    candidates << feed.channel.link.to_s.strip
  end

  if feed.respond_to?(:link) && feed.link
    l = feed.link
    candidates << (l.respond_to?(:href) ? l.href : l).to_s.strip
  end

  # Pick the first candidate that looks like a real web page, not a feed
  candidates
    .reject(&:empty?)
    .reject { |u| u.match?(/\.(xml|rss|atom|json|rdf)(\?|$)/i) }
    .reject { |u| u.match?(%r{/(feed|atom|rss)(/|$)}i) }
    .reject { |u| u == "/" }
    .reject { |u| u.match?(%r{^https?://(localhost|0\.0\.0\.0|127\.0\.0\.1)}i) }
    .first || ""
end

def parse_feed(xml, source_name, feed_url, cutoff:)
  feed = RSS::Parser.parse(xml, false)
  return [] unless feed

  source_url = feed_site_url(feed)
  items = []

  feed.items.each do |item|
    title = item.title.to_s.strip
    title = title.content if title.respond_to?(:content)
    title = strip_html(title.to_s).strip
    next if title.empty?

    link = if item.respond_to?(:link) && item.link
             l = item.link
             l.respond_to?(:href) ? l.href : l.to_s
           elsif item.respond_to?(:links) && item.links&.any?
             item.links.first.href.to_s
           else
             ""
           end
    link = link.strip
    next if link.empty?
    link = URI.join(feed_url, link).to_s unless link.start_with?("http")


    pub_date = if item.respond_to?(:pubDate) && item.pubDate
                 item.pubDate
               elsif item.respond_to?(:published) && item.published
                 item.published.respond_to?(:content) ? item.published.content : item.published
               elsif item.respond_to?(:date) && item.date
                 item.date
               elsif item.respond_to?(:updated) && item.updated
                 item.updated.respond_to?(:content) ? item.updated.content : item.updated
               end

    next unless pub_date
    pub_date = begin
      pub_date.is_a?(Time) ? pub_date : Time.parse(pub_date.to_s)
    rescue
      next
    end
    next if pub_date < cutoff

    description = if item.respond_to?(:description) && item.description
                    item.description.to_s
                  elsif item.respond_to?(:summary) && item.summary
                    s = item.summary
                    s.respond_to?(:content) ? s.content.to_s : s.to_s
                  elsif item.respond_to?(:content_encoded) && item.content_encoded
                    item.content_encoded.to_s
                  elsif item.respond_to?(:content) && item.content
                    c = item.content
                    c.respond_to?(:content) ? c.content.to_s : c.to_s
                  else
                    ""
                  end

    items << {
      title: title,
      url: link,
      published: pub_date.utc.iso8601,
      source: source_name,
      source_url: source_url,
      feed_url: feed_url,
      excerpt: excerpt(description)
    }
  end

  items
end

def parse_opml(path)
  doc = REXML::Document.new(File.read(path))
  feeds = []

  doc.elements.each("//outline") do |outline|
    xml_url = outline.attributes["xmlUrl"]
    next unless xml_url && !xml_url.strip.empty?

    feeds << {
      name: outline.attributes["title"] || outline.attributes["text"] || xml_url,
      url: xml_url.strip
    }
  end

  feeds
end

# --- Main ---

unless File.exist?(OPML_FILE)
  warn "No OPML file found at #{OPML_FILE}. Run filter_opml.rb first."
  exit 1
end

feeds = parse_opml(OPML_FILE)
cutoff = Time.now.utc - MAX_AGE_DAYS * 86_400

# Load existing items (if any) for merging
FileUtils.mkdir_p(DATA_DIR)
existing_items = if File.exist?(OUTPUT_FILE)
  JSON.parse(File.read(OUTPUT_FILE))
else
  []
end

# Drop expired items from existing data
existing_cutoff = cutoff.utc.iso8601
existing_items.reject! { |item| item["published"] < existing_cutoff }

# Index existing items by normalized URL for merging
existing_by_url = {}
existing_items.each do |item|
  key = item["url"].to_s.sub(/\/$/, "")
  existing_by_url[key] = item
end

THREAD_COUNT = 4

# Load etag/last-modified cache
etag_cache = if File.exist?(ETAG_FILE)
  JSON.parse(File.read(ETAG_FILE))
else
  {}
end

fresh_items = []
success_count = 0
not_modified_count = 0
error_count = 0
mutex = Mutex.new

queue = Queue.new
feeds.each { |feed| queue << feed }
THREAD_COUNT.times { queue << nil }

threads = THREAD_COUNT.times.map do
  Thread.new do
    thread_items = []

    while (feed = queue.pop)
      name = feed[:name]
      url = feed[:url]

      begin
        # Build conditional request headers
        conditional = {}
        if (cached = etag_cache[url])
          conditional["If-None-Match"] = cached["etag"] if cached["etag"]
          conditional["If-Modified-Since"] = cached["last_modified"] if cached["last_modified"]
        end

        response = fetch_url(url, headers: conditional)

        if response.nil?
          mutex.synchronize do
            not_modified_count += 1
            puts "#{name}: not modified"
          end
          next
        end

        # Store response headers for next time
        mutex.synchronize do
          etag_cache[url] = {
            "etag" => response["etag"],
            "last_modified" => response["last-modified"]
          }.compact
        end

        items = parse_feed(response.body, name, url, cutoff: cutoff)
        thread_items.concat(items)
        mutex.synchronize do
          success_count += 1
          puts "#{name}: #{items.length} items"
        end
      rescue => e
        mutex.synchronize do
          error_count += 1
          puts "#{name}: ERROR: #{e.message}"
        end
      end
    end

    thread_items
  end
end

threads.each { |t| fresh_items.concat(t.value) }

# Save etag cache
File.write(ETAG_FILE, JSON.pretty_generate(etag_cache))

# Merge: fresh items update existing ones by URL, new URLs get added.
# Existing items not re-fetched are kept (feed might be slow/down).
fresh_items.each do |item|
  key = item[:url].sub(/\/$/, "")
  existing = existing_by_url[key]

  if existing
    # Update crawl-sourced fields but preserve AI filtering work
    existing["title"] = item[:title] unless existing["ai_filtered"]
    existing["excerpt"] = item[:excerpt] unless existing["ai_filtered"]
    existing["published"] = item[:published]
    existing["source"] = item[:source]
    existing["source_url"] = item[:source_url]
    existing["feed_url"] = item[:feed_url]
  else
    existing_by_url[key] = {
      "title" => item[:title],
      "url" => item[:url],
      "published" => item[:published],
      "source" => item[:source],
      "source_url" => item[:source_url],
      "feed_url" => item[:feed_url],
      "excerpt" => item[:excerpt]
    }
  end
end

# Collect, sort by date descending
merged = existing_by_url.values
merged.sort_by! { |item| item["published"] }.reverse!

File.write(OUTPUT_FILE, JSON.pretty_generate(merged))

new_count = merged.length - existing_items.length
puts
puts "Done. #{merged.length} items (#{new_count >= 0 ? "+#{new_count}" : new_count} new) from #{success_count} feeds (#{not_modified_count} unchanged, #{error_count} errors)."
puts "Written to #{OUTPUT_FILE}"

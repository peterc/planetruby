#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "time"

DATA_FILE = File.join(__dir__, "data", "items.json")

OPENROUTER_API_KEY = ENV.fetch("OPENROUTER_API_KEY") {
  abort "OPENROUTER_API_KEY environment variable is not set."
}

OPENROUTER_URL = URI("https://openrouter.ai/api/v1/chat/completions")
MODEL = "x-ai/grok-code-fast-1"

SYSTEM_PROMPT = <<~PROMPT
  You are a content filter for a Ruby and Rails news aggregator called Planet Ruby.

  Given an item's source, title, and excerpt, you must decide:
  1. Is this item related to Ruby, Rails, or their ecosystem in any meaningful way?
  2. Clean up the title:
    * strip site names author names, junk prefixes/suffixes, emoji
    * Keep the title as intact as possible otherwise. Do not editorialize.
    * Title casing preferred.
  3. Clean up the excerpt
     * If the item clearly has a specific 'format' we need to stress this - like if it's a newsletter, a video, a security announcement, etc.
     * fix grammar and very obvious typos, but leave technical terms alone
     * remove leading repetition of the title, if any
     * remove trailing "Continue Reading" or similar junk
     * remove leading dates
     * keep the meaning and tone intact, and try to maintain the author's voice where possible (we don't want to sound too generic)
     * If the excerpt is empty, return an empty string.
     * The result needs to be a single paragraph of thirty to fifty words max ideally.
     * Use Markdown where appropriate for tiny bits of code or italics/bold if the author used or implied them.
     * Remove URLs or links from the content.
     * Don't put words into the author's mouth, like "I did X" etc. since we are summarizing, we need to be more neutral and like a curator.
     * You don't need to start "The author" or "The post" - people know there are posts by authors. Instead of "The author discusses using X to do Y" you can just say "A look into using X to do Y" or similar.
     * If the article has a tagline or subtitle of its own, lean on it heavily as it's already a good descriptor.
     * No em dashes, en dashes, or typical AI slop cliches.
     * Just call "Ruby on Rails" "Rails" instead. Every Rubyist calls it Rails.
  4. Give us a score out of 10 on how timely or urgent the item is.
     * Major Ruby or Rails releases are higher scoring.
     * Major security announcements are higher scoring.
     * Very generic tutorials are lower scoring (e.g. "How to install Ruby" or "How arrays work")

  Special rules for certain sources:
  * If the source is Ruby Weekly or any other newsletter ("Weekly" is a bit hint but also the URL might say newsletter or similar), always keep it, but you need to mention it's a newsletter in the excerpt rather than give the impression it's a single piece of content.
  * The official Ruby blog and RubyGems/Bundler blog should be kept always, scored higher and you need to say in the excerpt that they are official.
  * The Rails blog often runs a 'this week in Rails' summary post, you need to mention this rather than solely focus on the top most item in the excerpt.

  Return ONLY a JSON object with these fields:
  - "relevant": boolean -- true if the item is related to Ruby or Rails
  - "title": string -- the cleaned title
  - "excerpt": string -- the cleaned excerpt
  - "score": number -- an integer from 1 to 10
PROMPT

def call_openrouter(source, title, excerpt)
  user_message = <<~MSG
    Source: #{source}
    Title: #{title}
    Excerpt: #{excerpt}
  MSG

  body = {
    model: MODEL,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: user_message }
    ],
    temperature: 0.2
  }.to_json

  http = Net::HTTP.new(OPENROUTER_URL.host, OPENROUTER_URL.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 30

  request = Net::HTTP::Post.new(OPENROUTER_URL)
  request["Content-Type"] = "application/json"
  request["Authorization"] = "Bearer #{OPENROUTER_API_KEY}"
  request.body = body

  response = http.request(request)

  unless response.is_a?(Net::HTTPSuccess)
    raise "OpenRouter API error: #{response.code} #{response.body}"
  end

  data = JSON.parse(response.body)
  content = data.dig("choices", 0, "message", "content")
  JSON.parse(content)
end

# --- Main ---

unless File.exist?(DATA_FILE)
  abort "No data file found at #{DATA_FILE}. Run fetch.rb first."
end

items = JSON.parse(File.read(DATA_FILE))
cutoff = (Time.now.utc - 30 * 86_400).iso8601

# Discard items older than 30 days
original_count = items.length
items.reject! { |item| item["published"] < cutoff }
if items.length < original_count
  puts "Dropped #{original_count - items.length} items older than 30 days"
  File.write(DATA_FILE, JSON.pretty_generate(items))
end

THREAD_COUNT = 5
FORCE = ARGV.include?("--force")

if FORCE
  puts "Force mode: reprocessing all items"
  items.each { |item| item.delete("ai_filtered"); item.delete("score"); item.delete("relevant") }
end

to_process = items.reject { |item| item["ai_filtered"] }
puts "#{items.length} items total, #{to_process.length} to process"

mutex = Mutex.new
processed = 0

queue = Queue.new
to_process.each { |item| queue << item }
THREAD_COUNT.times { queue << nil }

threads = THREAD_COUNT.times.map do
  Thread.new do
    while (item = queue.pop)
      source = item["source"] || ""
      title = item["title"] || ""
      excerpt = item["excerpt"] || ""

      num = mutex.synchronize { processed += 1 }
      prefix = "[#{num}/#{to_process.length}] #{source}: #{title[0, 60]}... "

      begin
        result = call_openrouter(source, title, excerpt)

        mutex.synchronize do
          if result["relevant"]
            item["title"] = result["title"] if result["title"] && !result["title"].empty?
            item["excerpt"] = result["excerpt"] if result["excerpt"]
            item["score"] = result["score"].to_i if result["score"]
            item["ai_filtered"] = true
            puts "#{prefix}KEEP (#{result["score"]}/10)"
          else
            item["ai_filtered"] = true
            item["relevant"] = false
            puts "#{prefix}REMOVE"
          end
          File.write(DATA_FILE, JSON.pretty_generate(items))
        end
      rescue => e
        mutex.synchronize do
          puts "#{prefix}ERROR: #{e.message}"
          item["ai_filtered"] = true
          File.write(DATA_FILE, JSON.pretty_generate(items))
        end
      end
    end
  end
end

threads.each(&:join)

kept = items.count { |i| i["ai_filtered"] }
puts "\nDone. #{kept} items kept after filtering."

#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "erb"
require "time"
require "cgi"
require "uri"
require "fileutils"

DATA_FILE    = File.join(__dir__, "data", "items.json")
TEMPLATE_DIR = File.join(__dir__, "templates")
OUTPUT_DIR   = File.join(__dir__, "output")
OUTPUT_FILE  = File.join(OUTPUT_DIR, "index.html")

def h(text)
  CGI.escapeHTML(text.to_s)
end

def inline_code(text)
  s = CGI.escapeHTML(text.to_s)
  s.gsub(/`([^`]+)`/, '<code>\1</code>')
end

def inline_markdown(text)
  s = CGI.escapeHTML(text.to_s)
  s = s.gsub(/`([^`]+)`/, '<code>\1</code>')
  s = s.gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
  s = s.gsub(/\b__(.+?)__\b/, '<strong>\1</strong>')
  s = s.gsub(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/, '<em>\1</em>')
  s = s.gsub(/(?<!_)_(?!_)(.+?)(?<!_)_(?!_)/, '<em>\1</em>')
  s
end

def domain_for(url)
  URI.parse(url).host.to_s
rescue
  ""
end


def relative_time(iso_string)
  time = Time.parse(iso_string)
  diff = Time.now.utc - time.utc
  seconds = diff.to_i.abs

  result = if seconds < 60
             "just now"
           elsif seconds < 3600
             n = seconds / 60
             "#{n}m ago"
           elsif seconds < 86_400
             n = seconds / 3600
             "#{n}h ago"
           elsif seconds < 86_400 * 30
             n = seconds / 86_400
             n == 1 ? "yesterday" : "#{n}d ago"
           elsif seconds < 86_400 * 365
             n = seconds / (86_400 * 30)
             n == 1 ? "1 month ago" : "#{n} months ago"
           else
             n = seconds / (86_400 * 365)
             n == 1 ? "1 year ago" : "#{n} years ago"
           end

  result
end

def quiet_day_message(date_sub)
  QUIET_DAY_MESSAGES[date_sub.hash.abs % QUIET_DAY_MESSAGES.length]
end

SPECIAL_DATES = {
  [2, 24] => "Ruby's Birthday",
  [4, 14] => "Matz's Birthday"
}

def date_label(iso_string)
  date = Time.parse(iso_string).utc.to_date
  today = Time.now.utc.to_date
  special = SPECIAL_DATES[[date.month, date.day]]

  label = if date == today
            "Today"
          elsif date == today - 1
            "Yesterday"
          elsif date >= today - 7
            date.strftime("%A")
          else
            date.strftime("%B %-d")
          end

  label = special if special
  sub = date >= today - 7 ? date.strftime("%B %-d") : date.strftime("%Y")

  [label, sub]
end

# --- Main ---

unless File.exist?(DATA_FILE)
  warn "No data file found at #{DATA_FILE}. Run fetch.rb first."
  exit 1
end

all_items = JSON.parse(File.read(DATA_FILE))

# Only include items from the last 30 days that weren't rejected by AI
cutoff = (Time.now.utc - 30 * 86_400).iso8601
items = all_items.select { |item| item["published"] >= cutoff && item["relevant"] != false }

QUIET_DAY_MESSAGES = [
  "Ruby land was quiet today.",
  "Nothing to report. Even Matz takes a day off.",
  "A quiet day in the Ruby community.",
  "No posts today. Everyone must be busy writing code.",
  "Tumbleweeds in Ruby land today.",
  "The gems were resting today.",
  "All quiet on the Ruby front.",
  "Nothing new today. Must be a refactoring day.",
]

# Group items by date, preserving order (already sorted by date desc)
items_by_date = items.each_with_object({}) do |item, h|
  date = Time.parse(item["published"]).utc.to_date
  (h[date] ||= []) << item
end

# Fill in every day from today back to the cutoff date
today = Time.now.utc.to_date
cutoff_date = (Time.now.utc - 30 * 86_400).to_date
grouped_items = (cutoff_date..today).to_a.reverse.filter_map do |date|
  day_items = items_by_date[date] || []
  next if date == today && day_items.empty? # more items may still appear today
  label = date_label(date.iso8601)
  [label, day_items]
end

template_path = File.join(TEMPLATE_DIR, "index.html.erb")
template = ERB.new(File.read(template_path), trim_mode: "-")
html = template.result(binding)

FileUtils.mkdir_p(OUTPUT_DIR)
File.write(OUTPUT_FILE, html)
File.write(File.join(OUTPUT_DIR, "CNAME"), "planetruby.org\n")

puts "Rendered #{items.length} items into #{OUTPUT_FILE}"

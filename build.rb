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

def date_label(iso_string)
  date = Time.parse(iso_string).utc.to_date
  today = Time.now.utc.to_date

  if date == today
    ["Today", date.strftime("%B %-d")]
  elsif date == today - 1
    ["Yesterday", date.strftime("%B %-d")]
  elsif date >= today - 7
    [date.strftime("%A"), date.strftime("%B %-d")]
  else
    [date.strftime("%B %-d"), date.strftime("%Y")]
  end
end

# --- Main ---

unless File.exist?(DATA_FILE)
  warn "No data file found at #{DATA_FILE}. Run fetch.rb first."
  exit 1
end

all_items = JSON.parse(File.read(DATA_FILE))

# Only include items from the last 30 days
cutoff = (Time.now.utc - 30 * 86_400).iso8601
items = all_items.select { |item| item["published"] >= cutoff }

# Group items by date label, preserving order (already sorted by date desc)
grouped_items = items.each_with_object([]) do |item, groups|
  label = date_label(item["published"])
  if groups.last && groups.last[0] == label
    groups.last[1] << item
  else
    groups << [label, [item]]
  end
end

template_path = File.join(TEMPLATE_DIR, "index.html.erb")
template = ERB.new(File.read(template_path), trim_mode: "-")
html = template.result(binding)

FileUtils.mkdir_p(OUTPUT_DIR)
File.write(OUTPUT_FILE, html)
File.write(File.join(OUTPUT_DIR, "CNAME"), "planetruby.org\n")

puts "Rendered #{items.length} items into #{OUTPUT_FILE}"

# Planet Ruby

An aggregator that pulls together the last 30 days of posts from across the Ruby community into a single page at [planetruby.org](https://planetruby.org).

Feeds are defined in `feeds.opml`. Every 30 minutes, a GitHub Actions workflow crawls the feeds, runs each item through an LLM to filter out non-Ruby content and clean up titles/excerpts, then builds a static HTML page and deploys it to GitHub Pages.

## How it works

**`fetch.rb`** crawls all feeds in `feeds.opml` using 4 concurrent threads. It merges new items with existing data in `data/items.json` rather than overwriting, so items survive if a feed is temporarily down. Supports HTTP 304 (Not Modified) via cached ETag/Last-Modified headers to reduce bandwidth. Items older than 30 days are discarded at crawl time and never stored.

**`ai_filter.rb`** sends each new item to an LLM via OpenRouter. The model decides whether the item is relevant to Ruby/Rails, cleans up the title and excerpt, and assigns a score from 1-10 based on timeliness. Irrelevant items are removed. Processing is resumable since items are saved after each one and marked with an `ai_filtered` flag.

**`build.rb`** reads the filtered items, groups them by date, and renders `templates/index.html.erb` into `output/index.html`. The template is a single self-contained HTML file with inline CSS.

## Running locally

Requires Ruby 3.x (standard library only, no gems).

```
ruby fetch.rb                  # crawl feeds
OPENROUTER_API_KEY=... ruby ai_filter.rb   # filter and clean items
ruby ai_filter.rb --force      # reprocess all items
ruby build.rb                  # render the site to output/
```

## Utility scripts

**`scripts/filter_opml.rb`** takes an OPML URL, fetches every feed in it, and removes feeds that are dead or haven't posted in 2+ years.

**`clean_opml.rb`** uses an LLM to clean up feed names in `feeds.opml`.

## Deployment

The GitHub Actions workflow (`.github/workflows/build.yml`) runs every 30 minutes. It caches `data/items.json` and `data/etags.json` between runs so the fetcher can merge incrementally and use conditional HTTP requests. The built site is deployed to GitHub Pages.

## License

MIT. See `LICENSE`.

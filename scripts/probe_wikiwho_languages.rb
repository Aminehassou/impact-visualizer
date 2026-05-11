# frozen_string_literal: true

# End-to-end probe: build a small Topic with 2 universal articles per
# language and run TimepointService#full_timepoint_build to verify the
# whole data-generation pipeline works for each WikiWho-supported language
# we have per-language words-per-token data for.
#
# Run with: bundle exec rails runner scripts/probe_wikiwho_languages.rb

require 'json'
require 'net/http'
require 'uri'

# Languages: every WikiWho-supported wiki we also have words-per-token data
# for, minus en (already heavily exercised). ja is included even though it
# already has a Wiki record, because full data-gen has never actually been
# attempted on it (Topic count for ja is zero in this DB).
TARGET_LANGS = (WikiWhoApi::AVAILABLE_WIKIPEDIAS - %w[en]).freeze

# Picked for near-universal sitelink coverage and moderate length.
# Triangle = Q11401 (geometry), Hydrogen = Q556 (chemistry).
ARTICLE_QIDS = %w[Q11401 Q556].freeze

# Date window short enough to keep per-language wall time low. With a
# 365-day interval, this yields ~2 timestamps per topic.
START_DATE = Date.new(2024, 1, 1)
END_DATE   = Date.new(2025, 1, 1)
INTERVAL   = 365

def fetch_sitelinks(qids)
  uri = URI('https://www.wikidata.org/w/api.php')
  uri.query = URI.encode_www_form(
    action: 'wbgetentities',
    ids: qids.join('|'),
    props: 'sitelinks',
    format: 'json'
  )
  res = Net::HTTP.get_response(uri)
  raise "Wikidata fetch failed: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  body = JSON.parse(res.body)
  qids.each_with_object({}) do |qid, h|
    sitelinks = body.dig('entities', qid, 'sitelinks') || {}
    h[qid] = sitelinks.transform_values { |sl| sl['title'] }
  end
end

def wiki_key_for(lang)
  "#{lang.tr('-', '_')}wiki"
end

puts "[probe] Targeting #{TARGET_LANGS.size} languages: #{TARGET_LANGS.join(', ')}"
puts "[probe] Resolving sitelinks for #{ARTICLE_QIDS.inspect} on Wikidata…"
sitelinks_by_qid = fetch_sitelinks(ARTICLE_QIDS)
ARTICLE_QIDS.each do |qid|
  covered = sitelinks_by_qid[qid].keys.size
  puts "[probe]   #{qid}: #{covered} sitelinks fetched"
end
puts

results = []
overall_start = Time.now

TARGET_LANGS.each_with_index do |lang, i|
  banner = "[#{format('%2d', i + 1)}/#{TARGET_LANGS.size}] #{lang}.wikipedia"
  print "#{banner}: "

  wiki_key = wiki_key_for(lang)
  titles = ARTICLE_QIDS.map { |qid| sitelinks_by_qid[qid][wiki_key] }

  if titles.any?(&:nil?)
    missing = ARTICLE_QIDS.zip(titles).select { |_q, t| t.nil? }.map(&:first)
    puts "SKIP — no sitelink for #{missing.join(',')}"
    results << { lang:, status: :skip, note: "missing sitelinks: #{missing.join(',')}" }
    next
  end

  topic = nil
  begin
    wiki = Wiki.find_or_create_by!(language: lang, project: 'wikipedia')
    # Set the Wikidata site code so ClassificationService can resolve claims
    # via local titles (rather than defaulting to enwiki, which would never
    # match a non-en title).
    wiki.update!(wikidata_site: "#{lang.tr('-', '_')}wiki") if wiki.wikidata_site.nil?

    suffix = Time.now.to_i
    topic = Topic.create!(
      name: "probe_#{lang}_#{suffix}",
      slug: "probe-#{lang}-#{suffix}",
      description: "Pipeline probe for #{lang}.wikipedia",
      wiki:,
      start_date: START_DATE,
      end_date: END_DATE,
      timepoint_day_interval: INTERVAL,
      display: false,
      convert_tokens_to_words: true
    )

    bag = ArticleBag.create!(topic:, name: "probe-bag-#{lang}-#{suffix}")
    titles.each do |t|
      article = Article.create!(title: t, wiki:)
      ArticleBagArticle.create!(article_bag: bag, article:)
    end

    started = Time.now
    TimepointService.new(topic:).full_timepoint_build
    elapsed = (Time.now - started).round(1)

    topic.reload
    tp_count = topic.topic_timepoints.count
    atp_total = topic.topic_timepoints.sum(:articles_count) || 0
    token_total = topic.topic_timepoints.sum(:token_count) || 0
    length_total = topic.topic_timepoints.sum(:length) || 0
    revisions_total = topic.topic_timepoints.sum(:revisions_count) || 0

    puts format(
      'OK %5.1fs  topic=#%d  tp=%d  arts=%d  rev=%d  tokens=%d  len=%d',
      elapsed, topic.id, tp_count, atp_total, revisions_total, token_total, length_total
    )

    results << {
      lang:, status: :ok, elapsed_s: elapsed, topic_id: topic.id,
      topic_timepoints: tp_count, articles_count_sum: atp_total,
      token_total:, length_total:, revisions_total:
    }
  rescue StandardError => e
    puts "FAIL — #{e.class}: #{e.message.lines.first&.strip}"
    results << {
      lang:, status: :fail, topic_id: topic&.id,
      error: "#{e.class}: #{e.message.lines.first&.strip}"
    }
  end
end

overall_elapsed = (Time.now - overall_start).round(1)

puts
puts '=' * 72
puts "SUMMARY  (total wall time: #{overall_elapsed}s)"
puts '=' * 72
counts = results.group_by { |r| r[:status] }.transform_values(&:size)
puts "OK: #{counts[:ok] || 0}    FAIL: #{counts[:fail] || 0}    SKIP: #{counts[:skip] || 0}    TOTAL: #{results.size}"
puts

results.sort_by { |r| [{ ok: 0, fail: 1, skip: 2 }[r[:status]], r[:lang]] }.each do |r|
  case r[:status]
  when :ok
    puts format(
      '  OK   %-5s  %5.1fs  topic=#%-5d  tp=%-2d  arts=%-3d  rev=%-4d  tokens=%-6d  len=%-7d',
      r[:lang], r[:elapsed_s], r[:topic_id], r[:topic_timepoints],
      r[:articles_count_sum], r[:revisions_total], r[:token_total], r[:length_total]
    )
  when :fail
    puts format('  FAIL %-5s  topic=#%-5s  %s', r[:lang], r[:topic_id] || '-', r[:error])
  when :skip
    puts format('  SKIP %-5s  %s', r[:lang], r[:note])
  end
end

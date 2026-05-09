# frozen_string_literal: true

require 'rails_helper'

describe TopicBuilderSyncService do
  let!(:wiki) { Wiki.find_or_create_by!(language: 'en', project: 'wikipedia') }
  let(:topic) do
    create(:topic, wiki:, tb_handle: 'tbp_old', tb_source_topic_id: 42).tap do |t|
      t.update!(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 6, 1))
    end
  end
  let(:bag) { topic.active_article_bag }
  let(:article_a) { Article.create!(title: 'Achievement gap', wiki:, pageid: 1) }
  let(:article_b) { Article.create!(title: 'Active learning', wiki:, pageid: 2) }

  before do
    create(:article_bag_article, article_bag: bag, article: article_a, centrality: 8)
    create(:article_bag_article, article_bag: bag, article: article_b, centrality: nil)
  end

  def package_with(articles, handle: 'tbp_new')
    {
      'handle' => handle,
      'schema_version' => 1,
      'source_topic_id' => 42,
      'config' => { 'wiki' => 'en' },
      'articles' => articles
    }
  end

  describe '.compute_diff' do
    it 'returns empty diff when bag and package match' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Active learning', 'centrality' => nil }
      ])
      diff = described_class.compute_diff(topic:, package:)
      expect(diff).to be_empty
    end

    it 'detects adds (titles in package not in bag)' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Active learning', 'centrality' => nil },
        { 'title' => 'Bloom\'s taxonomy', 'centrality' => 5 }
      ])
      diff = described_class.compute_diff(topic:, package:)
      expect(diff.adds.pluck('title')).to eq(['Bloom\'s taxonomy'])
      expect(diff.removes).to be_empty
      expect(diff.centrality_changes).to be_empty
    end

    it 'detects removes (titles in bag not in package)' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 }
      ])
      diff = described_class.compute_diff(topic:, package:)
      expect(diff.removes.map { |aba| aba.article.title }).to eq(['Active learning'])
      expect(diff.adds).to be_empty
      expect(diff.centrality_changes).to be_empty
    end

    it 'detects centrality changes' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 9 },
        { 'title' => 'Active learning', 'centrality' => 3 }
      ])
      diff = described_class.compute_diff(topic:, package:)
      expect(diff.centrality_changes.map { |c| [c.title, c.from, c.to] })
        .to contain_exactly(['Achievement gap', 8, 9], ['Active learning', nil, 3])
    end

    it 'ignores entries with empty titles in the package' do
      package = package_with([
        { 'title' => '', 'centrality' => 5 },
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Active learning', 'centrality' => nil }
      ])
      diff = described_class.compute_diff(topic:, package:)
      expect(diff).to be_empty
    end
  end

  describe '#sync!' do
    it 'adds new articles with their centrality' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Active learning', 'centrality' => nil },
        { 'title' => 'Bloom\'s taxonomy', 'centrality' => 5 }
      ])
      expect {
        described_class.new(topic:, package:).sync!
      }.to change { bag.reload.article_bag_articles.count }.from(2).to(3)
        .and change(Article, :count).by(1)

      added = bag.article_bag_articles.joins(:article)
        .find_by('articles.title' => 'Bloom\'s taxonomy')
      expect(added.centrality).to eq(5)
    end

    it 'updates centrality in place without creating new ABAs' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 9 },
        { 'title' => 'Active learning', 'centrality' => nil }
      ])
      expect {
        described_class.new(topic:, package:).sync!
      }.not_to(change { bag.reload.article_bag_articles.count })

      aba = bag.article_bag_articles.joins(:article)
        .find_by('articles.title' => 'Achievement gap')
      expect(aba.centrality).to eq(9)
    end

    it 'hard-deletes the ArticleBagArticle for removed articles' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 }
      ])
      expect {
        described_class.new(topic:, package:).sync!
      }.to change { bag.reload.article_bag_articles.count }.from(2).to(1)

      remaining_titles = bag.article_bag_articles.includes(:article).map { |a| a.article.title }
      expect(remaining_titles).to eq(['Achievement gap'])
    end

    it 'hard-deletes topic-scoped analytics for removed articles' do
      analytic_keep = TopicArticleAnalytic.create!(
        topic:, article: article_a, average_daily_views: 100
      )
      analytic_remove = TopicArticleAnalytic.create!(
        topic:, article: article_b, average_daily_views: 50
      )

      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 }
      ])
      described_class.new(topic:, package:).sync!

      expect(TopicArticleAnalytic.exists?(analytic_keep.id)).to be true
      expect(TopicArticleAnalytic.exists?(analytic_remove.id)).to be false
    end

    it 'hard-deletes topic-scoped TopicArticleTimepoints for removed articles ' \
       'while preserving the underlying article-scoped ArticleTimepoint' do
      tt = TopicTimepoint.create!(topic:, timestamp: Date.new(2026, 2, 1))
      at_keep = ArticleTimepoint.create!(article: article_a, timestamp: Date.new(2026, 2, 1))
      at_remove = ArticleTimepoint.create!(article: article_b, timestamp: Date.new(2026, 2, 1))
      tat_keep = TopicArticleTimepoint.create!(topic_timepoint: tt, article_timepoint: at_keep)
      tat_remove = TopicArticleTimepoint.create!(topic_timepoint: tt, article_timepoint: at_remove)

      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 }
      ])
      described_class.new(topic:, package:).sync!

      expect(TopicArticleTimepoint.exists?(tat_keep.id)).to be true
      expect(TopicArticleTimepoint.exists?(tat_remove.id)).to be false
      # Article-scoped ArticleTimepoints are preserved (they may be shared
      # with other topics).
      expect(ArticleTimepoint.exists?(at_remove.id)).to be true
    end

    it 'updates Topic.tb_handle to the package handle' do
      package = package_with([], handle: 'tbp_brand_new')
      described_class.new(topic:, package:).sync!
      expect(topic.reload.tb_handle).to eq('tbp_brand_new')
    end

    it 'updates tb_handle even when the diff is empty (idempotent re-apply)' do
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Active learning', 'centrality' => nil }
      ], handle: 'tbp_brand_new')
      described_class.new(topic:, package:).sync!
      expect(topic.reload.tb_handle).to eq('tbp_brand_new')
    end

    it 'is wrapped in a transaction (failed adds roll back removes)' do
      # Simulate a failure during apply_adds! by stubbing Article.find_or_create_by!
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Bloom\'s taxonomy', 'centrality' => 5 }
      ])
      allow(Article).to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordInvalid)

      expect {
        described_class.new(topic:, package:).sync!
      }.to raise_error(ActiveRecord::RecordInvalid)

      # The remove of "Active learning" should have rolled back too.
      titles = bag.reload.article_bag_articles.includes(:article).map { |a| a.article.title }
      expect(titles).to contain_exactly('Achievement gap', 'Active learning')
      expect(topic.reload.tb_handle).to eq('tbp_old')
    end
  end

  # End-to-end check: a sync that adds and removes articles must
  # update every read method the topic-detail page consumes —
  # articles_count, total_average_daily_visits, article_analytics_data,
  # missing_articles_count — without waiting for the regen pipeline
  # to rebuild summaries. (Summary-derived stats like
  # articles_count_delta are intentionally allowed to lag until
  # incremental_topic_build runs.)
  describe 'topic read methods after a sync that adds and removes articles' do
    let(:article_c) { Article.create!(title: 'Bloom\'s taxonomy', wiki:, pageid: 3) }

    before do
      # Pre-existing summary captures the pre-sync snapshot (2 articles).
      TopicSummary.create!(
        topic:,
        articles_count: 2, articles_count_delta: 1,
        attributed_articles_created_delta: 1, attributed_length_delta: 100,
        attributed_revisions_count_delta: 1, attributed_token_count: 5,
        average_wp10_prediction: 50, length: 500, length_delta: 100,
        revisions_count: 10, revisions_count_delta: 5,
        token_count: 80, token_count_delta: 20, classifications: []
      )

      # Pre-existing analytics — both articles get pageviews, so
      # article_analytics_exist? returns true.
      TopicArticleAnalytic.create!(
        topic:, article: article_a,
        average_daily_views: 100, article_size: 1000
      )
      TopicArticleAnalytic.create!(
        topic:, article: article_b,
        average_daily_views: 80, article_size: 500
      )

      # Sync: keep article_a, remove article_b, add article_c.
      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 },
        { 'title' => 'Bloom\'s taxonomy', 'centrality' => 4 }
      ])
      described_class.new(topic:, package:).sync!
      topic.reload
    end

    it 'updates articles_count to reflect the post-sync bag' do
      expect(topic.articles_count).to eq(2)
    end

    it 'drops the removed article from total_average_daily_visits' do
      # 100 (kept) only; the removed article's 80 must not contribute.
      expect(topic.total_average_daily_visits).to eq(100)
    end

    it 'drops the removed article from article_analytics_data' do
      data = topic.article_analytics_data
      expect(data.keys).to contain_exactly('Achievement gap')
    end

    it 'leaves the most_recent_summary snapshot untouched' do
      # Summary is intentionally only refreshed by incremental_topic_build;
      # callers that need post-sync deltas must wait for that to complete.
      expect(topic.most_recent_summary.articles_count).to eq(2)
      expect(topic.most_recent_summary.articles_count_delta).to eq(1)
    end
  end

  # The Revisions / Tokens / WP10 tabs and the per-timepoint charts on
  # the Articles tab are all driven by TopicTimepoint stats, which are
  # aggregated from `topic_timepoint.topic_article_timepoints`. Those
  # TATs are deleted by the sync service for removed articles, so the
  # next aggregation run should reflect only the surviving bag. This
  # test runs the aggregation directly on a post-sync state to lock
  # that in — without it, a regression in the sync service's TAT
  # cleanup could silently leave Revisions/Tokens charts showing
  # stale numbers after the regen pipeline finishes.
  describe 'TopicTimepoint stats aggregation after a sync that removes an article' do
    # Must be one of topic.timestamps (start_date + N × interval), or
    # TopicTimepointStatsService → topic.timestamp_previous_to raises.
    let(:timestamp) { topic.timestamps[1] }
    let(:topic_timepoint) { TopicTimepoint.create!(topic:, timestamp:) }
    let(:at_a) do
      ArticleTimepoint.create!(
        article: article_a, timestamp:,
        article_length: 1000, revisions_count: 12, token_count: 200
      )
    end
    let(:at_b) do
      ArticleTimepoint.create!(
        article: article_b, timestamp:,
        article_length: 500, revisions_count: 8, token_count: 80
      )
    end

    before do
      TopicArticleTimepoint.create!(
        topic_timepoint:, article_timepoint: at_a,
        length_delta: 100, revisions_count_delta: 4, token_count_delta: 50
      )
      TopicArticleTimepoint.create!(
        topic_timepoint:, article_timepoint: at_b,
        length_delta: 80, revisions_count_delta: 3, token_count_delta: 20
      )

      package = package_with([
        { 'title' => 'Achievement gap', 'centrality' => 8 }
      ])
      described_class.new(topic:, package:).sync!

      TopicTimepointStatsService.new
        .update_stats_for_topic_timepoint(topic_timepoint: topic_timepoint.reload)
    end

    it 'aggregates only the surviving article into TopicTimepoint stats' do
      tp = topic_timepoint.reload
      expect(tp.articles_count).to eq(1)            # was 2 pre-sync
      expect(tp.length).to eq(1000)                 # only article_a
      expect(tp.revisions_count).to eq(12)
      expect(tp.token_count).to eq(200)
      expect(tp.length_delta).to eq(100)            # only article_a's TAT delta
      expect(tp.revisions_count_delta).to eq(4)
      expect(tp.token_count_delta).to eq(50)
    end

    it 'preserves the removed article\'s ArticleTimepoint (article-scoped, may be shared)' do
      # The TopicArticleTimepoint join row was deleted by sync, but
      # the underlying ArticleTimepoint remains in case another topic
      # references it.
      expect(ArticleTimepoint.exists?(at_b.id)).to be true
      expect(TopicArticleTimepoint.exists?(topic_timepoint:, article_timepoint: at_b)).to be false
    end
  end
end

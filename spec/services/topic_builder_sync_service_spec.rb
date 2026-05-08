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
end

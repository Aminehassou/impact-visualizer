# frozen_string_literal: true

# Applies a Topic Builder package to an existing IV topic by diffing the
# package's article list against the topic's active ArticleBag. v1 syncs
# only the article bag + centrality; config fields stay frozen at the
# original-import values.
#
# Removed articles get hard-deleted along with their topic-scoped analytics
# (TopicArticleAnalytic + TopicArticleTimepoint). Article + ArticleTimepoint
# rows are article-scoped and may be shared with other topics, so those
# stay. The net result: a synced topic looks like a fresh import would,
# except already-processed articles keep their analytics.
class TopicBuilderSyncService
  Diff = Struct.new(:adds, :removes, :centrality_changes, keyword_init: true) do
    def empty?
      adds.empty? && removes.empty? && centrality_changes.empty?
    end
  end

  CentralityChange = Struct.new(:title, :from, :to, keyword_init: true)

  attr_reader :topic, :package

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
  def self.compute_diff(topic:, package:)
    bag = topic.active_article_bag
    existing = bag ? bag.article_bag_articles.includes(:article).to_a : []
    by_title = existing.index_by { |aba| aba.article.title }

    package_entries = package.fetch('articles', []).reject do |entry|
      entry['title'].to_s.empty?
    end
    package_titles = package_entries.to_set { |e| e['title'].to_s }

    adds = package_entries.reject { |e| by_title.key?(e['title'].to_s) }
    removes = existing.reject { |aba| package_titles.include?(aba.article.title) }
    centrality_changes = package_entries.filter_map do |entry|
      aba = by_title[entry['title'].to_s]
      next nil if aba.nil?
      next nil if aba.centrality == entry['centrality']
      CentralityChange.new(title: entry['title'], from: aba.centrality, to: entry['centrality'])
    end

    Diff.new(adds:, removes:, centrality_changes:)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

  def initialize(topic:, package:)
    @topic = topic
    @package = package
  end

  def sync!
    diff = self.class.compute_diff(topic:, package:)
    bag = topic.active_article_bag

    Topic.transaction do
      apply_removes!(bag, diff.removes)
      apply_centrality_changes!(bag, diff.centrality_changes)
      apply_adds!(bag, diff.adds)
      topic.update!(tb_handle: package['handle'])
    end

    diff
  end

  private

  def apply_removes!(_bag, removes)
    return if removes.empty?

    aba_ids = removes.map(&:id)
    article_ids = removes.map(&:article_id)

    TopicArticleTimepoint
      .joins(:topic_timepoint, :article_timepoint)
      .where(topic_timepoints: { topic_id: topic.id },
             article_timepoints: { article_id: article_ids })
      .delete_all

    TopicArticleAnalytic
      .where(topic_id: topic.id, article_id: article_ids)
      .delete_all

    ArticleBagArticle.where(id: aba_ids).delete_all
  end

  def apply_centrality_changes!(bag, changes)
    return if changes.empty?

    abas_by_title = bag.article_bag_articles.includes(:article)
      .index_by { |aba| aba.article.title }

    changes.each do |change|
      aba = abas_by_title[change.title]
      next unless aba
      aba.update!(centrality: change.to)
    end
  end

  def apply_adds!(bag, adds)
    return if adds.empty?

    adds.each do |entry|
      title = entry['title'].to_s
      article = Article.find_or_create_by!(title:, wiki: topic.wiki)
      ArticleBagArticle.find_or_create_by!(article_bag: bag, article:) do |aba|
        aba.centrality = entry['centrality']
      end
    end
  end
end

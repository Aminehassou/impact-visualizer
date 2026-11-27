# frozen_string_literal: true

class ArticleTimeTravelService
  MIN_YEAR = 2015
  MIN_PAGEVIEWS_DATE = Date.new(2015, 7, 1)
  THREADS_COUNT = 3

  class InvalidRequest < StandardError; end

  def initialize(topic)
    @topic = topic
    @article_stats_service = ArticleStatsService.new(topic.wiki)
  end

  def self.max_year
    Date.current.year
  end

  def call(article_titles:, start_year:, end_year:)
    titles = validate_titles(article_titles)
    validate_years(start_year, end_year)

    articles = @topic.active_article_bag.articles.where(title: titles).to_a
    result = {}
    semaphore = Mutex.new

    articles.each_slice(THREADS_COUNT) do |slice|
      threads = slice.map do |article|
        Thread.new(article) do |a|
          snapshots = snapshots_for(a, start_year, end_year)
          semaphore.synchronize { result[a.title] = snapshots }
        end
      end
      threads.each(&:join)
    end

    titles.index_with { |title| result[title] || empty_snapshots(start_year, end_year) }
  end

  private

  def validate_titles(article_titles)
    titles = Array(article_titles).map(&:to_s).uniq.reject(&:blank?)
    raise InvalidRequest, 'At least one article is required' if titles.empty?

    reject_unknown_titles(titles)
    titles
  end

  def reject_unknown_titles(titles)
    bag = @topic.active_article_bag
    known = bag ? bag.articles.pluck(:title) : []
    unknown = titles - known
    raise InvalidRequest, "Unknown articles: #{unknown.join(', ')}" if unknown.any?
  end

  def validate_years(start_year, end_year)
    [start_year, end_year].each do |year|
      unless year.is_a?(Integer) && year.between?(MIN_YEAR, self.class.max_year)
        raise InvalidRequest, "Years must be between #{MIN_YEAR} and #{self.class.max_year}"
      end
    end

    raise InvalidRequest, 'Start year must be before end year' unless start_year < end_year
  end

  def empty_snapshots(start_year, end_year)
    { start_year.to_s => nil, end_year.to_s => nil }
  end

  def snapshots_for(article, start_year, end_year)
    @article_stats_service.update_details_for_article(article:)
    article.reload

    if article.missing
      Rails.logger.info("[ArticleTimeTravelService] #{article.title} is missing, skipping")
      return empty_snapshots(start_year, end_year)
    end

    start_snapshot, end_snapshot = [start_year, end_year].map { |year| snapshot(article, year) }
    start_rev_id = start_snapshot&.delete(:revision_id)
    end_rev_id = end_snapshot&.delete(:revision_id)
    end_snapshot&.merge!(edits_in_period(article, start_year, start_rev_id, end_rev_id))

    { start_year.to_s => start_snapshot, end_year.to_s => end_snapshot }
  end

  def snapshot(article, year)
    date = snapshot_date(year)
    return nil unless existed_at?(article, date)

    revision = fetch(:revision, article) do
      @article_stats_service.get_revision_at_date(article:, date:)
    end
    return nil unless revision && revision['size']

    {
      revision_id: revision['revid'],
      article_size: revision['size'],
      lead_section_size: fetch(:lead_section_size, article) do
        @article_stats_service.get_lead_section_size_at_date(article:, date:)
      end,
      talk_size: fetch(:talk_size, article) do
        @article_stats_service.get_talk_page_size_at_date(article:, date:)
      end,
      average_daily_views: average_daily_views(article, year, date)
    }
  end

  def average_daily_views(article, year, date)
    from = pageviews_start(year)
    fetch(:average_daily_views, article) do
      @article_stats_service.get_average_daily_views(
        article: article.title,
        start_year: from.year, start_month: from.month, start_day: from.day,
        end_year: year, end_month: date.month, end_day: date.day
      )&.round
    end
  end

  def edits_in_period(article, start_year, start_rev_id, end_rev_id)
    return edits_result(0) if start_rev_id == end_rev_id

    created_in_period = !existed_at?(article, snapshot_date(start_year))
    from_rev_id = created_in_period ? article.first_revision_id : start_rev_id
    return edits_result(nil) unless from_rev_id
    return edits_result(1) if from_rev_id == end_rev_id

    count_edits(article, from_rev_id, end_rev_id, created_in_period ? 2 : 1)
  end

  def count_edits(article, from_rev_id, to_rev_id, excluded_in_period)
    result = fetch(:edits_in_period, article) do
      @article_stats_service.get_edits_count_between(article:, from_rev_id:, to_rev_id:)
    end
    return edits_result(nil) unless result

    edits_result(result[:count] + excluded_in_period, capped: result[:capped])
  end

  def edits_result(count, capped: false)
    { edits_in_period: count, edits_in_period_capped: capped }
  end

  def existed_at?(article, date)
    first_revision_at = article.first_revision_at
    first_revision_at.present? && first_revision_at.to_date <= date
  end

  def snapshot_date(year)
    [Date.new(year, 12, 31), Date.current].min
  end

  # The pageviews API has no data before 2015-07-01; asking for a range that
  # starts earlier returns a 404, which the client reports as 0 views.
  def pageviews_start(year)
    [Date.new(year, 1, 1), MIN_PAGEVIEWS_DATE].max
  end

  def fetch(what, article)
    yield
  rescue StandardError => e
    Rails.logger.error(
      "[ArticleTimeTravelService] Error fetching #{what} for #{article.title}: #{e.message}"
    )
    nil
  end
end

# frozen_string_literal: true

class ImportService
  attr_accessor :topic, :wiki_action_api

  def initialize(topic:)
    @topic = topic
    @wiki = topic.wiki
    @wiki_action_api = WikiActionApi.new(@wiki)
    @imported_titles_mutex = Mutex.new
    @imported_titles = {}
  end

  def normalize_csv_content(content)
    lines = content.split("\n")
    normalized_lines = lines.map do |line|
      line = line.strip
      next if line.empty?

      unquoted = if line.start_with?('"') && line.end_with?('"')
                   line[1..-2].gsub('""', '"')
                 else
                   line
                 end

      "\"#{unquoted.gsub('"', '""')}\""
    end
    normalized_lines.compact.join("\n")
  end

  def reset_topic
    @topic.topic_timepoints.each do |topic_timepoint|
      topic_timepoint.topic_article_timepoints.destroy_all
    end

    @topic.topic_timepoints.destroy_all

    @topic.articles.each do |article|
      article.article_timepoints.destroy_all
      article.article_bag_articles.destroy_all
      article.destroy
    end

    @topic.users.destroy_all
    @topic.topic_summaries.destroy_all
    @topic.article_bags.destroy_all
  end

  def import_articles(total: nil, at: nil)
    raise ImpactVisualizerErrors::CsvMissingForImport unless topic.articles_csv.attached?
    article_rows = parse_article_csv_content(topic.articles_csv.download.force_encoding('UTF-8'))
    article_bag = @topic.active_article_bag ||
                  ArticleBag.create(topic:, name: "#{topic.slug.titleize} Articles")
    total&.call(article_rows.count)
    count = 0
    Parallel.each(article_rows, in_threads: 3) do |article_row|
      ActiveRecord::Base.connection_pool.with_connection do
        count += 1
        at&.call(count)
        import_article(article_row:, article_bag:)
        ActiveRecord::Base.connection_pool.release_connection
      end
    end
  end

  def import_article(article_row:, article_bag:)
    csv_title = article_row[:title]
    centrality = article_row[:centrality]
    page_info = @wiki_action_api.get_page_info(title: URI::DEFAULT_PARSER.unescape(csv_title))
    return unless page_info
    title = page_info['title']

    @imported_titles_mutex.synchronize do
      if @imported_titles.key?(title)
        Rails.logger.warn(
          "DUPLICATE DETECTED: CSV entry '#{csv_title}' resolves to '#{title}', " \
          "which was already imported from CSV entry '#{@imported_titles[title]}'"
        )
      else
        @imported_titles[title] = csv_title
      end
    end

    article = Article.find_or_create_by(title:, wiki: @wiki)
    article.update_details
    article_bag_article = ArticleBagArticle.find_or_initialize_by(article:, article_bag:)
    article_bag_article.centrality = centrality
    article_bag_article.save!
  end

  def import_users(total: nil, at: nil)
    raise ImpactVisualizerErrors::CsvMissingForImport unless topic.users_csv.attached?
    csv_content = normalize_csv_content(topic.users_csv.download.force_encoding('UTF-8'))
    user_names = CSV.parse(csv_content, headers: false, skip_blanks: true)
    total&.call(user_names.count)
    count = 0
    Parallel.each(user_names, in_threads: 10) do |user_name|
      ActiveRecord::Base.connection_pool.with_connection do
        count += 1
        at&.call(count)
        user = User.find_or_create_by(name: user_name[0], wiki: @wiki)
        user.update_name_and_id
        TopicUser.find_or_create_by user:, topic: @topic
        ActiveRecord::Base.connection_pool.release_connection
      end
    end
  end

  private

  def parse_article_csv_content(content)
    content.lines.filter_map { |line| parse_article_csv_line(line) }
  end

  def parse_article_csv_line(line)
    stripped_line = line.strip
    return if stripped_line.empty?

    fields = parse_csv_line(stripped_line)
    return if fields.empty?

    centrality = fields.length > 1 ? parse_centrality(fields.last) : nil
    title_fields = centrality ? fields[0...-1] : fields
    title = title_fields.map(&:to_s).join(',').strip
    return if title.empty?

    { title:, centrality: }
  end

  def parse_csv_line(line)
    CSV.parse_line(line, liberal_parsing: true) || []
  rescue CSV::MalformedCSVError
    [line]
  end

  def parse_centrality(value)
    normalized = value.to_s.strip
    return unless normalized.match?(/\A(?:[1-9]|10)\z/)

    normalized.to_i
  end
end

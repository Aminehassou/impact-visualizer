# frozen_string_literal: true

class ImportArticlesJob
  include Sidekiq::Job
  include Sidekiq::Status::Worker
  sidekiq_options queue: 'import'

  def perform(topic_id)
    @expiration = 60 * 60 * 24 * 30
    store(started_at: Time.now.to_i)

    topic = Topic.find topic_id
    import_service = ImportService.new(topic:)
    import_service.import_articles(total: method(:total), at: method(:at))
    topic.reload.update(article_import_job_id: nil)
    topic.chain_to_analytics_if_ready
  end

  def expiration
    @expiration = 60 * 60 * 24 * 30
  end
end

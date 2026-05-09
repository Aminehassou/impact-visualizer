# frozen_string_literal: true

# Background sync of a Topic Builder package against an existing IV topic.
# Mirror of ImportTopicBuilderArticlesJob: the controller queues this when
# the user clicks Apply on the sync preview, and the job re-fetches the
# package + applies the diff via TopicBuilderSyncService.
class SyncTopicBuilderArticlesJob
  include Sidekiq::Job
  include Sidekiq::Status::Worker
  sidekiq_options queue: 'import', retry: 3

  sidekiq_retries_exhausted do |msg, _ex|
    topic_id = msg['args'].first
    # rubocop:disable Rails/SkipsModelValidations -- bulk update bypasses callbacks intentionally
    Topic.where(id: topic_id).update_all(article_import_job_id: nil)
    # rubocop:enable Rails/SkipsModelValidations
  end

  EXPIRATION_SECONDS = 60 * 60 * 24 * 30

  def perform(topic_id, handle)
    @expiration = EXPIRATION_SECONDS
    store(started_at: Time.now.to_i)

    topic = Topic.find(topic_id)

    package = TopicBuilderPackageService.fetch(handle)
    TopicBuilderPackageService.assert_supported_schema!(package)

    diff = TopicBuilderSyncService.compute_diff(topic:, package:)
    diff_count = diff.adds.size + diff.removes.size + diff.centrality_changes.size
    total(diff_count)
    at(0, 'Applying Topic Builder sync')

    TopicBuilderSyncService.new(topic:, package:).sync!

    at(diff_count, 'Sync applied')

    topic.reload.update(article_import_job_id: nil)
    topic.queue_generate_article_analytics
  end

  def expiration
    @expiration ||= EXPIRATION_SECONDS
  end
end

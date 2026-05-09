# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GenerateArticleAnalyticsJob, type: :job do
  let!(:wiki) { Wiki.find_or_create_by!(language: 'en', project: 'wikipedia') }

  describe '#perform — auto-chain to incremental_topic_build' do
    context 'for a Topic Builder topic' do
      let(:topic) do
        create(:topic, wiki:, tb_handle: 'tbp_abc123',
                       start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31))
      end

      it 'queues IncrementalTopicBuildJob at the tail (empty article bag short-circuit)' do
        expect {
          described_class.new.perform(topic.id)
        }.to change(IncrementalTopicBuildJob.jobs, :size).by(1)
      end
    end

    context 'for a CSV-driven topic (no tb_handle)' do
      let(:topic) do
        create(:topic, wiki:, tb_handle: nil,
                       start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31))
      end

      # Every topic now flows through the same auto-chained pipeline
      # (articles → analytics → timepoint build); the tb_handle gate
      # was removed when the unified data-generation UI shipped.
      it 'queues IncrementalTopicBuildJob at the tail' do
        expect {
          described_class.new.perform(topic.id)
        }.to change(IncrementalTopicBuildJob.jobs, :size).by(1)
      end
    end

    context 'for a TB topic that already has a build in flight' do
      let(:topic) do
        create(:topic, wiki:, tb_handle: 'tbp_abc123',
                       incremental_topic_build_job_id: 'in-flight',
                       start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31))
      end

      it 'does not queue a second IncrementalTopicBuildJob' do
        expect {
          described_class.new.perform(topic.id)
        }.to change(IncrementalTopicBuildJob.jobs, :size).by(0)
      end
    end
  end

  describe '#perform — recency-cache skip' do
    let(:topic) do
      create(:topic, wiki:, tb_handle: 'tbp_abc123',
                     start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31))
    end
    let(:bag) { topic.active_article_bag }
    let(:fresh_article) { Article.create!(title: 'Fresh', wiki:, pageid: 1) }
    let(:stale_article) { Article.create!(title: 'Stale', wiki:, pageid: 2) }

    before do
      ArticleBagArticle.create!(article_bag: bag, article: fresh_article)
      ArticleBagArticle.create!(article_bag: bag, article: stale_article)
    end

    it 'skips articles whose TopicArticleAnalytic was updated within RECENCY_WINDOW' do
      TopicArticleAnalytic.create!(topic:, article: fresh_article, average_daily_views: 100)
      stale = TopicArticleAnalytic.create!(
        topic:, article: stale_article, average_daily_views: 50
      )
      # rubocop:disable Rails/SkipsModelValidations -- backdating updated_at is the whole point
      stale.update_columns(updated_at: described_class::RECENCY_WINDOW.ago - 1.minute)
      # rubocop:enable Rails/SkipsModelValidations

      stats_service = instance_double(ArticleStatsService)
      allow(ArticleStatsService).to receive(:new).and_return(stats_service)
      allow(stats_service).to receive(:update_details_for_article) do |args|
        # Only the stale article should reach the stats service.
        expect(args[:article]).to eq(stale_article)
      end
      allow(stats_service).to receive(:get_average_daily_views).and_return(0)
      allow(stats_service).to receive(:get_article_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_page_assessment_grade).and_return(nil)
      allow(stats_service).to receive(:get_linguistic_versions_count).and_return(0)
      allow(stats_service).to receive(:get_images_count).and_return(0)
      allow(stats_service).to receive(:get_warning_tags_count).and_return(0)
      allow(stats_service).to receive(:get_number_of_editors).and_return(0)
      allow(stats_service).to receive(:get_article_protections).and_return([])
      allow(stats_service).to receive(:get_incoming_links_count).and_return(0)

      described_class.new.perform(topic.id)

      expect(stats_service).to have_received(:update_details_for_article).once
    end

    it 'processes everything when force=true even if recently updated' do
      TopicArticleAnalytic.create!(topic:, article: fresh_article, average_daily_views: 100)
      TopicArticleAnalytic.create!(topic:, article: stale_article, average_daily_views: 50)

      stats_service = instance_double(ArticleStatsService)
      allow(ArticleStatsService).to receive(:new).and_return(stats_service)
      allow(stats_service).to receive(:update_details_for_article)
      allow(stats_service).to receive(:get_average_daily_views).and_return(0)
      allow(stats_service).to receive(:get_article_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_page_assessment_grade).and_return(nil)
      allow(stats_service).to receive(:get_linguistic_versions_count).and_return(0)
      allow(stats_service).to receive(:get_images_count).and_return(0)
      allow(stats_service).to receive(:get_warning_tags_count).and_return(0)
      allow(stats_service).to receive(:get_number_of_editors).and_return(0)
      allow(stats_service).to receive(:get_article_protections).and_return([])
      allow(stats_service).to receive(:get_incoming_links_count).and_return(0)

      described_class.new.perform(topic.id, true)

      expect(stats_service).to have_received(:update_details_for_article).twice
    end
  end
end

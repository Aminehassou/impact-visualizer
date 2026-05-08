# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SyncTopicBuilderArticlesJob, type: :job do
  let!(:wiki) { Wiki.find_or_create_by!(language: 'en', project: 'wikipedia') }
  let(:handle) { 'tbp_new123' }
  let(:url) { "https://topic-builder.wikiedu.org/packages/#{handle}" }
  let(:source_topic_id) { 42 }
  let(:topic) do
    create(:topic, wiki: wiki, tb_handle: 'tbp_old', tb_source_topic_id: source_topic_id)
  end
  let(:bag) { topic.active_article_bag }
  let(:article_a) { Article.create!(title: 'Achievement gap', wiki: wiki, pageid: 1) }
  let(:article_b) { Article.create!(title: 'Active learning', wiki: wiki, pageid: 2) }
  let(:package) do
    {
      'handle' => handle,
      'schema_version' => 1,
      'source_topic_id' => source_topic_id,
      'config' => { 'name' => topic.name, 'wiki' => 'en' },
      'articles' => [
        { 'title' => 'Achievement gap', 'centrality' => 9 },
        { 'title' => 'Bloom\'s taxonomy', 'centrality' => 5 }
      ]
    }
  end

  before do
    create(:article_bag_article, article_bag: bag, article: article_a, centrality: 8)
    create(:article_bag_article, article_bag: bag, article: article_b, centrality: nil)
    stub_request(:get, url).to_return(
      status: 200, body: package.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
  end

  it 're-fetches the package and applies the diff' do
    described_class.new.perform(topic.id, handle)

    titles = bag.reload.article_bag_articles.includes(:article).map { |a| a.article.title }
    expect(titles).to contain_exactly('Achievement gap', 'Bloom\'s taxonomy')

    centrality = bag.article_bag_articles.joins(:article)
                    .find_by('articles.title' => 'Achievement gap').centrality
    expect(centrality).to eq(9)
  end

  it 'updates Topic.tb_handle to the new package handle' do
    described_class.new.perform(topic.id, handle)
    expect(topic.reload.tb_handle).to eq(handle)
  end

  it 'clears article_import_job_id when finished' do
    topic.update(article_import_job_id: 'fake-job-id')
    described_class.new.perform(topic.id, handle)
    expect(topic.reload.article_import_job_id).to be_nil
  end

  it 'queues GenerateArticleAnalyticsJob to refresh analytics for the synced bag' do
    expect {
      described_class.new.perform(topic.id, handle)
    }.to change(GenerateArticleAnalyticsJob.jobs, :size).by(1)
  end

  it 'clears article_import_job_id when all retries are exhausted' do
    topic.update(article_import_job_id: 'fake-jid')
    described_class.sidekiq_retries_exhausted_block.call(
      { 'args' => [topic.id, handle] }, RuntimeError.new('TB unreachable')
    )
    expect(topic.reload.article_import_job_id).to be_nil
  end
end

# frozen_string_literal: true

require 'rails_helper'

describe ArticleTimeTravelService do
  let(:topic) { create(:topic) }
  let(:article_bag) { topic.active_article_bag }
  let(:service) { described_class.new(topic) }
  let(:current_year) { Date.current.year }

  def add_article(title:, pageid:, first_revision_at: Date.new(2010, 1, 1))
    article = create(:article, title:, pageid:, first_revision_at:)
    create(:article_bag_article, article:, article_bag:)
    article
  end

  describe 'validation' do
    before { add_article(title: 'Forest', pageid: 1) }

    it 'rejects an empty article list' do
      expect { service.call(article_titles: [], start_year: 2016, end_year: 2020) }
        .to raise_error(described_class::InvalidRequest, /At least one article/)
    end

    it 'rejects titles outside the active article bag' do
      expect { service.call(article_titles: ['Rainforest'], start_year: 2016, end_year: 2020) }
        .to raise_error(described_class::InvalidRequest, /Unknown articles: Rainforest/)
    end

    it 'rejects a start year before MIN_YEAR' do
      expect { service.call(article_titles: ['Forest'], start_year: 2010, end_year: 2020) }
        .to raise_error(described_class::InvalidRequest, /between 2015/)
    end

    it 'rejects an end year in the future' do
      expect {
        service.call(article_titles: ['Forest'], start_year: 2016, end_year: current_year + 1)
      }
        .to raise_error(described_class::InvalidRequest, /between 2015/)
    end

    it 'rejects a start year that is not before the end year' do
      expect { service.call(article_titles: ['Forest'], start_year: 2020, end_year: 2020) }
        .to raise_error(described_class::InvalidRequest, /before end year/)
    end
  end

  describe '#call' do
    let(:stats_service) { instance_double(ArticleStatsService) }

    before do
      allow(ArticleStatsService).to receive(:new).and_return(stats_service)
      allow(stats_service).to receive(:update_details_for_article)
      allow(stats_service).to receive(:get_edits_count_between)
        .and_return({ count: 40, capped: false })
    end

    it 'returns a snapshot per article per year' do
      add_article(title: 'Forest', pageid: 1)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 1000, 'revid' => 1 }, { 'size' => 2000, 'revid' => 2 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100, 200)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(10, 20)
      allow(stats_service).to receive(:get_average_daily_views).and_return(5.4, 9.6)

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result).to eq(
        'Forest' => {
          '2016' => { article_size: 1000, lead_section_size: 100, talk_size: 10,
                      average_daily_views: 5 },
          '2020' => { article_size: 2000, lead_section_size: 200, talk_size: 20,
                      average_daily_views: 10, edits_in_period: 41, edits_in_period_capped: false }
        }
      )
    end

    it 'returns nil for a year before the article existed' do
      add_article(title: 'Taiga', pageid: 2, first_revision_at: Date.new(2018, 6, 1))
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 2000, 'revid' => 1 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(200)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(20)
      allow(stats_service).to receive(:get_average_daily_views).and_return(9.0)

      result = service.call(article_titles: ['Taiga'], start_year: 2016, end_year: 2020)

      expect(result['Taiga']['2016']).to be_nil
      expect(result['Taiga']['2020']).to include(article_size: 2000)
    end

    it 'returns nil for a year whose revision lookup fails' do
      add_article(title: 'Forest', pageid: 1)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return(nil, { 'size' => 2000, 'revid' => 2 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(200)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(20)
      allow(stats_service).to receive(:get_average_daily_views).and_return(9.0)

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result['Forest']['2016']).to be_nil
      expect(result['Forest']['2020']).to include(article_size: 2000)
    end

    it 'keeps a nil metric alongside the ones that resolved' do
      add_article(title: 'Forest', pageid: 1)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 1000, 'revid' => 1 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(nil)
      allow(stats_service).to receive(:get_average_daily_views)
        .and_raise(StandardError, 'pageviews down')

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result['Forest']['2016']).to eq(
        article_size: 1000, lead_section_size: 100, talk_size: nil, average_daily_views: nil
      )
    end

    it 'returns empty snapshots for a missing article' do
      article = add_article(title: 'Forest', pageid: 1)
      article.update!(missing: true)

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result).to eq('Forest' => { '2016' => nil, '2020' => nil })
    end

    it 'clamps the pageviews window to July 2015' do
      add_article(title: 'Forest', pageid: 1)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 1000, 'revid' => 1 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(10)
      allow(stats_service).to receive(:get_average_daily_views).and_return(5.0)

      service.call(article_titles: ['Forest'], start_year: 2015, end_year: 2020)

      expect(stats_service).to have_received(:get_average_daily_views)
        .with(hash_including(start_year: 2015, start_month: 7, start_day: 1))
      expect(stats_service).to have_received(:get_average_daily_views)
        .with(hash_including(start_year: 2020, start_month: 1, start_day: 1))
    end

    it 'clamps the snapshot date to today for the current year' do
      add_article(title: 'Forest', pageid: 1)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 1000, 'revid' => 1 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(10)
      allow(stats_service).to receive(:get_average_daily_views).and_return(5.0)

      service.call(article_titles: ['Forest'], start_year: 2016, end_year: current_year)

      expect(stats_service).to have_received(:get_revision_at_date)
        .with(hash_including(date: Date.current))
    end

    it 'treats an article with only first_revision_at as existing' do
      article = add_article(title: 'Forest', pageid: 1)
      article.update!(first_revision_by_id: nil, first_revision_id: nil)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 1000, 'revid' => 1 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(10)
      allow(stats_service).to receive(:get_average_daily_views).and_return(5.0)

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result['Forest']['2016']).to include(article_size: 1000)
    end

    it 'does not drop results when fanning out across threads' do
      titles = Array.new(12) do |i|
        "Article #{i}".tap { |t| add_article(title: t, pageid: 100 + i) }
      end
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return({ 'size' => 1000, 'revid' => 1 })
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(10)
      allow(stats_service).to receive(:get_average_daily_views).and_return(5.0)

      result = service.call(article_titles: titles, start_year: 2016, end_year: 2020)

      expect(result.keys).to match_array(titles)
      expect(result.values.map { |years| years['2016'][:article_size] }).to all(eq(1000))
    end
  end

  describe 'edits in period' do
    let(:stats_service) { instance_double(ArticleStatsService) }

    before do
      allow(ArticleStatsService).to receive(:new).and_return(stats_service)
      allow(stats_service).to receive(:update_details_for_article)
      allow(stats_service).to receive(:get_lead_section_size_at_date).and_return(100)
      allow(stats_service).to receive(:get_talk_page_size_at_date).and_return(10)
      allow(stats_service).to receive(:get_average_daily_views).and_return(5.0)
      allow(stats_service).to receive(:get_edits_count_between)
        .and_return({ count: 40, capped: false })
    end

    def revisions(*revids)
      allow(stats_service).to receive(:get_revision_at_date)
        .and_return(*revids.map { |revid| revid && { 'size' => 1000, 'revid' => revid } })
    end

    def edits_for(title)
      result = service.call(article_titles: [title], start_year: 2016, end_year: 2020)
      result[title]['2020'].slice(:edits_in_period, :edits_in_period_capped)
    end

    it 'adds back the end revision, which the endpoint excludes' do
      add_article(title: 'Forest', pageid: 1)
      revisions(10, 20)

      expect(edits_for('Forest')).to eq(edits_in_period: 41, edits_in_period_capped: false)
      expect(stats_service).to have_received(:get_edits_count_between)
        .with(hash_including(from_rev_id: 10, to_rev_id: 20))
    end

    it 'only adds edits to the end-year snapshot' do
      add_article(title: 'Forest', pageid: 1)
      revisions(10, 20)

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result['Forest']['2016']).not_to have_key(:edits_in_period)
      expect(result['Forest']['2016']).not_to have_key(:revision_id)
      expect(result['Forest']['2020']).not_to have_key(:revision_id)
    end

    it 'returns 0 without calling the API when the revision did not change' do
      add_article(title: 'Forest', pageid: 1)
      revisions(10, 10)

      expect(edits_for('Forest')).to include(edits_in_period: 0)
      expect(stats_service).not_to have_received(:get_edits_count_between)
    end

    it 'counts from the creation revision for an article created in the period' do
      article = add_article(title: 'Taiga', pageid: 2, first_revision_at: Date.new(2018, 6, 1))
      article.update!(first_revision_id: 5)
      revisions(20)

      expect(edits_for('Taiga')).to include(edits_in_period: 42)
      expect(stats_service).to have_received(:get_edits_count_between)
        .with(hash_including(from_rev_id: 5, to_rev_id: 20))
    end

    it 'returns 1 for an article created in the period and never edited again' do
      article = add_article(title: 'Taiga', pageid: 2, first_revision_at: Date.new(2018, 6, 1))
      article.update!(first_revision_id: 20)
      revisions(20)

      expect(edits_for('Taiga')).to include(edits_in_period: 1)
      expect(stats_service).not_to have_received(:get_edits_count_between)
    end

    it 'returns nil for an article created in the period with no creation revision id' do
      article = add_article(title: 'Taiga', pageid: 2, first_revision_at: Date.new(2018, 6, 1))
      article.update!(first_revision_id: nil)
      revisions(20)

      expect(edits_for('Taiga')).to include(edits_in_period: nil)
    end

    it 'returns nil instead of counting all history when the start lookup failed' do
      article = add_article(title: 'Forest', pageid: 1)
      article.update!(first_revision_id: 1)
      revisions(nil, 20)

      expect(edits_for('Forest')).to include(edits_in_period: nil)
      expect(stats_service).not_to have_received(:get_edits_count_between)
    end

    it 'returns nil for edits but keeps the other metrics when the count fails' do
      add_article(title: 'Forest', pageid: 1)
      revisions(10, 20)
      allow(stats_service).to receive(:get_edits_count_between).and_return(nil)

      result = service.call(article_titles: ['Forest'], start_year: 2016, end_year: 2020)

      expect(result['Forest']['2020']).to include(article_size: 1000, edits_in_period: nil)
    end

    it 'passes the capped flag through' do
      add_article(title: 'Forest', pageid: 1)
      revisions(10, 20)
      allow(stats_service).to receive(:get_edits_count_between)
        .and_return({ count: 30_000, capped: true })

      expect(edits_for('Forest')).to eq(edits_in_period: 30_001, edits_in_period_capped: true)
    end
  end
end

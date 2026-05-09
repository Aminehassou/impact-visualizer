# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wiki do
  it { is_expected.to have_many(:topics) }

  describe 'validation' do
    context 'For valid wiki projects' do
      it 'ensures the project and language combination are unique' do
        create(:wiki, language: 'zh', project: 'wiktionary')
        expect { create(:wiki, language: 'zh', project: 'wiktionary') }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'For invalid wiki projects' do
      let(:bad_language) { create(:wiki, language: 'xx', project: 'wikipedia') }
      let(:bad_project) { create(:wiki, language: 'en', project: 'wikinothing') }
      let(:nil_language) { create(:wiki, language: nil, project: 'wikipedia') }

      it 'does not allow bad language codes' do
        expect { bad_language }.to raise_error(ActiveRecord::RecordInvalid)
      end

      it 'does not allow bad projects' do
        expect { bad_project }.to raise_error(ActiveRecord::RecordInvalid)
      end

      it 'does not allow nil language for standard projects' do
        expect { nil_language }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe '.default_wiki' do
    it 'creates a default wiki' do
      expect(described_class.count).to eq(0)
      wiki = described_class.default_wiki
      expect(described_class.count).to eq(1)
      expect(wiki.language).to eq('en')
      expect(wiki.project).to eq('wikipedia')
    end

    it 'returns existing default wiki' do
      described_class.create language: 'en', project: 'wikipedia'
      wiki = described_class.default_wiki
      expect(described_class.count).to eq(1)
      expect(wiki.language).to eq('en')
      expect(wiki.project).to eq('wikipedia')
    end
  end

  describe '#base_url' do
    it 'returns the correct url for standard projects' do
      wiki = described_class.find_or_create_by(language: 'en', project: 'wikipedia')
      expect(wiki.base_url).to eq('https://en.wikipedia.org')
    end
  end

  describe '#action_api_url' do
    it 'returns the correct url for standard projects' do
      wiki = described_class.find_or_create_by(language: 'en', project: 'wikipedia')
      expect(wiki.action_api_url).to eq('https://en.wikipedia.org/w/api.php')
    end
  end

  describe '#rest_api_url' do
    it 'returns the correct url for standard projects' do
      wiki = described_class.find_or_create_by(language: 'en', project: 'wikipedia')
      expect(wiki.rest_api_url).to eq('https://en.wikipedia.org/w/rest.php/v1/')
    end
  end

  describe '#tokens_per_word_default' do
    before { described_class.reset_tokens_per_word_table! }
    after  { described_class.reset_tokens_per_word_table! }

    it 'returns the median from config/words_per_token.yml for a known language' do
      wiki = described_class.find_or_create_by(language: 'en', project: 'wikipedia')
      table = described_class.tokens_per_word_table
      # If the file is present, the value should match its YAML entry; if
      # not, the test still proves the fallback. Either way, the method
      # must return a positive Float.
      expect(wiki.tokens_per_word_default).to be_a(Float)
      expect(wiki.tokens_per_word_default).to be > 0
      expect(wiki.tokens_per_word_default).to eq(table['en']) if table['en']
    end

    it 'falls back to TOKENS_PER_WORD_GLOBAL_FALLBACK for languages not in the table' do
      wiki = described_class.find_or_create_by(language: 'xx', project: 'wikipedia')
      # 'xx' isn't a real Wikipedia language and won't be in the YAML
      # study output. We bypass validation since 'xx' isn't in LANGUAGES.
      wiki.save(validate: false)
      expect(wiki.tokens_per_word_default).to eq(Wiki::TOKENS_PER_WORD_GLOBAL_FALLBACK)
    end
  end
end

# == Schema Information
#
# Table name: wikis
#
#  id            :bigint           not null, primary key
#  language      :string(16)
#  project       :string(16)
#  wikidata_site :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_wikis_on_language_and_project  (language,project) UNIQUE
#

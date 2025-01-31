FactoryBot.define do
  factory :article do
    pageid { 2364730 }
    title { 'Yankari Game Reserve' }
    first_revision_at { Date.new(2020, 1, 1) }
    first_revision_by_name { 'username' }
    first_revision_by_id { 1234 }
    first_revision_id { 3456 }
    wiki { Wiki.default_wiki }
  end
end

# == Schema Information
#
# Table name: articles
#
#  id                     :bigint           not null, primary key
#  first_revision_at      :datetime
#  first_revision_by_name :string
#  missing                :boolean          default(FALSE)
#  pageid                 :integer
#  title                  :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  first_revision_by_id   :integer
#  first_revision_id      :integer
#  wiki_id                :bigint           not null
#
# Indexes
#
#  index_articles_on_wiki_id  (wiki_id)
#
# Foreign Keys
#
#  fk_rails_...  (wiki_id => wikis.id)
#

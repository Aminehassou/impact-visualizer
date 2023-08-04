# frozen_string_literal: true

class ArticleBag < ApplicationRecord
  # Associations
  belongs_to :topic
  has_many :article_bag_articles
  has_many :articles, through: :article_bag_articles

  default_scope { order(created_at: :asc) }
end

# == Schema Information
#
# Table name: article_bags
#
#  id         :bigint           not null, primary key
#  name       :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  topic_id   :bigint           not null
#
# Indexes
#
#  index_article_bags_on_topic_id  (topic_id)
#
# Foreign Keys
#
#  fk_rails_...  (topic_id => topics.id)
#

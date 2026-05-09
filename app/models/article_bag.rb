# frozen_string_literal: true

class ArticleBag < ApplicationRecord
  # Bag-change auto-resume note: every code path that creates or
  # repopulates an ArticleBag already chains the data-generation
  # pipeline through Topic#queue_generate_article_analytics or via
  # Topic#chain_to_analytics_if_ready when a CSV import job
  # completes. No callback is needed here. New code paths that
  # mutate bag contents must do the same.
  #
  # Associations
  belongs_to :topic
  has_many :article_bag_articles, dependent: :destroy
  has_many :articles, through: :article_bag_articles

  default_scope { order(created_at: :asc) }

  # For ActiveAdmin
  def self.ransackable_associations(_auth_object = nil)
    %w[article_bag_articles articles topic]
  end

  def self.ransackable_attributes(_auth_object = nil)
    %w[created_at id name topic_id updated_at]
  end
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

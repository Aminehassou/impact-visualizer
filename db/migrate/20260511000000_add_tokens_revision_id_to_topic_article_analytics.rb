# frozen_string_literal: true

class AddTokensRevisionIdToTopicArticleAnalytics < ActiveRecord::Migration[7.0]
  def change
    add_column :topic_article_analytics, :tokens_revision_id, :integer
  end
end

# frozen_string_literal: true

class AddTokensUnavailableToTopicArticleAnalytics < ActiveRecord::Migration[7.0]
  def change
    add_column :topic_article_analytics, :tokens_unavailable, :boolean, default: false, null: false
  end
end

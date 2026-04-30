# frozen_string_literal: true

class AddCentralityToArticleBagArticles < ActiveRecord::Migration[7.0]
  def up
    add_column :article_bag_articles, :centrality, :integer, default: 0, null: false
    add_check_constraint :article_bag_articles, 'centrality >= 0 AND centrality <= 10', name: 'centrality_range'
  end

  def down
    remove_check_constraint :article_bag_articles, name: 'centrality_range'
    remove_column :article_bag_articles, :centrality
  end
end

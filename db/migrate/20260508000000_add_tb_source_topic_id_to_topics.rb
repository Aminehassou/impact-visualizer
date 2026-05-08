# frozen_string_literal: true

class AddTbSourceTopicIdToTopics < ActiveRecord::Migration[7.0]
  def change
    return if column_exists?(:topics, :tb_source_topic_id)

    add_column :topics, :tb_source_topic_id, :integer
    add_index :topics, :tb_source_topic_id, where: 'tb_source_topic_id IS NOT NULL'
  end
end

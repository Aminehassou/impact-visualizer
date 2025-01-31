FactoryBot.define do
  factory :topic_summary do
    topic {
      Topic.first || create(:topic)
    }    
  end
end

# == Schema Information
#
# Table name: topic_summaries
#
#  id                                :bigint           not null, primary key
#  articles_count                    :integer
#  articles_count_delta              :integer
#  attributed_articles_created_delta :integer
#  attributed_length_delta           :integer
#  attributed_revisions_count_delta  :integer
#  attributed_token_count            :integer
#  average_wp10_prediction           :float
#  classifications                   :jsonb
#  length                            :integer
#  length_delta                      :integer
#  missing_articles_count            :integer
#  revisions_count                   :integer
#  revisions_count_delta             :integer
#  timepoint_count                   :integer
#  token_count                       :integer
#  token_count_delta                 :integer
#  wp10_prediction_categories        :jsonb
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  topic_id                          :bigint           not null
#
# Indexes
#
#  index_topic_summaries_on_topic_id  (topic_id)
#
# Foreign Keys
#
#  fk_rails_...  (topic_id => topics.id)
#

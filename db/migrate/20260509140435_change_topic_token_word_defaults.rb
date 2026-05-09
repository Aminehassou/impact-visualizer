# frozen_string_literal: true

# Switch new topics to display words by default, with a per-language
# `tokens_per_word` divisor resolved from `Wiki#tokens_per_word_default`
# (backed by config/words_per_token.yml). Existing rows are left alone:
# operators who explicitly chose `convert_tokens_to_words=false` or a
# custom `tokens_per_word` keep their settings; the column-default
# changes only affect inserts going forward.
class ChangeTopicTokenWordDefaults < ActiveRecord::Migration[7.0]
  def up
    change_column_default :topics, :tokens_per_word, from: 3.25, to: nil
    change_column_default :topics, :convert_tokens_to_words, from: false, to: true
  end

  def down
    change_column_default :topics, :tokens_per_word, from: nil, to: 3.25
    change_column_default :topics, :convert_tokens_to_words, from: true, to: false
  end
end

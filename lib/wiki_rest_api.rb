# frozen_string_literal: true

class WikiRestApi
  include ApiErrorHandling

  # Projects exposing the MediaWiki REST API endpoints this client calls.
  # Deliberately NOT gated on language: /w/rest.php/v1/ ships with MediaWiki
  # itself, so the history-counts endpoint answers on every Wikipedia —
  # verified by live probe across large, tiny, and legacy dashed-code wikis
  # (be-tarask, zh-yue, bat-smg, …). An allowlist here would only lock out
  # wikis the API serves fine. Wiki::LANGUAGES already rejects codes that
  # aren't real Wikimedia languages, at the model layer.
  AVAILABLE_PROJECTS = %w[wikipedia wikidata].freeze

  def initialize(wiki)
    @api_url = wiki.rest_api_url
    @client = wiki_rest_server
    raise InvalidProjectError unless WikiRestApi.valid_wiki?(wiki)
  end

  def self.valid_wiki?(wiki)
    AVAILABLE_PROJECTS.include?(wiki.project)
  end

  def get_page_edits_count(page_title:, from_rev_id: nil, to_rev_id: nil)
    params = nil
    if from_rev_id && to_rev_id
      params = {
        from: from_rev_id,
        to: to_rev_id
      }
    end
    title = URI::DEFAULT_PARSER.escape(page_title.tr(' ', '_'))
    response = make_request('get', "page/#{title}/history/counts/edits", params)
    Oj.load(response.body).to_hashugar
  end

  class InvalidProjectError < StandardError
  end

  private

  def wiki_rest_server
    options = {
      url: @api_url,
      headers: {
        'Content-Type': 'application/json'
      }
    }
    connection = Faraday.new(options) do |faraday|
      faraday.response :raise_error
      faraday.adapter Faraday.default_adapter
    end
    connection.headers['User-Agent'] = Features.user_agent
    if (token = Rails.application.credentials.dig(:wiki, :token))
      connection.headers['Authorization'] = "Bearer #{token}"
    end
    connection
  end

  # Default backoff when the server doesn't send a Retry-After header.
  # Per Wikimedia's rate-limits policy, ≥5s is the floor expected of
  # well-behaved clients.
  DEFAULT_RETRY_AFTER_SECONDS = 5
  MAX_RETRY_AFTER_SECONDS = 60

  def make_request(action, url, params)
    tries ||= 5
    response = @client.send(action, url, params)
    response
  rescue StandardError => e
    tries -= 1
    if too_many_requests?(e)
      retry_after = e.response && e.response[:headers] &&
                    (e.response[:headers]['retry-after'] || e.response[:headers]['Retry-After'])
      wait_seconds = retry_after.to_i if retry_after
      wait_seconds = [wait_seconds || 0, DEFAULT_RETRY_AFTER_SECONDS].max
      wait_seconds = [wait_seconds, MAX_RETRY_AFTER_SECONDS].min
      # 0–3 s of jitter to de-correlate the retry herd; see
      # wiki_action_api.rb for the full rationale.
      wait_seconds += rand(0.0..3.0)
      unless Rails.env.test?
        ap "WikiRestApi / 429 Too Many Requests - waiting #{wait_seconds.round(2)}s, tries remaining: #{tries}"
        sleep wait_seconds
      end
      retry unless tries.zero?
    else
      unless Rails.env.test?
        ap url
        ap params
        ap e
      end
    end
    ap e.response
    raise e
  end

  # Faraday 2 raises Faraday::TooManyRequestsError (a ClientError
  # subclass) for 429s, so the previous `instance_of?(ClientError)`
  # check missed them. Match on the specific subclass when available
  # and fall back to the status-code check for older Faraday.
  def too_many_requests?(e)
    return true if defined?(Faraday::TooManyRequestsError) && e.is_a?(Faraday::TooManyRequestsError)
    return false unless e.is_a?(Faraday::ClientError)
    e.response.is_a?(Hash) && e.response[:status] == 429
  end
end

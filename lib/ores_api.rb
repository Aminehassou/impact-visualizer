# frozen_string_literal: true

# Gets data from ORES — Objective Revision Evaluation Service
# https://meta.wikimedia.org/wiki/Objective_Revision_Evaluation_Service
class OresApi
  include ApiErrorHandling

  # This is the maximum number of concurrent requests the app should make.
  # As of 2018-09-19, ORES policy is a max of 4 parallel connections per IP:
  # https://lists.wikimedia.org/pipermail/wikitech-l/2018-September/090835.html
  # Use this if we need to make parallel threaded requests.
  # CONCURRENCY = 4

  ORES_SERVER_URL = 'https://ores.wikimedia.org'
  REVS_PER_REQUEST = 50

  # All the wikis with an articlequality model as of 2018-09-18
  # https://ores.wikimedia.org/v3/scores/
  AVAILABLE_WIKIPEDIAS = %w[en eu fa fr ru simple tr].freeze

  def self.valid_wiki?(wiki)
    return true if wiki.project == 'wikidata'
    wiki.project == 'wikipedia' && AVAILABLE_WIKIPEDIAS.include?(wiki.language)
  end

  def initialize(wiki)
    raise InvalidProjectError unless OresApi.valid_wiki?(wiki)
    @project_code = wiki.project == 'wikidata' ? 'wikidata' + 'wiki' : wiki.language + 'wiki'
    @project_model = wiki.project == 'wikidata' ? 'itemquality' : 'articlequality'
  end

  def get_revision_data(rev_ids)
    url_query = query_url(rev_ids)
    response = ores_server.get(url_query)
    response_body = response.body
    ores_data = Oj.load(response_body)
    ores_data
  rescue StandardError => e
    log_error(e)
    return {}
  end

  class InvalidProjectError < StandardError
  end

  private

  def query_url(rev_ids)
    base_url = "/v3/scores/#{@project_code}/?models=#{@project_model}&features&revids="
    url = base_url + rev_ids.join('|')
    url
  end

  def ores_server
    conn = Faraday.new(url: ORES_SERVER_URL)
    conn.headers['User-Agent'] = Features.user_agent
    conn
  end
end

require 'json'
require 'sparql/client'
require 'rdf/turtle'
require 'umakadata/data_format'

class EndpointsController < ApplicationController

  include Umakadata::DataFormat

  before_action :set_endpoint, only: [:show]
  before_action :set_start_date, only: [:top, :show]

  def top
    @date = date_param
    @endpoints = Endpoint.crawled_before(@date).order(endpointlist_param)
  end

  def search
  end

  def show
    @date = date_param
  end

  def log
    evaluation = Evaluation.where(:id => params[:evaluation_id]).first
    @endpoint_id = evaluation.endpoint_id
    json = nil
    case(params[:name])
      when 'alive' then
        json = evaluation.alive_log
      when 'last_updated' then
        json = evaluation.last_updated_log
      when 'execution_time' then
        json = evaluation.execution_time_log
      when 'service_description'
        json = evaluation.service_description_log
      when 'void_ttl' then
        json = evaluation.void_ttl_log
      when 'subject_is_http_uri'
        json = evaluation.subject_is_http_uri_log
      when 'uri_provides_info'
        json = evaluation.uri_provides_info_log
      when 'contains_links'
        json = evaluation.contains_links_log
      when 'metadata_score' then
        json = evaluation.metadata_log
      when 'ontology_score' then
        json = evaluation.ontology_log
      when 'support_xml_format' then
        json = evaluation.support_content_negotiation_log
      when 'support_html_format' then
        json = evaluation.support_html_format_log
      when 'support_turtle_format' then
        json = evaluation.support_turtle_format_log
      when 'cool_uri_rate' then
        json = evaluation.cool_uri_rate_log
      when 'number_of_statements' then
        json = evaluation.number_of_statements_log
      else
        json = nil
    end

    begin
      @log = JSON.parse(json)
    rescue
      @log = json
    end

  end

  def scores
    count = {1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0}
    @endpoints = Endpoint.retrieved_at(date_param)
    @endpoints.each do |endpoint|
      rank = endpoint.evaluation.rank
      count[rank] += 1
    end
    render :json => count
  end

  def radar
    data = {
      data: Evaluation.rates(params[:id], params[:evaluation_id]),
      avg: Evaluation.avg_rates
    }
    respond_to do |format|
      format.any { render :json => data }
      format.json { render :json => data }
    end
  end

  def score_history
    labels = Array.new
    availability = Array.new
    freshness = Array.new
    operation = Array.new
    usefulness = Array.new
    validity = Array.new
    performance = Array.new
    rank = Array.new
    points = 30

    target_evaluation = Evaluation.lookup(params[:id], params[:evaluation_id])
    target_time = target_evaluation.retrieved_at.end_of_day
    evaluations = Evaluation.where(Evaluation.arel_table[:retrieved_at].lteq(target_time))
                            .where(endpoint_id: params[:id])
                            .order(retrieved_at: :desc)
                            .limit(points)
    dates = Evaluation.where(Evaluation.arel_table[:retrieved_at].lteq(target_time))
                      .group('date(retrieved_at)')
                      .order('date(retrieved_at) DESC')
                      .limit(points)
                      .pluck('date(retrieved_at)')
                      .reverse
    dates.each do |date|
      day_begin = Time.zone.local(date.year, date.month, date.day, 0, 0, 0)
      day_end = Time.zone.local(date.year, date.month, date.day, 23, 59, 59)
      evaluation = evaluations.where(retrieved_at: day_begin..day_end).first
      next if evaluation.nil?
      rates = Evaluation.calc_rates(evaluation)
      availability.push(rates[0])
      freshness.push(rates[1])
      operation.push(rates[2])
      usefulness.push(rates[3])
      validity.push(rates[4])
      performance.push(rates[5])
      rank.push(evaluation.score.presence || 0)
      labels.push date
    end

    while labels.size < points
      evaluation = Evaluation.new
      rates = Evaluation.calc_rates(evaluation)
      availability.unshift(rates[0])
      freshness.unshift(rates[1])
      operation.unshift(rates[2])
      usefulness.unshift(rates[3])
      validity.unshift(rates[4])
      performance.unshift(rates[5])
      rank.unshift(0)
      labels.unshift(labels.first - 1)
    end

    render :json => {
      :labels => labels,
      :datasets => [
        {
          label: 'Availability',
          data: availability
        },
        {
          label: 'Freshness',
          data: freshness
        },
        {
          label: 'Operation',
          data: operation
        },
        {
          label: 'Usefulness',
          data: usefulness
        },
        {
          label: 'Validity',
          data: validity
        },
        {
          label: 'Performance',
          data: performance
        },
        {
          label: 'Rank',
          data: rank
        }
      ]
    }
  end

  def alive
    count = { :alive => 0, :dead => 0 }
    @endpoints = Endpoint.retrieved_at(date_param)
    @endpoints.each do |endpoint|
      alive = endpoint.evaluation.alive
      alive ? count[:alive] += 1 : count[:dead] += 1
    end
    render :json => count
  end

  def service_descriptions
    count = { :true => 0, :false => 0 }
    @endpoints = Endpoint.crawled_at(date_param)
    @endpoints.each do |endpoint|
      sd = endpoint.evaluation.service_description
      sd.present? ? count[:true] += 1 : count[:false] += 1
    end
    render :json => count
  end


  def score_statistics
    last_crawled_date = date_param
    from = 9.days.ago(last_crawled_date)

    labels = Array.new
    averages = Array.new
    medians = Array.new

    time_series = Endpoint.score_statistics_from_to(from, last_crawled_date)
    average = time_series['average']
    median = time_series['median']
    (from.to_datetime..last_crawled_date.to_datetime).each {|datetime|
      date = datetime.strftime('%Y-%m-%d')
      labels.push date
      averages.push average.fetch(Date.parse(date), 0).round(1)
      medians.push median.fetch(Date.parse(date), 0)
    }

    render :json => {
      :labels => labels,
      :datasets => [
        {
          :label => 'Average',
          :data => averages
        },
        {
          :label => 'Median',
          :data => medians
        }
      ]
    }

  end

  def alive_statistics
    last_crawled_date = date_param
    from = 9.days.ago(last_crawled_date)

    labels = Array.new
    alive_data = Array.new

    time_series = Endpoint.alive_statistics_from_to(from, last_crawled_date)
    (from.to_datetime..last_crawled_date.to_datetime).each do |datetime|
      date = datetime.strftime('%Y-%m-%d')
      labels.push date
      alive_data.push time_series.fetch(Date.parse(date), 0).round(1)
    end

    render :json => {
      :labels => labels,
      :datasets => [
        {
          label: 'Alive',
          data: alive_data
        }
      ]
    }
  end

  def service_description_statistics
    last_crawled_date = date_param
    from = 9.days.ago(last_crawled_date)

    labels = Array.new
    have_data = Array.new

    time_series = Endpoint.sd_statistics_from_to(from, last_crawled_date)
    (from.to_datetime..last_crawled_date.to_datetime).each do |datetime|
      date = datetime.strftime('%Y-%m-%d')
      labels.push date
      have_data.push time_series.fetch(Date.parse(date), 0).round(1)
    end

    render :json => {
      :labels => labels,
      :datasets => [
        {
          label: 'Have',
          data: have_data
        }
      ]
    }
  end

  def score_ranking
    render json: Endpoint.crawled_before(date_param).order(endpointlist_param).pluck(:id, 'evaluations.id', :name, :url, :score)
  end

  private

    def render_404
      render :file=>"/public/404.html", :status=>'404 Not Found'
    end

    # Use callbacks to share common setup or constraints between actions.
    def set_endpoint
      @endpoint = Endpoint.find(params[:id])
      @evaluation = Evaluation.lookup(params[:id], params[:evaluation_id])
      if @evaluation.nil?
         render_404
         return
      end
      @prev_evaluation = Evaluation.previous(@endpoint[:id], @evaluation[:id])
      @next_evaluation = Evaluation.next(@endpoint[:id], @evaluation[:id])

      @cors = false
      if !@evaluation.response_header.blank?
        @evaluation.response_header.split(/\n/).each do |line|
          items = line.split(/\s*:\s*/)
          if items[0].downcase == 'access-control-allow-origin'
            @cors = true if items[1] == '*'
            break
          end
        end
      end

      @void = @evaluation.void_ttl
      @supported_language = JSON.parse(@evaluation.supported_language).join('<br/>') unless @evaluation.supported_language.nil?
      @linksets = JSON.parse(@evaluation.linksets) unless @evaluation.linksets.nil?
      @license = JSON.parse(@evaluation.license).join('<br/>') unless @evaluation.license.nil?
      @publisher = JSON.parse(@evaluation.publisher).join('<br/>') unless @evaluation.publisher.nil?
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def endpoint_params
      params.require(:endpoint).permit(:name, :url)
    end

    def date_param
      input_date = params[:date]
      if input_date.blank?
        if params[:id].blank?
          date = Endpoint.get_last_crawled_date
        else
          evaluation = Evaluation.lookup(params[:id], params[:evaluation_id])
          date = evaluation.created_at
        end
      else
        date = Time.zone.parse(input_date)
      end
    end

    def set_start_date
      evaluations = params[:id].nil? ? Evaluation.all : Evaluation.where(:endpoint_id => params[:id])
      oldest_evaluation = evaluations.order('created_at ASC').first
      @start_date = oldest_evaluation.created_at.strftime('%Y-%m-%d')
    end

    def endpointlist_param
      column = %w[name url score].include?(params[:column]) ? params[:column] : 'score'
      direction = %w[ASC DESC].include?(params[:direction]) ? params[:direction]
                                                            : %w[score].include?(params[:column]) || params[:column].blank? ? 'DESC'
                                                                                                                            : 'ASC'
      column + ' ' + direction
    end

end

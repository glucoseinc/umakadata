class Evaluation < ActiveRecord::Base

  belongs_to :endpoint

  def self.record(endpoint, retriever)
    self.transaction do
      self.where(endpoint_id: endpoint.id).update_all("latest = false")
      self.retrieve_and_record endpoint, retriever
    end
  end

  def self.retrieve_and_record(endpoint, retriever)
    eval = Evaluation.new
    eval.endpoint_id = endpoint.id

    eval.latest = true
    eval.alive = retriever.alive?

    if eval.alive
      self.retrieve_service_description(retriever, eval)
      self.retrieve_void(retriever, eval)
      self.retrieve_linked_data_rules(retriever, eval)
    end

    eval.alive_rate = Evaluation.calc_alive_rate(eval)
    eval.score = Evaluation.calc_score(eval)
    eval.rank  = Evaluation.calc_rank(eval.score)

    eval.response_time = retriever.response_time
    eval.cool_uri_rate = retriever.cool_uri_rate

    eval.support_turtle_format = retriever.check_content_negotiation(Yummydata::ContentType::TURTLE)
    eval.support_xml_format    = retriever.check_content_negotiation(Yummydata::ContentType::RDFXML)
    eval.support_html_format   = retriever.check_content_negotiation(Yummydata::ContentType::HTML)
    eval.support_content_negotiation = eval.support_turtle_format ||
                                       eval.support_xml_format ||
                                       eval.support_html_format

    eval.save!
  end

  def self.retrieve_service_description(retriever, eval)
    service_description = retriever.service_description
    eval.response_header     = service_description.response_header
    eval.service_description = service_description.text
  end

  def self.retrieve_void(retriever, eval)
    eval.void_uri            = retriever.well_known_uri
    eval.void_ttl            = retriever.void_on_well_known_uri
  end

  def self.retrieve_linked_data_rules(retriever, eval)
    eval.subject_is_uri      = retriever.uri_subject?
    eval.subject_is_http_uri = retriever.http_subject?
    eval.uri_provides_info   = retriever.uri_provides_info?
    eval.contains_links      = retriever.contains_links?
    eval.response_time       = retriever.response_time
  end

  def self.calc_alive_rate(eval)
    today = Time.zone.now
    first = 29.days.ago(Time.zone.local(today.year, today.month, today.day, 0, 0, 0))
    last = 1.days.ago(Time.zone.local(today.year, today.month, today.day, 23, 59, 59))
    count = self.where(endpoint_id: eval.endpoint_id, created_at: first..last).group(:alive).count
    count[true] ||= 0
    count[false] ||= 0
    total = count[true] + count[false] + 1.0
    alive = count[true] + (eval.alive? ? 1 : 0)
    percentage = (alive / total) * 100
    return percentage.round(1)
  end

  def self.calc_score(eval)
    score = 0

    score += 15 if eval.alive

    score += 15 if eval.service_description

    count = 0
    count += 1 if eval.subject_is_uri
    count += 1 if eval.subject_is_http_uri
    count += 1 if eval.uri_provides_info
    count += 1 if eval.contains_links
    score += (count / 4.0 * 100) / 4

    score += 25 if !eval.void_ttl.nil?
    return score
  end

  def self.calc_rank(score)
    return case
    when  0 <= score && score < 30 then 1
    when 30 <= score && score < 50 then 2
    when 50 <= score && score < 70 then 3
    when 70 <= score && score < 85 then 4
    when 85 <= score               then 5
    end
  end

  def self.rates(id)
    conditions = {'evaluations.endpoint_id': id, 'evaluations.latest': true}
    endpoint = Endpoint.includes(:evaluation).order('evaluations.score DESC').where(conditions).first
    evaluation = endpoint.evaluation.first
    return self.calc_rates(evaluation)
  end

  def self.avg_rates
    total = [0, 0, 0, 0, 0, 0]
    count = 0
    conditions = {'evaluations.latest': true}
    endpoints = Endpoint.includes(:evaluation).order('evaluations.score DESC').where(conditions).all
    endpoints.each do |endpoint|
      evaluation = endpoint.evaluation.first
      rates = self.calc_rates(evaluation)
      for i in 0..5 do
        total[i] += rates[i]
      end
      count += 1
    end
    avg = [0, 0, 0, 0, 0, 0]
    for i in 0..5 do
      avg[i] = total[i] / count
    end
    return avg
  end

  def self.calc_rates(eval)
    rates = [0, 0, 0, 0, 0, 0]

    # availability
    rates[0] += 100 if eval.alive

    #freshness
    rates[1] = 50

    #operation
    rates[2] += 50 unless eval.service_description.blank?
    rates[2] += 50 unless eval.void_ttl.blank?

    #usefulness
    rates[3] = 50

    #validity
    rates[4] += 40 unless eval.void_ttl.blank?
    rates[4] += 15 if eval.subject_is_uri
    rates[4] += 15 if eval.subject_is_http_uri
    rates[4] += 15 if eval.uri_provides_info
    rates[4] += 15 if eval.contains_links

    #performance
    rates[5] = 50

    return rates
  end

end

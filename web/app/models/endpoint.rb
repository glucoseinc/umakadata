class Endpoint < ActiveRecord::Base

  has_many :evaluations
  has_many :prefixes
  has_many :relations
  has_many :prefix_filters
  has_one :evaluation

  validates :name, uniqueness: true
  validates :url, uniqueness: true
  validates :url, format: /\A#{URI::regexp(%w(http https))}\z/, if: 'url.present?'
  validates :description_url, format: /\A#{URI::regexp(%w(http https))}\z/, if: 'description_url.present?'

  scope :created_at, ->(date) { where('evaluations.created_at': date) }

  def self.rdf_graph
    endpoints = self.thin_out_attributes
    UmakaRDF.build(endpoints)
  end

  def self.thin_out_attributes
    endpoints = []
    all.each do |endpoint|
      hash = endpoint.attributes
      hash['evaluation'] = endpoint.evaluation.attributes.select {|key, value| /_log$/ !~ key }
      endpoints << hash
    end
    endpoints
  end

  def self.to_jsonld
    self.rdf_graph.dump(:jsonld, prefixes: UmakaRDF.prefixes)
  end

  def self.to_rdfxml
    self.rdf_graph.dump(:rdfxml, prefixes: UmakaRDF.prefixes)
  end

  def self.to_ttl
    self.rdf_graph.dump(:ttl, prefixes: UmakaRDF.prefixes)
  end

  def self.to_pretty_json
    endpoints = self.thin_out_attributes
    JSON.pretty_generate(JSON.parse(endpoints.to_json))
  end

  after_save do
    if self.issue_id.nil?
      issue = GithubHelper.create_issue(self.name)
      self.update_column(:issue_id, issue[:number]) unless issue.nil?
    else
      GithubHelper.edit_issue(self.issue_id, self.name)
    end
    GithubHelper.add_labels_to_an_issue(self.issue_id, ['endpoints'])
  end

  after_destroy do
    GithubHelper.close_issue(self.issue_id) unless self.issue_id.nil?
  end

  def self.retrieved_at(date)
    self.joins(:evaluation).eager_load(:evaluation).where(evaluations: {retrieved_at: date.beginning_of_day..date.end_of_day})
  end

  def self.alive_statistics_latest_n(date, n)
    data = {}
    data['date'] = self.joins(:evaluation).select('date(evaluations.retrieved_at)').where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).group('date(evaluations.retrieved_at)').order('date(evaluations.retrieved_at) DESC').limit(n).pluck('date(evaluations.retrieved_at)')
    percentage_of_alive = '(count(evaluations.retrieved_at) * 1.0) / (select count(endpoints.id) from endpoints) * 100'
    data['alive'] = self.joins(:evaluation).where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).where(evaluations: {alive: true}).group('date(evaluations.retrieved_at)').limit(n).pluck("date(evaluations.retrieved_at),#{percentage_of_alive}").to_h
    data
  end

  def self.sd_statistics_latest_n(date, n)
    data = {}
    data['date'] = self.joins(:evaluation).select('date(evaluations.retrieved_at)').where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).group('date(evaluations.retrieved_at)').order('date(evaluations.retrieved_at) DESC').limit(n).pluck('date(evaluations.retrieved_at)')
    percentage_of_sd = '(count(evaluations.retrieved_at) * 1.0) / (select count(endpoints.id) from endpoints) * 100'
    data['sd'] = self.joins(:evaluation).where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).where.not('evaluations.service_description': [nil,'']).group('date(evaluations.retrieved_at)').limit(n).pluck("date(evaluations.retrieved_at),#{percentage_of_sd}").to_h
    data
  end

  def self.get_last_crawled_date
    endpoints = self.joins(:evaluation)
    start_or_end_datetime = endpoints.first.evaluations.order('created_at DESC').first.created_at
    end_or_start_datetime = endpoints.last.evaluations.order('created_at DESC').first.created_at
    start_or_end_date = start_or_end_datetime.strftime('%Y-%m-%d')
    end_or_start_date = end_or_start_datetime.strftime('%Y-%m-%d')
    if start_or_end_date == end_or_start_date
      Time.zone.parse(start_or_end_date)
    else
      date = endpoints.select('date(evaluations.created_at)').group('date(evaluations.created_at)').order('date(evaluations.created_at) DESC').limit(2)[1].date
      Time.zone.parse(date.to_s)
    end
  end

  def self.score_statistics_lastest_n(date, n)
    data = {}
    data['date'] = self.joins(:evaluation).select('date(evaluations.retrieved_at)').where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).group('date(evaluations.retrieved_at)').order('date(evaluations.retrieved_at) DESC').limit(n).pluck('date(evaluations.retrieved_at)')
    data['average'] = self.joins(:evaluation).where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).group('date(evaluations.retrieved_at)').limit(n).average('evaluations.score')
    data['median']  = self.joins(:evaluation).where(Evaluation.arel_table[:retrieved_at].lteq(date.end_of_day)).group('date(evaluations.retrieved_at)').limit(n).median('evaluations.score')
    data
  end

end

require "umakadata/criteria/liveness"
require "umakadata/criteria/service_description"
require "umakadata/criteria/linked_data_rules"
require "umakadata/criteria/void"
require "umakadata/criteria/execution_time"
require "umakadata/criteria/cool_uri"
require "umakadata/criteria/content_negotiation"
require "umakadata/criteria/metadata"
require "umakadata/criteria/basic_sparql"
require "umakadata/sparql_grammar"
require "umakadata/linkset"

module Umakadata
  class Retriever

    include ErrorHelper

    attr_reader :support_graph_clause, :retrieved_at

    def initialize(uri, retrieved_at)
      @uri = URI(uri)
      @retrieved_at = retrieved_at
      @support_graph_clause = Umakadata::SparqlGrammar.support_graph_clause?(@uri)
      @handler = @support_graph_clause ? Umakadata::GraphHandler.new(uri) : Umakadata::NoGraphHandler.new(uri)
    end

    include Umakadata::Criteria::Liveness
    def alive?(time_out = 30, logger: nil)
      super(@uri, time_out, logger: logger)
    end

    include Umakadata::Criteria::ServiceDescription
    def service_description(time_out = 30, logger: nil)
      super(@uri, time_out, logger: logger)
    end

    include Umakadata::Criteria::LinkedDataRules
    def http_subject?(number_of_statements, logger: nil)
      if number_of_statements.nil? or number_of_statements == 0
        logger.result = "We could not check whether Subjects in the endpoint are HTTP URI or not, since we did not know the number of statements. "
        return false
      end
      @handler.http_subject?(number_of_statements, logger: logger)
    end
    def uri_provides_info?(prefixes, logger: nil)
      @handler.uri_provides_info?(prefixes, logger: logger)
    end
    def contains_links?(prefixes, logger: nil)
      @handler.contains_links?(prefixes, logger: logger)
    end

    include Umakadata::Criteria::VoID
    def well_known_uri
      super(@uri)
    end
    def void_on_well_known_uri(time_out = 30, logger: nil)
      super(@uri, time_out, logger: logger)
    end

    include Umakadata::Criteria::ExecutionTime
    def execution_time(logger: nil)
      super(@uri, logger: logger)
    end

    include Umakadata::Criteria::CoolURI
    def cool_uri_rate(logger: nil)
      super(@uri, logger: logger)
    end

    include Umakadata::Criteria::ContentNegotiation
    def check_content_negotiation(prefix, content_type, logger: nil)
      @handler.check_content_negotiation(prefix, content_type, logger: logger)
    end

    include Umakadata::Criteria::Metadata
    def metadata(logger: nil)
      @handler.metadata(logger: logger)
    end
    def list_ontologies(metadata, logger: nil)
      @handler.list_ontologies(metadata, logger: logger)
    end
    def list_ontologies_in_LOV(metadata, logger: nil)
      @handler.list_ontologies_in_LOV(metadata, logger: logger)
    end
    def score_metadata(metadata, logger: nil)
      @handler.score_metadata(metadata, logger: logger)
    end
    def score_ontologies_for_endpoints(metadata, rdf_prefixes, logger: nil)
      @handler.score_ontologies_for_endpoints(metadata, rdf_prefixes, logger: logger)
    end
    def score_ontologies_for_LOV(metadata, lov, logger: nil)
      @handler.score_ontologies_for_LOV(metadata, lov, logger: logger)
    end

    def last_updated(service_description, void, logger: nil)
      log = Umakadata::Logging::Log.new
      logger.push log unless logger.nil?

      result = extract_dcterms_modified(service_description, :sd, log)
      return result unless result.nil?

      result = extract_dcterms_modified(void, :void, log)
      return result unless result.nil?

      log.result = 'The literal of dcterms:modified is not found in either Service Description or VoID'
      nil
    end

    def first_last(count, logger: nil)
      count_log = Umakadata::Logging::Log.new
      logger.push count_log unless logger.nil?
      if count.nil? || count == 0
        count_log.result = 'The latest statement is not found'
        return { first: nil, last: nil }
      end
      count_log.result = "#{count} statements are found"

      first_log = Umakadata::Logging::Log.new
      logger.push first_log unless logger.nil?
      sparql = Umakadata::Criteria::BasicSPARQL.new(@uri)
      first = sparql.nth_statement(0, logger: first_log)
      if first.nil?
        first_log.result = 'The first statement is not found'
      else
        first_log.result = 'The first statement is found'
      end

      last_log = Umakadata::Logging::Log.new
      logger.push last_log unless logger.nil?
      n = calc_near_last(count)
      last  = sparql.nth_statement(n > 1 ? n - 1 : 1, logger: last_log)
      if last.nil?
        last_log.result = "The #{n}th statement is not found"
      else
        last_log.result = "The #{n}th statement is found"
      end

      return { first: first, last: last }
    end

    def number_of_statements(logger: nil)
      sparql = Umakadata::Criteria::BasicSPARQL.new(@uri)
      return sparql.count_statements(logger: logger)
    end

    SD = 'http://www.w3.org/ns/sparql-service-description'.freeze
    def supported_language(service_description)
      supported_language = []
      data = service_description.data
      unless data.nil?
        sl = []
        data.each do |subject, predicate, object|
          if subject == RDF::URI(@uri)
            if predicate == RDF::URI("#{SD}#supportedLanguage")
              sl.push object.to_s.sub(/#{SD}#/, '') unless object.nil?
            end
          end
        end
        supported_language = sl.uniq
      end
      supported_language.to_json
    end

    include Umakadata::Linkset
    def linksets(void_ttl)
      void = triples(void_ttl)
      super(void).map{|linkset| linkset.to_s}
    end

    private
    def calc_near_last(count)
      tolerance = (count * 0.0005).ceil # 0.05% tolerance is obtained from Virtuoso (Life Science Dictionary)
      order_tolerance = Math.log10(tolerance).ceil
      count_minus_tolerance = count - tolerance
      digit_rounddown = 10 ** order_tolerance
      count_minus_tolerance.quo(digit_rounddown).floor * digit_rounddown
    end

    def extract_dcterms_modified(str, type, log)
      s = if type == :sd
            'Service Description'
          elsif type == :void
            'VoID'
          end
      local_log = Umakadata::Logging::Log.new
      log.push local_log
      statements = triples(str)
      unless statements.nil?
        time = []
        statements.each do |subject, predicate, object|
          if predicate == RDF::URI("http://purl.org/dc/terms/modified")
            time.push Time.parse(object.to_s) rescue time.push nil
          end
        end
        dcterms_modified = time.compact.max
        unless dcterms_modified.nil?
          log.result = 'The literal of dcterms:modified is found in ' + s
          local_log.result = "dcterms:modified is #{dcterms_modified}"
          return { date: dcterms_modified, source: s }
        end
      end
      local_log.result = 'The literal of dcterms:modified is not found in ' + s
      nil
    end

  end
end

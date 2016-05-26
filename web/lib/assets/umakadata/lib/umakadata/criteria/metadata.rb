require 'json'
require 'sparql/client'
require 'umakadata/error_helper'
require 'umakadata/http_helper'
require 'umakadata/sparql_helper'
require 'umakadata/logging/criteria_log'


module Umakadata
  module Criteria
    module Metadata

      REGEXP = /<title>(.*)<\/title>/

      include Umakadata::ErrorHelper

      SKIP_GRAPH_LIST = [
        'http://www.openlinksw.com/schemas/virtrdf#'
      ]

      COMMON_ONTOLOGIES = [
        'http://www.w3.org/2000/01/rdf-schema',
        'http://www.w3.org/1999/02/22-rdf-syntax-ns',
        'http://www.socrata.com/rdf/terms',
        'http://www.w3.org/2003/01/geo/wgs84_pos',
        'http://xmlns.com/foaf/0.1/',
        'http://www.w3.org/2002/07/owl',
        'http://purl.org/dc/elements/1.1/',
        'http://purl.org/dc/terms/',
        'http://www.w3.org/2000/10/swap/pim/usps',
        'http://dublincore.org/documents/dcmi-box/',
        'http://www.territorio.provincia.tn.it/geodati/ontology/',
        'http://www.w3.org/2004/02/skos/core',
      ]

      def metadata(uri, logger: nil)
        graphs = self.list_of_graph_uris(uri, logger: logger)
        metadata = {}
        if graphs.empty?
          return metadata
        end

        graphs.each do |graph|
          classes_log = Umakadata::Logging::CriteriaLog.new
          classes = self.classes_on_graph(uri, graph, logger: classes_log)
          labels_log = Umakadata::Logging::CriteriaLog.new
          labels = list_of_labels_of_classes(uri, graph, classes, logger: labels_log)
          datatypes_log = Umakadata::Logging::CriteriaLog.new
          datatypes = self.list_of_datatypes(uri, graph, logger: datatypes_log)
          properties_log = Umakadata::Logging::CriteriaLog.new
          properties = self.list_of_properties_on_graph(uri, graph, logger: properties_log)
          metadata[graph] = {
            classes: classes,
            labels: labels,
            datatypes: datatypes,
            properties: properties,
            classes_log: classes_log,
            labels_log: labels_log,
            datatypes_log: datatypes_log,
            properties_log: properties_log
          }
        end

        return metadata
      end

      def score_metadata(metadata, logger: nil)
        score_proc = lambda do |graph, data|
          graph_log = Umakadata::Logging::CriteriaLog.new unless logger.nil?
          logger.push graph_log unless graph_log.nil?

          total_score = 0
          classes_log = data[:classes_log]
          graph_log.push classes_log unless logger.nil?
          score = data[:classes].empty? ? 0 : 25
          total_score += score
          classes_log.result = "Classes score: #{score}"

          labels_log = data[:labels_log]
          graph_log.push labels_log unless logger.nil?
          score = data[:labels].empty? ? 0 : 25
          total_score += score
          labels_log.result = "Labels score: #{score}"

          datatypes_log = data[:datatypes_log]
          graph_log.push datatypes_log unless logger.nil?
          score = data[:datatypes].empty? ? 0 : 25
          total_score += score
          datatypes_log.result = "Datatypes score: #{score}"

          properties_log = data[:properties_log]
          graph_log.push properties_log unless logger.nil?
          score = data[:properties].empty? ? 0 : 25
          total_score += score
          properties_log.result = "Properties score: #{score}"

          graph_log.result = "Graph: #{graph}"
          total_score
        end
        self.score_each_graph(metadata, score_proc)
      end

      def score_ontologies(metadata, logger: nil)
        score_proc = lambda do |graph, data|
          graph_log = Umakadata::Logging::CriteriaLog.new unless logger.nil?
          logger.push graph_log unless graph_log.nil?

          properties_log = data[:properties_log]
          graph_log.push properties_log unless logger.nil?
          graph_log.result = "Graph: #{graph}"

          if data[:properties].empty?
            score =  0
            properties_log.result = "Properties score: #{score}"
            return score
          end
          ontologies = self.ontologies(data[:properties])
          commons = ontologies.count{ |ontology| COMMON_ONTOLOGIES.include?(ontology) }

          score = commons.to_f / ontologies.count.to_f * 100.0
          properties_log.result = "Properties score: #{score} (#{commons} / #{ontologies.count} * 100)"
          return score
        end
        self.score_each_graph(metadata, score_proc)
      end

      def score_vocabularies(metadata, logger: nil)
        score_proc = lambda do |graph, data|
          graph_log = Umakadata::Logging::CriteriaLog.new unless logger.nil?
          logger.push graph_log unless graph_log.nil?
          graph_log.result = "Graph: #{graph}"

          properties_log = data[:properties_log]
          graph_log.push properties_log unless logger.nil?

          count = data[:properties].count
          properties_log.result = "Properties count: #{count}"

          return count
        end
        self.score_each_graph(metadata, score_proc)
      end

      def ontologies(properties)
        ontologies = []
        properties.each do |uri|
          uri = uri.to_s
          if uri.include?('#')
            ontologies.push uri.split('#')[0]
          else
            ontologies.push /^(.*\/).*?$/.match(uri)[1]
          end
        end
        return ontologies.uniq
      end

      def score_each_graph(metadata, score_proc)
        return 0 if metadata.nil? || metadata.empty?

        score_list = []
        metadata.each do |graph, data|
          next if SKIP_GRAPH_LIST.include?(graph.to_s)
          score_list.push(score_proc.call(graph, data))
        end

        return 0 if score_list.empty?
        return score_list.inject(0.0) { |r, i| r += i } / score_list.size
      end

      def list_of_graph_uris(uri, logger: nil)
        query = <<-SPARQL
SELECT DISTINCT ?g
WHERE {
  GRAPH ?g
  { ?s ?p ?o. }
}
SPARQL
        results = Umakadata::SparqlHelper.query(uri, query, logger: logger)
        return [] if results.nil?
        results.map { |solution| solution[:g] }
      end

      def classes_on_graph(uri, graph, logger: nil)
        classes = []
        classes += self.list_of_classes_on_graph(uri, graph, logger: logger)
        classes += self.list_of_classes_having_instances(uri, graph, logger: logger)
        classes.uniq!
        return classes
      end

      def list_of_classes_on_graph(uri, graph, logger: nil)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT DISTINCT ?c
FROM <#{graph}>
WHERE {
  { ?c rdf:type rdfs:Class. }
  UNION
  { [] rdf:type ?c. }
  UNION
  { [] rdfs:domain ?c. }
  UNION
  { [] rdfs:range ?c. }
  UNION
  { ?c rdfs:subclassOf []. }
  UNION
  { [] rdfs:subclassOf ?c. }
}
LIMIT 100
SPARQL
        results = Umakadata::SparqlHelper.query(uri, query, logger: logger)
        return [] if results.nil?
        results.map { |solution| solution[:c] }
      end

      def list_of_classes_having_instances(uri, graph, logger: nil)
        query = <<-SPARQL
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT DISTINCT ?c
FROM <#{graph}>
WHERE { [] rdf:type ?c. }
SPARQL
        results = Umakadata::SparqlHelper.query(uri, query, logger: logger)
        return [] if results.nil?
        results.map { |solution| solution[:c] }
      end

      def list_of_labels_of_a_class(client, graph, cls)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?label
FROM <#{graph}>
WHERE{ <#{cls}> rdfs:label ?label. }
SPARQL
        results = self.query_metadata(client, query)
        return [] if results.nil?
        results.map { |solution| solution[:label] }
      end

      def list_of_labels_of_classes(uri, graph, classes, logger: nil)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?c ?label
WHERE {
    graph <#{graph}> {
      ?c rdfs:label ?label.
      filter (
        ?c IN (<#{classes.join('>,<')}>)
      )
    }
}
SPARQL
        results = Umakadata::SparqlHelper.query(uri, query, logger: logger)
        return [] if results.nil?
        results.map { |solution| solution[:label] }
      end

      def number_of_instances_of_class_on_a_graph(client, graph, cls)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT (count(DISTINCT ?i)  AS ?num)
  FROM <#{graph}>
WHERE{
  { ?i rdf:type <#{cls}>. }
  UNION
  { [] ?p ?i. ?p rdfs:range <#{cls}>. }
  UNION
  { ?i ?p []. ?p rdfs:domain <#{cls}>. }
}
SPARQL
        results = self.query_metadata(client, query)
        return 0 if results.nil?
        return results[0][:num]
      end

      def list_of_properties_on_graph(uri, graph, logger: nil)
        query = <<-SPARQL
SELECT DISTINCT ?p
        FROM <#{graph}>
WHERE{
        ?s ?p ?o.
}
SPARQL
        results = Umakadata::SparqlHelper.query(uri, query, logger: logger)
        return [] if results.nil?
        results.map { |solution| solution[:p] }
      end

      def list_of_domain_classes_of_property_on_graph(client, graph, property)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?d
FROM <#{graph}>
WHERE {
  <#{property}> rdfs:domain ?d.
}
SPARQL
        results = self.query_metadata(client, query)
        return [] if results.nil?
        results.map { |solution| solution[:d] }
      end

      def list_of_range_classes_of_property_on_graph(client, graph, property)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?r
FROM <#{graph}>
WHERE{
  <#{property}> rdfs:range ?r.
}
SPARQL
        results = self.query_metadata(client, query)
        return [] if results.nil?
        results.map { |solution| solution[:d] }
      end

      def list_of_class_class_relationships(client, graph, property)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT DISTINCT ?d ?r
FROM <#{graph}>
WHERE{
        ?i <#{property}> ?o.
        OPTIONAL{ ?i rdf:type ?d.}
        OPTIONAL{ ?o rdf:type ?r.}
}
SPARQL
        results = self.query_metadata(client, query)
        return [] if results.nil?
        results.map { |solution| [ solution[:d], solution[:r] ] }
      end

      def list_of_class_datatype_relationships(client, graph, property)
        query = <<-SPARQL
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT DISTINCT ?d (datatype(?o) AS ?ldt)
FROM <#{graph}>
WHERE{
    ?i <#{property}> ?o.
    OPTIONAL{ ?i rdf:type ?d.}
    FILTER(isLiteral(?o))
}
SPARQL
        results = self.query_metadata(client, query)
        return [] if results.nil?
        results.map { |solution| [ solution[:d], solution[:ldt] ] }
      end

      def number_of_elements1(client, graph, property, domain, range)
        query = <<-SPARQL
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT (count(?i) AS ?numTriples) (count(DISTINCT ?i) AS ?numDomIns) (count(DISTINCT ?o) AS ?numRanIns)
FROM <#{graph}>
WHERE {
  SELECT DISTINCT ?i ?o WHERE {
    ?i <#{property}> ?o.
    ?i rdf:type <#{domain}>.
    ?o rdf:type <#{range}>.
  }
}
SPARQL
        results = self.query_metadata(client, query)
        return nil if results.nil?
        return [ results[0][:numTriples], results[0][:numDomIns], results[0][:numRanIns] ]
      end

      def number_of_elements2(client, graph, property, datatype)
        query = <<-SPARQL
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT (count(?i) AS ?numTriples) (count(DISTINCT ?i) AS ?numDomIns) (count(DISTINCT ?o) AS ?numRanIns)
        FROM <#{graph}>
WHERE{
  SELECT DISTINCT ?i ?o WHERE{
    ?i <#{property}> ?o.
    ?i rdf:type ?d.
    FILTER( datatype(?o) = <#{datatype}> )
  }
}
SPARQL
        results = self.query_metadata(client, query)
        return nil if results.nil?
        return [ results[0][:numTriples], results[0][:numDomIns], results[0][:numRanIns] ]
      end

      def number_of_elements3(client, graph, property)
query = <<-SPARQL
SELECT (count(?i) AS ?numTriples) (count(DISTINCT ?i) AS ?numDomIns) (count(DISTINCT ?o) AS ?numRanIns)
FROM <#{graph}>
WHERE{
   ?i <#{property}> ?o.
}
SPARQL
        results = self.query_metadata(client, query)
        return nil if results.nil?
        return [ results[0][:numTriples], results[0][:numDomIns], results[0][:numRanIns] ]
      end

      def number_of_elements4(client, graph, property)
        query = <<-SPARQL
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT (count(DISTINCT ?i) AS ?numDomIns) (count(?i) AS ?numTriplesWithDom)
FROM <#{graph}>
WHERE {
  SELECT DISTINCT ?i ?o
  WHERE{
    ?i <#{property}> ?o.
    ?i rdf:type ?d.
  }
}
SPARQL
        results = self.query_metadata(client, query)
        return nil if results.nil?
        return [ results[0][:numDomIns], results[0][:numTriplesWithDom] ]
      end

      def number_of_elements5(client, graph, property)
        query = <<-SPARQL
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT (count(DISTINCT ?o) AS ?numRanIns) (count(?o) AS ?numTriplesWithRan)
FROM <#{graph}>
WHERE {
  SELECT DISTINCT ?i ?o
  WHERE{
    ?i <#{property}> ?o.
    ?o rdf:type ?r.
  }
}
SPARQL
        results = self.query_metadata(client, query)
        return nil if results.nil?
        return [ results[0][:numRanIns], results[0][:numTriplesWithRan] ]
      end

      def number_of_elements6(client, graph, property)
        query = <<-SPARQL
SELECT (count(DISTINCT ?o) AS ?numRanIns) (count(?o) AS ?numTriplesWithRan)
FROM <#{graph}>
WHERE {
  SELECT DISTINCT ?i ?o
  WHERE{
    ?i <#{property}> ?o.
    FILTER(isLiteral(?o))
  }
}
SPARQL
        results = self.query_metadata(client, query)
        return nil if results.nil?
        return [ results[0][:numRanIns], results[0][:numTriplesWithRan] ]
      end

      def list_of_properties_domains_ranges(client, graph)
        query = <<-SPARQL
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT ?p ?d ?r
        FROM <#{graph}>
WHERE{
  ?p rdfs:domain ?d.
  ?p rdfs:range ?r.
}
SPARQL
        results = self.query_metadata(client, query)
        return [] if results.nil?
        results.map { |solution| [ solution[:p], solution[:d], solution[:r] ] }
      end

      def list_of_datatypes(uri, graph, logger: nil)
        query = <<-SPARQL
SELECT DISTINCT (datatype(?o) AS ?ldt)
FROM <#{graph}>
WHERE{
  [] ?p ?o.
  FILTER(isLiteral(?o))
}
SPARQL
        results = Umakadata::SparqlHelper.query(uri, query, logger: logger)
        return [] if results.nil?
        results.map { |solution| solution[:ldt] }
      end

      def query_metadata(client, query)
        begin
          results = client.query(query)
          if results.nil?
            client.response(query)
            set_error('Endpoint URI is different from actual URI in executing query')
            return nil
          end
        rescue SPARQL::Client::MalformedQuery => e
          set_error("Query: #{query}, Error: #{e.message}")
          return nil
        rescue SPARQL::Client::ClientError, SPARQL::Client::ServerError => e
          message = e.message.scan(REGEXP)[0]
          if message.nil?
            result = e.message.scan(/"datatype":\s"(.*\n)/)[0]
            if result.nil?
              message = ''
            else
              message = result[0].chomp
            end
          end
          set_error("Query: #{query}, Error: #{message}")
          return nil
        rescue => e
          set_error("Query: #{query}, Error: #{e.to_s}")
          return nil
        end

        return results
      end

    end
  end
end

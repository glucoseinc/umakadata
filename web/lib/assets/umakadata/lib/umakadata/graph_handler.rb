require "umakadata/criteria/execution_time"
require "umakadata/criteria/content_negotiation"
require "umakadata/criteria/linked_data_rules"

module Umakadata
  class GraphHandler

    def initialize(uri)
      @uri = URI(uri)
    end

    include Umakadata::Criteria::ContentNegotiation
    def check_content_negotiation(content_type, logger: nil)
      super(@uri, content_type, logger: logger)
    end

    include Umakadata::Criteria::LinkedDataRules
    def http_subject?(logger: nil)
      super(@uri, logger: logger)
    end

    def uri_provides_info?(logger: nil)
      super(@uri, logger: logger)
    end

    def contains_links?(logger: nil)
      super(@uri, logger: logger)
    end

    include Umakadata::Criteria::Metadata
    def metadata(logger: nil)
      super(@uri, logger: logger)
    end
    def score_metadata(metadata, logger: nil)
      super(metadata, logger: logger)
    end
    def score_ontologies(metadata, logger: nil)
      super(metadata, logger: logger)
    end
    def score_vocabularies(metadata, logger: nil)
      super(metadata, logger: logger)
    end

  end
end

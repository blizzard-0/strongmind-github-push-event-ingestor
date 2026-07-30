module Github
  EnrichmentResult = Data.define(:status, :record, :reason, :fetched) do
    def fetched?
      status == :fetched
    end

    def reused?
      status == :reused
    end

    def skipped?
      status == :skipped
    end
  end
end

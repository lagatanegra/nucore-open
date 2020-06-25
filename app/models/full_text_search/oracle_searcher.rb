module FullTextSearch

  class OracleSearcher < BaseSearcher

    def search(fields, query)
      return @scope.none if query.blank?

      query_elements = query.to_s.split
      # By wrapping each portion in {}, it escapes what's inside so it handles special
      # characters and other reserved words
      # https://docs.oracle.com/cd/B10501_01/text.920/a96518/cqspcl.htm#20741
      formatted_query = query_elements
        .map { |s| s.gsub(/[{}]/, "") } # remove any existing curly braces
        .map { |s| "{#{s}}" }
        .join(",")
      # If we leave the label out `:label`, we end up with duplicate labels which Oracle doesn't like.
      # If we don't handle the `order` ourselves, then AR's `or` complains about incompatible `ORDER BY`s.
      array = Array(fields)
      relation = array.map.with_index { |field, i| @scope.contains("#{arel_table.name}.#{field}", formatted_query, label: i).unscope(:order) }.inject(&:or)
      array.length.times.inject(relation) do |relation, label|
        relation.order(Arel.sql("SCORE(#{label}) DESC"))
      end
    end

  end

end

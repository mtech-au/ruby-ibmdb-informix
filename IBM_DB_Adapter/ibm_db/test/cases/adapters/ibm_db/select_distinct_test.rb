# frozen_string_literal: true

require "cases/helper"

module ActiveRecord
  # Relation#distinct on Informix. The IDS SELECT visitor writes SKIP/FIRST
  # itself and then visits the core without its SELECT keyword; it dropped
  # the core's set quantifier, so .distinct was silently ignored and every
  # duplicate row came back.
  class IBM_DBSelectDistinctTest < ActiveRecord::IBM_DBTestCase
    self.use_transactional_tests = false

    TABLE = "ibm_db_distinct_samples"

    class Sample < ActiveRecord::Base
      self.table_name = TABLE
    end

    setup do
      @connection = ActiveRecord::Base.lease_connection
      @connection.drop_table(TABLE, if_exists: true)
      @connection.execute("CREATE TABLE #{TABLE} (id INT PRIMARY KEY, code CHAR(8))")
      [[1, "a"], [2, "a"], [3, "b"], [4, "b"], [5, "c"]].each do |id, code|
        @connection.execute("INSERT INTO #{TABLE} VALUES (#{id}, '#{code}')")
      end
      Sample.reset_column_information
    end

    teardown do
      @connection.drop_table(TABLE, if_exists: true)
    end

    def test_distinct_emits_distinct
      assert_match(/\ASELECT DISTINCT /, Sample.select(:code).distinct.to_sql)
    end

    def test_distinct_follows_skip_and_first
      sql = Sample.select(:code).distinct.order(:code).limit(2).offset(1).to_sql

      assert_match(/\ASELECT SKIP 1 FIRST 2 DISTINCT /, sql)
    end

    def test_distinct_removes_duplicate_rows
      assert_equal %w[a b c], Sample.select(:code).distinct.order(:code).map { |s| s.code.strip }
    end

    def test_distinct_pluck
      assert_equal %w[a b c], Sample.distinct.order(:code).pluck(:code).map(&:strip)
    end

    def test_distinct_with_skip_and_first
      assert_equal %w[b c], Sample.distinct.order(:code).limit(2).offset(1).pluck(:code).map(&:strip)
    end

    def test_distinct_count
      assert_equal 3, Sample.distinct.count(:code)
    end

    def test_without_distinct_keeps_duplicates
      assert_equal 5, Sample.pluck(:code).size
    end
  end
end

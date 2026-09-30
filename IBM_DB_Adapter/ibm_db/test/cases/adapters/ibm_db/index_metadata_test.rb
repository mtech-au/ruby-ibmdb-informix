# frozen_string_literal: true

require "cases/helper"
require "minitest/mock"

module ActiveRecord
  # Regression tests for #indexes raising
  #   "An unexpected error occurred during retrieval of index metadata:
  #    undefined method 'downcase' for nil"
  # on every Informix ODBC connection. The Informix CSDK returns INDEX_QUALIFIER
  # (SQLStatistics column 5) as NULL on every row, and #indexes downcased it
  # unconditionally. Rails reaches #indexes through schema_cache.indexes from
  # UniquenessValidator#covered_by_unique_index?, so saving any persisted record
  # with a uniqueness validation failed.
  class IBM_DBIndexMetadataTest < ActiveRecord::IBM_DBTestCase
    self.use_transactional_tests = false

    TABLE = "ibm_db_index_samples"

    # SQLStatistics result set as Informix ODBC returned it for sys5tbl6 on a
    # live ERP: a leading SQL_TABLE_STAT row with no INDEX_NAME, then one row
    # per index key column, every one with a nil INDEX_QUALIFIER. The last row
    # stands in for an expression index key, which has no COLUMN_NAME.
    # Columns: TABLE_CAT, TABLE_SCHEM, TABLE_NAME, NON_UNIQUE, INDEX_QUALIFIER,
    # INDEX_NAME, TYPE, ORDINAL_POSITION, COLUMN_NAME, ASC_OR_DESC
    INFORMIX_STATISTICS_ROWS = [
      [nil, "informix", "sys5tbl6", nil, nil, nil,              0, nil, nil,            nil],
      [nil, "informix", "sys5tbl6", 0,   nil, "sys5tbl6_rowid", 3, 1,   "row_id",       "A"],
      [nil, "informix", "sys5tbl6", 0,   nil, "sys5tbl6a",      3, 1,   "sys_tbl_type", "A"],
      [nil, "informix", "sys5tbl6", 0,   nil, "sys5tbl6a",      3, 2,   "sys_tbl_code", "A"],
      [nil, "informix", "sys5tbl6", 1,   nil, "sys5tbl6_expr",  3, 1,   nil,            "A"]
    ].freeze

    setup do
      @connection = ActiveRecord::Base.lease_connection
    end

    def test_indexes_tolerates_nil_index_qualifier_and_column_name
      indexes = with_statistics_rows(INFORMIX_STATISTICS_ROWS) { @connection.indexes("sys5tbl6") }

      assert_equal %w[sys5tbl6_rowid sys5tbl6a], indexes.map(&:name)
    end

    def test_indexes_groups_composite_columns_when_every_qualifier_is_nil
      indexes = with_statistics_rows(INFORMIX_STATISTICS_ROWS) { @connection.indexes("sys5tbl6") }
      composite = indexes.find { |index| index.name == "sys5tbl6a" }

      assert composite.unique
      assert_equal %w[sys_tbl_type sys_tbl_code], composite.columns
    end

    # The same path against the live server, so the real driver's result shape
    # (qualifier or not, TABLE_STAT row or not) still round-trips.
    def test_indexes_reports_a_composite_unique_index_from_the_server
      @connection.drop_table(TABLE, if_exists: true)
      @connection.create_table(TABLE) do |t|
        t.string :kind, limit: 10
        t.string :code, limit: 10
        t.integer :value
      end
      @connection.add_index TABLE, [:kind, :code], unique: true, name: "ibm_db_idx_kind_code"
      @connection.add_index TABLE, :value, name: "ibm_db_idx_value"

      indexes = @connection.indexes(TABLE).index_by(&:name)

      assert indexes["ibm_db_idx_kind_code"].unique
      assert_equal %w[kind code], indexes["ibm_db_idx_kind_code"].columns
      assert_not indexes["ibm_db_idx_value"].unique
      assert_equal %w[value], indexes["ibm_db_idx_value"].columns
    ensure
      @connection.drop_table(TABLE, if_exists: true)
    end

    private
      # Feeds canned SQLStatistics rows through #indexes, with no primary key.
      def with_statistics_rows(rows, &block)
        results = { pk: [], stats: rows.dup }

        IBM_DB.stub(:primary_keys, :pk) do
          IBM_DB.stub(:statistics, :stats) do
            IBM_DB.stub(:fetch_array, ->(stmt) { results[stmt].shift }) do
              IBM_DB.stub(:getErrormsg, nil) do
                IBM_DB.stub(:free_stmt, true, &block)
              end
            end
          end
        end
      end
  end
end

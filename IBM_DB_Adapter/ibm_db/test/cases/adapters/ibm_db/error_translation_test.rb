# frozen_string_literal: true

require "cases/helper"
require "minitest/mock"

module ActiveRecord
  # Informix SQLCODEs mapped to Active Record errors, and fetch failures that
  # used to come back as data.
  #
  # Messages are in the shape the Informix ODBC build produces, measured on
  # IDS 12.10 and 14.10: a row another session holds locked fails with
  #   -244 ISAM -107  (SET LOCK MODE TO NOT WAIT, the server default)
  #   -243 ISAM -154  (SET LOCK MODE TO WAIT n, once n seconds have passed)
  # and for a SELECT it fails at SQLFetch, not at execute.
  class IBM_DBErrorTranslationTest < ActiveRecord::IBM_DBTestCase
    self.use_transactional_tests = false

    PREFIX = "[Informix][Informix ODBC Driver][Informix]"
    SQL = "SELECT FIRST 1 tabid FROM systables"

    setup do
      @connection = ActiveRecord::Base.lease_connection
    end

    def test_lock_failures_map_to_lock_wait_timeout
      [
        "Could not do a physical-order read to fetch next row. SQLCODE=-244 ISAM=-107",
        "Could not position within a table (informix.t). SQLCODE=-243 ISAM=-154",
        "Could not position within a table via an index. SQLCODE=-245 ISAM=-143",
        "Could not position within a table (informix.t). SQLCODE=-243 ISAM=-113",
        "Cannot read record that is locked by another user. SQLCODE=-233"
      ].each do |message|
        assert_instance_of LockWaitTimeout, translate(message), message
      end
    end

    # The DRDA build has no ISAM code in the message: keep treating these as
    # lock failures, which is what they nearly always are.
    def test_position_errors_without_an_isam_code_map_to_lock_wait_timeout
      assert_instance_of LockWaitTimeout, translate("Could not do a physical-order read. SQLCODE=-244")
    end

    def test_position_errors_with_a_non_lock_isam_code_stay_statement_invalid
      error = translate("Could not do a physical-order read to fetch next row. SQLCODE=-244 ISAM=-104")

      assert_instance_of StatementInvalid, error
    end

    def test_unique_violations_map_to_record_not_unique
      assert_instance_of RecordNotUnique, translate("Unique constraint (informix.u1) violated. SQLCODE=-268 ISAM=-100")
      assert_instance_of RecordNotUnique,
                         translate("Could not insert new row - duplicate value in a UNIQUE INDEX column. SQLCODE=-239 ISAM=-100")
    end

    # DB2 uses -243..-245 for unrelated errors (sensitive cursors, ambiguous
    # function), so the Informix mapping must not apply there.
    def test_informix_codes_are_not_mapped_on_db2
      informix = @connection.instance_variable_get(:@servertype)
      @connection.instance_variable_set(:@servertype, ConnectionAdapters::IBM_DB2_LUW.new(@connection, false))

      assert_instance_of StatementInvalid, translate("SQL0244N SQLCODE=-244")
      assert_instance_of StatementInvalid, translate("SQLCODE=-239")
    ensure
      @connection.instance_variable_set(:@servertype, informix)
    end

    # The driver reports a failed fetch with rb_throw. The adapter used to call
    # getErrormsg a second time, get the (empty) next diag record, and return
    # the text ": Failed to retrieve data: ..." in place of the rows, which
    # select_value turned into ":".
    def test_a_failed_fetch_raises_from_select_value
      error = with_failing_fetch { assert_raises(LockWaitTimeout) { @connection.select_value(SQL) } }

      assert_includes error.message, "SQLCODE=-244 ISAM=-107"
    end

    def test_a_failed_fetch_raises_from_select_rows
      with_failing_fetch { assert_raises(LockWaitTimeout) { @connection.select_rows(SQL) } }
    end

    def test_a_failed_fetch_raises_from_a_query_with_binds
      binds = [Relation::QueryAttribute.new("tabid", 1, Type::Integer.new)]

      with_failing_fetch do
        assert_raises(LockWaitTimeout) { @connection.exec_query("#{SQL} WHERE tabid = ?", "SQL", binds) }
      end
    end

    private
      def translate(message)
        @connection.send(:translate_exception, RuntimeError.new(message),
                         message: "RuntimeError: #{PREFIX}#{message}", sql: SQL, binds: [])
      end

      def with_failing_fetch(&block)
        failing_fetch = ->(*) { throw :"Fetch Failure: #{PREFIX}Could not do a physical-order read. SQLCODE=-244 ISAM=-107" }

        IBM_DB.stub(:fetch_array, failing_fetch) { IBM_DB.stub(:fetch_assoc, failing_fetch, &block) }
      end
  end
end

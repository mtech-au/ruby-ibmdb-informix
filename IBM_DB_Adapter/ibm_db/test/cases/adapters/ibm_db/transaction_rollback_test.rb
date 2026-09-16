# frozen_string_literal: true

require "cases/helper"
require "minitest/mock"

module ActiveRecord
  # Regression tests for an open transaction being silently discarded, which
  # made ActiveRecord::Rollback a no-op and let half-finished work commit.
  #
  # The chain, as reproduced against a live Informix (IDS) ODBC connection:
  #
  #   * IBM_DB.active used the DB2 CLI attribute SQL_ATTR_PING_DB, which the
  #     Informix CSDK ODBC driver does not implement, so #active? was false on
  #     every healthy connection;
  #   * #raw_execute called verify! from inside its with_raw_connection block,
  #     bypassing the reconnect_can_restore_state? guard that is the only thing
  #     stopping Active Record from reconnecting mid-transaction;
  #   * verify! therefore ran reconnect!(restore_transactions: true) on every
  #     statement. Once a write had dirtied the transaction, restorable? was
  #     false, so reset_transaction swapped in a fresh TransactionManager and
  #     never restored the old one.
  #
  # Active Record then believed no transaction was open: the next save! opened
  # a new top-level transaction and committed it, and the outer rollback rolled
  # back nothing.
  class IBM_DBTransactionRollbackTest < ActiveRecord::IBM_DBTestCase
    self.use_transactional_tests = false

    TABLE = "ibm_db_txn_rollback_samples"

    class Sample < ActiveRecord::Base
      self.table_name = TABLE
    end

    setup do
      @connection = ActiveRecord::Base.lease_connection
      @connection.drop_table(TABLE, if_exists: true)
      @connection.create_table(TABLE) { |t| t.integer :value }
      Sample.reset_column_information
    end

    teardown do
      @connection.drop_table(TABLE, if_exists: true)
    end

    # The adapter keeps its own @connection ivar. Active Record owns
    # @raw_connection: with_raw_connection yields it, seconds_since_last_activity
    # needs it, and while it is nil with_raw_connection calls connect! (and so
    # verify!) on every single statement. AbstractAdapter#initialize resets it
    # to nil, so the adapter has to re-publish the handle afterwards.
    def test_raw_connection_tracks_the_driver_handle
      assert_not_nil @connection.instance_variable_get(:@raw_connection),
                     "@raw_connection is nil, so with_raw_connection yields nil and re-verifies on every statement"
      assert_same @connection.instance_variable_get(:@connection),
                  @connection.instance_variable_get(:@raw_connection)
    end

    def test_with_raw_connection_yields_the_live_handle
      @connection.send(:with_raw_connection) do |conn|
        assert_not_nil conn, "with_raw_connection yielded nil"
        assert_same @connection.instance_variable_get(:@connection), conn
      end
    end

    # The reported failure, in the shape ProntoService::Base uses: writes, then
    # a nested transaction (every save! opens one), then ActiveRecord::Rollback.
    def test_rollback_discards_writes_made_around_a_nested_transaction
      Sample.transaction do
        Sample.create!(value: 1)
        # Any statement between the write and the nested transaction was enough
        # to lose the transaction.
        @connection.select_value("SELECT FIRST 1 tabid FROM systables")

        Sample.transaction { Sample.create!(value: 2) }

        assert_predicate @connection, :transaction_open?,
                         "the open transaction was discarded before the rollback could reach it"
        raise ActiveRecord::Rollback
      end

      assert_equal 0, Sample.count, "ActiveRecord::Rollback left rows behind"
    end

    def test_rollback_discards_writes_when_an_exception_escapes
      assert_raises(RuntimeError) do
        Sample.transaction do
          Sample.create!(value: 1)
          Sample.transaction { Sample.create!(value: 2) }
          raise "boom"
        end
      end

      assert_equal 0, Sample.count, "a raise inside the transaction left rows behind"
    end

    # A nested transaction must join the open one, not become a second
    # top-level transaction that commits on its own.
    def test_nested_transaction_does_not_commit_independently
      committed = false
      @connection.singleton_class.prepend(Module.new do
        define_method(:commit_db_transaction) do
          committed = true
          super()
        end
      end)

      Sample.transaction do
        Sample.create!(value: 1)
        Sample.transaction { Sample.create!(value: 2) }
        assert_not committed, "the nested transaction issued its own COMMIT"
        raise ActiveRecord::Rollback
      end

      assert_equal 0, Sample.count
    end

    # The guard itself: even if #active? lies (as it did for every Informix ODBC
    # connection), a statement must not be allowed to tear down an open, dirty
    # transaction. This is what fails on the old code in *any* mode, DRDA
    # included, not just where active? happens to be broken.
    def test_open_transaction_survives_a_statement_when_active_reports_false
      Sample.transaction do
        Sample.create!(value: 1)
        manager_before = @connection.instance_variable_get(:@transaction_manager)

        @connection.stub(:active?, false) do
          @connection.select_value("SELECT FIRST 1 tabid FROM systables")
        end

        assert_same manager_before, @connection.instance_variable_get(:@transaction_manager),
                    "the TransactionManager was replaced mid-transaction, discarding the open transaction"
        assert_predicate @connection, :transaction_open?
        raise ActiveRecord::Rollback
      end

      assert_equal 0, Sample.count
    end
  end
end

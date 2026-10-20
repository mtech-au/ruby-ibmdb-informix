# frozen_string_literal: true

require "cases/helper"

module ActiveRecord
  # Row locks between two live Informix sessions.
  #
  # One connection holds an update lock on row 1 (REPEATABLE READ keeps it
  # until the transaction ends). A second connection, from its own pool, then
  # reads the row FOR UPDATE inside a transaction (in autocommit mode Informix
  # takes no update lock, so nothing would block). Before these fixes:
  #   * Model.lock / lock! emitted no FOR UPDATE at all;
  #   * the failed fetch came back as the error text, so select_value
  #     returned ":" instead of raising;
  #   * nothing mapped the Informix lock errors to LockWaitTimeout;
  #   * there was no way to set the lock wait from database.yml.
  class IBM_DBRowLockTest < ActiveRecord::IBM_DBTestCase
    self.use_transactional_tests = false

    TABLE = "ibm_db_row_lock_samples"
    LOCKING_SELECT = "SELECT id FROM #{TABLE} WHERE id = 1 FOR UPDATE"

    class Sample < ActiveRecord::Base
      self.table_name = TABLE
    end

    # A second pool, so the blocked reader is a different Informix session.
    class OtherSession < ActiveRecord::Base
      self.abstract_class = true
    end

    class OtherSample < OtherSession
      self.table_name = TABLE
    end

    setup do
      @connection = ActiveRecord::Base.lease_connection
      @connection.drop_table(TABLE, if_exists: true)
      @connection.execute("CREATE TABLE #{TABLE} (id INT PRIMARY KEY, code CHAR(8), value INT) LOCK MODE ROW")
      @connection.execute("CREATE UNIQUE INDEX #{TABLE}_code ON #{TABLE} (code)")
      @connection.execute("INSERT INTO #{TABLE} VALUES (1, 'one', 0)")
      Sample.reset_column_information
      OtherSample.reset_column_information
    end

    teardown do
      OtherSession.remove_connection
      @connection.drop_table(TABLE, if_exists: true)
    end

    def test_lock_emits_for_update
      assert_match(/ FOR UPDATE\z/, Sample.lock.where(id: 1).to_sql)
    end

    def test_lock_with_a_string_emits_that_clause
      assert_match(/ FOR UPDATE OF value\z/, Sample.lock("FOR UPDATE OF value").where(id: 1).to_sql)
    end

    def test_lock_bang_runs_on_informix
      Sample.transaction do
        assert_equal 1, Sample.find(1).lock!.id
      end
    end

    def test_a_locked_row_raises_lock_wait_timeout_from_select_value
      other = other_session

      error = holding_row_lock { assert_raises(LockWaitTimeout) { in_transaction(other) { other.select_value(LOCKING_SELECT) } } }

      assert_includes error.message, "SQLCODE=-244"
    end

    def test_a_locked_row_raises_lock_wait_timeout_from_select_rows
      other = other_session

      holding_row_lock { assert_raises(LockWaitTimeout) { in_transaction(other) { other.select_rows(LOCKING_SELECT) } } }
    end

    def test_a_locked_row_raises_lock_wait_timeout_from_a_locking_find
      other_session

      holding_row_lock do
        assert_raises(LockWaitTimeout) { OtherSample.transaction { OtherSample.lock.find(1) } }
      end
    end

    def test_a_locked_row_raises_lock_wait_timeout_from_an_update
      other_session

      holding_row_lock do
        assert_raises(LockWaitTimeout) { OtherSample.where(id: 1).update_all(value: 1) }
      end
    end

    def test_duplicate_keys_raise_record_not_unique
      assert_raises(RecordNotUnique) { Sample.create!(id: 1, code: "dup-pk", value: 0) }
      assert_raises(RecordNotUnique) { Sample.create!(id: 2, code: "one", value: 0) }
    end

    # Informix counts the wait in whole-second ticks, so WAIT n gives up
    # after n-1 to n seconds (measured: WAIT 1 has returned after 0.11 s).
    def test_lock_wait_waits_before_raising
      other = other_session(lock_wait: 2)

      seconds = holding_row_lock { elapsed { assert_raises(LockWaitTimeout) { locking_read(other) } } }

      assert_operator seconds, :>=, 0.9, "lock_wait: 2 should wait before failing, not fail at once"
    end

    def test_lock_wait_is_reapplied_after_a_reconnect
      other = other_session(lock_wait: 2)
      other.reconnect!

      seconds = holding_row_lock { elapsed { assert_raises(LockWaitTimeout) { locking_read(other) } } }

      assert_operator seconds, :>=, 0.9, "the reconnected session lost its lock wait"
    end

    def test_lock_wait_zero_does_not_wait
      other = other_session(lock_wait: 0)

      seconds = holding_row_lock { elapsed { assert_raises(LockWaitTimeout) { locking_read(other) } } }

      assert_operator seconds, :<, 0.5
    end

    def test_lock_wait_rejects_a_non_integer
      assert_raises(ArgumentError) { other_session(lock_wait: "soon") }
    end

    private
      def other_session(**config)
        OtherSession.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash.merge(config))
        OtherSession.lease_connection
      end

      def in_transaction(connection)
        connection.transaction { yield }
      end

      def locking_read(connection)
        in_transaction(connection) { connection.select_value(LOCKING_SELECT) }
      end

      # Holds an update lock on row 1 for the duration of the block.
      def holding_row_lock
        result = nil
        @connection.execute("SET ISOLATION TO REPEATABLE READ")
        Sample.transaction do
          Sample.lock.find(1)
          result = yield
          raise ActiveRecord::Rollback
        end
        result
      ensure
        @connection.execute("SET ISOLATION TO COMMITTED READ")
      end

      def elapsed
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
  end
end

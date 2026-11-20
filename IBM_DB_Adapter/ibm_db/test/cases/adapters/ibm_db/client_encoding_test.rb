# frozen_string_literal: true

require "cases/helper"
require "json"

module ActiveRecord
  # The Informix CSDK ODBC build is an ANSI (SQLCHAR) build. It built every
  # fetched value with rb_str_new, so CHAR/VARCHAR data, column names and error
  # messages came back tagged ASCII-8BIT even though the driver had already
  # converted them to the CLIENT_LOCALE codeset. JSON.generate warns about such
  # strings, and json 3.0 rejects them. Character data now carries the
  # connection's CLIENT_LOCALE encoding (UTF-8 when none is given). Binary
  # columns stay ASCII-8BIT.
  class IBM_DBClientEncodingTest < ActiveRecord::IBM_DBTestCase
    self.use_transactional_tests = false

    TABLE = "ibm_db_encoding_samples"
    # Multi-byte in UTF-8 but representable in ISO-8859-1, so the test also
    # runs against an en_US.819 database (the driver converts both ways).
    TEXT  = "Crème brûlée café"
    BYTES = "\xE2\x80\x93\x00\xFF".b

    class Sample < ActiveRecord::Base
      self.table_name = TABLE
    end

    setup do
      # Connecting loads the extension, which defines IBM_DB::INFORMIX_ODBC.
      @connection = ActiveRecord::Base.lease_connection
      @connection.verify!
      # DRDA (clidriver) builds are UNICODE builds and never had this bug.
      skip "Informix CSDK ODBC build only" unless defined?(IBM_DB::INFORMIX_ODBC) && IBM_DB::INFORMIX_ODBC

      @connection.drop_table(TABLE, if_exists: true)
      @connection.execute(<<~SQL)
        CREATE TABLE #{TABLE} (id INT PRIMARY KEY, name VARCHAR(60), code CHAR(30), note LVARCHAR(200), payload BYTE)
      SQL
      @connection.execute("INSERT INTO #{TABLE} (id, name, code, note) VALUES (1, '#{TEXT}', '#{TEXT}', '#{TEXT}')")
      Sample.reset_column_information
    end

    teardown do
      @connection&.drop_table(TABLE, if_exists: true)
    end

    def test_varchar_is_utf8
      assert_utf8_text Sample.find(1).name
    end

    def test_char_is_utf8
      assert_utf8_text Sample.find(1).code.rstrip
    end

    def test_lvarchar_is_utf8
      assert_utf8_text Sample.find(1).note
    end

    def test_select_value_is_utf8
      assert_utf8_text @connection.select_value("SELECT name FROM #{TABLE} WHERE id = 1")
    end

    def test_pluck_is_utf8
      assert_utf8_text Sample.pluck(:name).first
    end

    def test_column_names_are_utf8
      name = @connection.select_all("SELECT name FROM #{TABLE}").columns.first

      assert_equal Encoding::UTF_8, name.encoding
    end

    # json 2.x warns ("UTF-8 string passed as BINARY") where json 3.0 raises.
    def test_json_generate_does_not_warn
      previous_verbose, previous_deprecated = $VERBOSE, Warning[:deprecated]
      $VERBOSE = false # -W0 (nil) would silence the warning being tested for
      Warning[:deprecated] = true
      value = Sample.find(1).name

      assert_output(nil, "") { assert_equal %(["#{TEXT}"]), JSON.generate([value]) }
    ensure
      $VERBOSE = previous_verbose
      Warning[:deprecated] = previous_deprecated
    end

    # The server error differs by database locale (-206 echoing the name on a
    # UTF-8 database, -202 on en_US.819), so only the encoding is checked.
    def test_error_message_is_utf8
      error = assert_raises(ActiveRecord::StatementInvalid) do
        @connection.select_value("SELECT * FROM tablé_missing")
      end

      assert_equal Encoding::UTF_8, error.message.encoding
      assert_predicate error.message, :valid_encoding?
    end

    # BYTE contents do not currently round-trip through the driver (they read
    # back as zero bytes, before and after this change), so only the encoding
    # and length are checked here.
    def test_binary_column_stays_binary
      raw    = @connection.raw_connection
      update = IBM_DB.prepare(raw, "UPDATE #{TABLE} SET payload = ? WHERE id = 1")
      assert IBM_DB.execute(update, [BYTES]), IBM_DB.getErrormsg(update, IBM_DB::DB_STMT)

      select  = IBM_DB.exec(raw, "SELECT payload FROM #{TABLE} WHERE id = 1")
      payload = IBM_DB.fetch_array(select).first

      assert_equal Encoding::ASCII_8BIT, payload.encoding
      assert_equal BYTES.bytesize, payload.bytesize
    ensure
      # An open cursor keeps the table locked against the next DROP TABLE.
      [update, select].each { |stmt| IBM_DB.free_stmt(stmt) if stmt }
    end

    private
      def assert_utf8_text(value)
        assert_equal Encoding::UTF_8, value.encoding
        assert_predicate value, :valid_encoding?
        assert_equal TEXT, value
      end
  end
end

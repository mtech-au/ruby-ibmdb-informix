/*
  +----------------------------------------------------------------------+
  |  Compatibility definitions for building against the Informix CSDK    |
  |  ODBC driver (IBM_DB_INFORMIX_ODBC) instead of the DB2 CLI driver.   |
  |                                                                      |
  |  The Informix headers (infxcli.h/sql.h/sqlext.h) do not define the   |
  |  DB2 CLI extensions referenced by this extension. The fallback       |
  |  values below are the DB2 CLI values (from sqlcli.h/sqlcli1.h), so   |
  |  type switches compile unchanged and simply never match at runtime,  |
  |  and unsupported attributes fail softly via the driver's own error.  |
  +----------------------------------------------------------------------+
*/

#ifndef RUBY_INFORMIX_COMPAT_H
#define RUBY_INFORMIX_COMPAT_H

/* DB2 CLI type extensions (sqlcli.h) */
#ifndef SQL_GRAPHIC
#define SQL_GRAPHIC          -95
#endif
#ifndef SQL_VARGRAPHIC
#define SQL_VARGRAPHIC       -96
#endif
#ifndef SQL_BLOB
#define SQL_BLOB             -98
#endif
#ifndef SQL_CLOB
#define SQL_CLOB             -99
#endif
#ifndef SQL_BLOB_LOCATOR
#define SQL_BLOB_LOCATOR      31
#endif
#ifndef SQL_CLOB_LOCATOR
#define SQL_CLOB_LOCATOR      41
#endif

/* DB2 client-info connection attributes (sqlcli1.h) */
#ifndef SQL_ATTR_INFO_USERID
#define SQL_ATTR_INFO_USERID      1281
#define SQL_ATTR_INFO_WRKSTNNAME  1282
#define SQL_ATTR_INFO_APPLNAME    1283
#define SQL_ATTR_INFO_ACCTSTR     1284
#endif

/* DB2 connection-level ping attribute (sqlcli1.h) */
#ifndef SQL_ATTR_PING_DB
#define SQL_ATTR_PING_DB          2545
#endif

/* DB2 SQLGetInfo extensions used by client_info/server_info (sqlcli.h) */
#ifndef SQL_DATABASE_CODEPAGE
#define SQL_DATABASE_CODEPAGE     2519
#endif
#ifndef SQL_APPLICATION_CODEPAGE
#define SQL_APPLICATION_CODEPAGE  2520
#endif

/* DB2 no-commit isolation bit reported by SQL_TXN_ISOLATION_OPTION (sqlcli1.h) */
#ifndef SQL_TXN_NOCOMMIT
#define SQL_TXN_NOCOMMIT          0x00000020L
#endif

/* LOB file option for PARAM_FILE binds (sqlcli1.h) */
#ifndef SQL_FILE_READ
#define SQL_FILE_READ             2
#endif

/* Standard ODBC symbols that some header sets omit */
#ifndef SQL_FALSE
#define SQL_FALSE                 0
#endif
#ifndef SQL_TRUE
#define SQL_TRUE                  1
#endif
#ifndef SQL_WCHAR
#define SQL_WCHAR                 (-8)
#endif
#ifndef SQL_WVARCHAR
#define SQL_WVARCHAR              (-9)
#endif
#ifndef SQL_WLONGVARCHAR
#define SQL_WLONGVARCHAR          (-10)
#endif
#ifndef SQL_C_WCHAR
#define SQL_C_WCHAR               SQL_WCHAR
#endif

#endif /* RUBY_INFORMIX_COMPAT_H */

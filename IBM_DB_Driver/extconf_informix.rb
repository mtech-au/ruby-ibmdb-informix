#!/usr/bin/env ruby
# Builds the ibm_db extension against the Informix CSDK ODBC driver
# (direct link, native SQLI/onsoctcp) instead of the IBM DB2 CLI driver (DRDA).
# Loaded from extconf.rb when IBM_DB_INFORMIX=1 or --enable-informix is given.
#
# Requires a pre-installed Informix CSDK (or IDS server install) pointed at by
# INFORMIXDIR (or IBM_DB_INFORMIX_HOME). Nothing is downloaded.

unless RUBY_PLATFORM =~ /linux/i
  puts "Informix ODBC mode (IBM_DB_INFORMIX=1) is only supported on Linux.\n" \
       "No Informix CSDK exists for #{RUBY_PLATFORM}; unset IBM_DB_INFORMIX to build the default DB2/DRDA driver.\n "
  exit 1
end

INFORMIXDIR = ENV['IBM_DB_INFORMIX_HOME'] || ENV['INFORMIXDIR']

if INFORMIXDIR.nil? || INFORMIXDIR.empty?
  puts "IBM_DB_INFORMIX=1 requires the INFORMIXDIR (or IBM_DB_INFORMIX_HOME) environment variable\n" \
       "pointing at an Informix CSDK installation (expects incl/cli and lib/cli under it).\n "
  exit 1
end

INFORMIX_INCLUDE = "#{INFORMIXDIR}/incl/cli"
INFORMIX_CLI_LIB = "#{INFORMIXDIR}/lib/cli"
INFORMIX_ESQL_LIB = "#{INFORMIXDIR}/lib/esql"

[INFORMIX_INCLUDE, INFORMIX_CLI_LIB].each do |dir|
  unless File.directory?(dir)
    puts "#{dir} not found. Check that INFORMIXDIR points at a complete Informix CSDK installation.\n "
    exit 1
  end
end

puts "Building ibm_db against Informix CSDK ODBC driver at #{INFORMIXDIR}\n "

require 'mkmf'

dir_config('IBM_DB', INFORMIX_INCLUDE, INFORMIX_CLI_LIB)

def crash(str)
  printf(" extconf failure: %s\n", str)
  exit 1
end

# Use $CPPFLAGS, not $defs: create_header drains $defs into the generated header,
# and the macro must be visible on the compile command line for every source file.
$CPPFLAGS << ' -DIBM_DB_INFORMIX_ODBC'

$LDFLAGS << " -L#{INFORMIX_ESQL_LIB}" if File.directory?(INFORMIX_ESQL_LIB)
[INFORMIX_CLI_LIB, INFORMIX_ESQL_LIB, "#{INFORMIXDIR}/lib"].each do |path|
  $LDFLAGS << " -Wl,-rpath,#{path}" if File.directory?(path)
end

# ANSI (non-unicode) build: create only the GIL header. RUBY_EXTCONF_H then points
# at gil_release_version.h and UNICODE_SUPPORT_VERSION_H stays undefined, selecting
# the plain-SQLCHAR code paths throughout the extension. The CSDK driver's wide-char
# (SQLWCHAR) behavior on Unix is version-dependent, so the W entry points are avoided.
if RUBY_VERSION =~ /1.9/ || RUBY_VERSION =~ /2./ || RUBY_VERSION =~ /3./
  create_header('gil_release_version.h')
end

unless have_header('infxcli.h')
  crash("infxcli.h not found under #{INFORMIX_INCLUDE}. Check your Informix CSDK installation.")
end

# libthcli is the thread-safe CSDK ODBC driver, libifcli the non-threaded one;
# both are direct-link variants of the driver (iclit09b.so). Prefer thread-safe.
unless have_library('thcli', 'SQLConnect') ||
       have_library('ifcli', 'SQLConnect') ||
       find_library('thcli', 'SQLConnect', INFORMIX_CLI_LIB) ||
       find_library('ifcli', 'SQLConnect', INFORMIX_CLI_LIB)
  crash(<<EOL)
Unable to locate the Informix CSDK ODBC driver (libthcli/libifcli) under #{INFORMIX_CLI_LIB}

Follow the steps below and retry

Step 1: - Install the IBM Informix Client SDK (CSDK)

Step 2: - Set the environment variable INFORMIXDIR to the CSDK installation directory

            (assuming bash shell)

            export INFORMIXDIR=<CSDK installation directory> #(Eg: export INFORMIXDIR=/opt/IBM/Informix_Client-SDK)

Step 3: - Retry gem install with IBM_DB_INFORMIX=1

EOL
end

have_header('gil_release_version.h')

create_makefile('ibm_db')

# In the gem layout the built extension is copied to ../lib (not present when
# building the standalone IBM_DB_Driver copy)
if File.directory?(File.expand_path('../lib', __dir__))
  File.open('Makefile', 'a') do |mf|
    mf.puts <<~MAKE

      all: copy-to-lib
      copy-to-lib: $(DLLIB)
      \tcp $(DLLIB) $(srcdir)/../lib/$(DLLIB)
    MAKE
  end
end

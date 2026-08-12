#!/usr/bin/env ruby

# Informix CSDK ODBC build mode (native SQLI, no DRDA / DB2 clidriver).
# Opt in with IBM_DB_INFORMIX=1 or `bundle config set build.ibm_db --enable-informix`.
if ENV['IBM_DB_INFORMIX'] =~ /\A(1|true|yes)\z/i || ARGV.grep(/\A--enable-informix\z/).any?
  load File.expand_path('extconf_informix.rb', __dir__)
  exit 0
end

require 'net/http'
require 'open-uri'
require 'rubygems/package'
require 'zlib'
require 'zip'
require 'fileutils'
require 'down'
require 'uri'

# +----------------------------------------------------------------------+
# |  Licensed Materials - Property of IBM                                |
# |                                                                      |
# | (C) Copyright IBM Corporation 2006 - 2024                            |
# +----------------------------------------------------------------------+

TAR_LONGLINK = '././@LongLink'

WIN = RUBY_PLATFORM =~ /mswin/ || RUBY_PLATFORM =~ /mingw/

# use ENV['IBM_DB_HOME'] or latest db2 you can find
IBM_DB_HOME = ENV['IBM_DB_HOME']

machine_bits = ['ibm'].pack('p').size * 8

is64Bit = true

if machine_bits == 64
  is64Bit = true
  puts "Detected 64-bit Ruby\n "
else
  is64Bit = false
  puts "Detected 32-bit Ruby\n "
end

module Kernel
  def suppress_warnings
    origVerbosity = $VERBOSE
    $VERBOSE = nil
    result = yield
    $VERBOSE = origVerbosity
    return result
  end
end

DOWNLOADLINK = ''
ZIP = false
PRIMARY_CLIDRIVER_BASE_URL = 'https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/'
FALLBACK_CLIDRIVER_BASE_URL = 'https://github.com/ibmdb/db2drivers/raw/main/clidriver/'
CLIFILENAME = ''

if(RUBY_PLATFORM =~ /aix/i)
  #AIX
  if(is64Bit)
    puts "Detected platform - aix 64"
    CLIFILENAME = 'aix64_odbc_cli.tar.gz'
  else
    puts "Detected platform - aix 32"
    CLIFILENAME = 'aix32_odbc_cli.tar.gz'
  end
elsif (RUBY_PLATFORM =~ /powerpc/ || RUBY_PLATFORM =~ /ppc/)
  #PPC
  if(is64Bit)
    puts "Detected platform - ppc linux 64"
    CLIFILENAME = 'ppc64_odbc_cli.tar.gz'
  else
    puts "Detected platform - ppc linux 64"
    CLIFILENAME = 'ppc32_odbc_cli.tar.gz'
  end
elsif (RUBY_PLATFORM =~ /linux/)
  #x86
  if(is64Bit)
    puts "Detected platform - linux x86 64"
    CLIFILENAME = 'linuxx64_odbc_cli.tar.gz'
  else
    puts "Detected platform - linux 32"
    CLIFILENAME = 'linuxia32_odbc_cli.tar.gz'
  end
elsif (RUBY_PLATFORM =~ /sparc/i)
  #Solaris
  if(is64Bit)
    puts "Detected platform - sun sparc64"
    CLIFILENAME = 'sun64_odbc_cli.tar.gz'
  else
    puts "Detected platform - sun sparc32"
    CLIFILENAME = 'sun32_odbc_cli.tar.gz'
  end
elsif (RUBY_PLATFORM =~ /solaris/i)
  if(is64Bit)
    puts "Detected platform - sun amd64"
    CLIFILENAME = 'sunamd64_odbc_cli.tar.gz'
  else
    puts "Detected platform - sun amd32"
    CLIFILENAME = 'sunamd32_odbc_cli.tar.gz'
  end
elsif (RUBY_PLATFORM =~ /darwin/i)
  if (RUBY_PLATFORM =~ /arm64/i)
    puts "Detected platform - MacOS darwin arm64"
    CLIFILENAME = 'macarm64_odbc_cli.tar.gz'
  elsif(RUBY_PLATFORM =~ /x86_64/i || is64Bit)
    puts "Detected platform - MacOS darwin x86_64"
    CLIFILENAME = 'macos64_odbc_cli.tar.gz'
  else
    puts "Mac OS 32 bit not supported. Please use an x64 architecture."
  end
elsif (RUBY_PLATFORM =~ /mswin/ || RUBY_PLATFORM =~ /mingw/)
  ZIP = true
  if(is64Bit)
    puts "Detected platform - windows 64"
    CLIFILENAME = 'ntx64_odbc_cli.zip'
  else
    puts "Detected platform - windows 32"
    CLIFILENAME = 'nt32_odbc_cli.zip'
  end
end

if(!CLIFILENAME.nil? && !CLIFILENAME.empty?)
  DOWNLOADLINK = "#{PRIMARY_CLIDRIVER_BASE_URL}#{CLIFILENAME}"
end

def downloadCLIPackage(destination, link = nil)
  if(link.nil?)
    cliFileName = CLIFILENAME
  else
    begin
      cliFileName = File.basename(URI.parse(link).path)
    rescue
      cliFileName = nil
    end
  end

  if(cliFileName.nil? || cliFileName.empty?)
    raise 'Unable to determine clidriver package filename for download.'
  end

  primaryLink = "#{PRIMARY_CLIDRIVER_BASE_URL}#{cliFileName}"
  if(!link.nil? && !link.empty?)
    primaryLink = link
  end

  if ZIP
    filename = "#{destination}/clidriver.zip"
  else
    filename = "#{destination}/clidriver.tar.gz"
  end

  fallbackLink = "#{FALLBACK_CLIDRIVER_BASE_URL}#{cliFileName}"

  downloadUrls = [primaryLink]
  if !fallbackLink.nil? && fallbackLink != primaryLink
    downloadUrls << fallbackLink
  end

  lastError = nil
  downloadUrls.each_with_index do |url, index|
    begin
      puts "Downloading DSDriver from URL: #{url}"
      Down.download(url, destination: filename, ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE)
      return filename
    rescue => e
      lastError = e
      if index < downloadUrls.length - 1
        puts "Download failed from primary URL. Retrying with fallback mirror..."
      end
    end
  end

  raise "Failed to download DSDriver from all configured URLs. Last error: #{lastError}"

  filename
end

def extract_zip(file, destination)
  FileUtils.mkdir_p(destination)

  Zip::File.open(file) do |zip_file|
    zip_file.each do |entry|
      fpath = File.join(destination, entry.name)

      if entry.directory?
        FileUtils.mkdir_p(fpath)
      else
        FileUtils.mkdir_p(File.dirname(fpath))
        next if File.exist?(fpath)

        entry.get_input_stream do |input|
          File.open(fpath, 'wb') do |output|
            IO.copy_stream(input, output)
          end
        end
      end
    end
  end
end

def untarCLIPackage(archive,destination)
  Gem::Package::TarReader.new( Zlib::GzipReader.open(archive) ) do |tar|
    tar.each do |entry|
      file = nil
      if entry.full_name == $TAR_LONGLINK
        file = File.join destination, entry.read.strip
        next
      end
      file ||= File.join destination, entry.full_name
      if entry.directory?
        File.delete file if File.file? file
        FileUtils.mkdir_p file, :mode => entry.header.mode, :verbose => false
      elsif entry.file?
        FileUtils.rm_rf file if File.directory? file
        if (RUBY_PLATFORM =~ /darwin/i) && (RUBY_PLATFORM =~ /arm64/i) && File.exist?(file)
          FileUtils.chmod 755, file, :verbose => false
        end
        File.open file, "wb" do |f|
          f.print entry.read
        end
        FileUtils.chmod entry.header.mode, file, :verbose => false
      elsif entry.header.typeflag == '2' #Symlink!
        if (RUBY_PLATFORM =~ /darwin/i) && (RUBY_PLATFORM =~ /arm64/i) && File.exist?(file)
          File.delete file if File.file? file
        end
        File.symlink entry.header.linkname, file
      end
    end
  end
end

if(IBM_DB_HOME == nil || IBM_DB_HOME == '')
  IBM_DB_INCLUDE = ENV['IBM_DB_INCLUDE']
  IBM_DB_LIB = ENV['IBM_DB_LIB']

  if( ( (IBM_DB_INCLUDE.nil?) || (IBM_DB_LIB.nil?) ) ||
      ( IBM_DB_INCLUDE == '' || IBM_DB_LIB == '' )
  )
    if(!DOWNLOADLINK.nil? && !DOWNLOADLINK.empty?)
      puts "Environment variable IBM_DB_HOME is not set. Downloading and setting up the DB2 client driver\n"
      destination = "#{File.expand_path(File.dirname(File.dirname(__FILE__)))}/../lib"

      archive = downloadCLIPackage(destination)
      if (ZIP)
        extract_zip(archive, destination)
      else
        untarCLIPackage(archive,destination)
      end

      IBM_DB_HOME="#{destination}/clidriver"

      IBM_DB_INCLUDE = "#{IBM_DB_HOME}/include"
      IBM_DB_LIB="#{IBM_DB_HOME}/lib"
    else
      puts "Environment variable IBM_DB_HOME is not set. Set it to your DB2/IBM_Data_Server_Driver installation directory and retry gem install.\n "
      exit 1
    end
  end
else
  IBM_DB_INCLUDE = "#{IBM_DB_HOME}/include"

  if(is64Bit)
    IBM_DB_LIB="#{IBM_DB_HOME}/lib64"
  else
    IBM_DB_LIB="#{IBM_DB_HOME}/lib32"
  end
end

if( !(File.directory?(IBM_DB_LIB)) )
  suppress_warnings{IBM_DB_LIB = "#{IBM_DB_HOME}/lib"}
  if( !(File.directory?(IBM_DB_LIB)) )
    puts "Cannot find #{IBM_DB_LIB} directory. Check if you have set the IBM_DB_HOME environment variable's value correctly\n "
    exit 1
  end
  notifyString  = "Detected usage of IBM Data Server Driver package. Ensure you have downloaded "

  if(is64Bit)
    notifyString = notifyString + "64-bit package "
  else
    notifyString = notifyString + "32-bit package "
  end
  notifyString = notifyString + "of IBM_Data_Server_Driver and retry the 'gem install ibm_db' command\n "

  puts notifyString
end

if( !(File.directory?(IBM_DB_INCLUDE)) )
  puts " #{IBM_DB_HOME}/include folder not found. Check if you have set the IBM_DB_HOME environment variable's value correctly\n "
  exit 1
end

require 'mkmf'

dir_config('IBM_DB',IBM_DB_INCLUDE,IBM_DB_LIB)

def crash(str)
  printf(" extconf failure: %s\n", str)
  exit 1
end

if( RUBY_VERSION =~ /1.9/ || RUBY_VERSION =~ /2./ || RUBY_VERSION =~ /3./ || RUBY_VERSION =~ /4./)
  create_header('gil_release_version.h')
  create_header('unicode_support_version.h')
end

lib_found =
  if WIN
    have_library('db2cli64', 'SQLConnect') ||
    find_library('db2cli64', 'SQLConnect', IBM_DB_LIB) ||
    have_library('db2app64', 'SQLConnect') ||
    find_library('db2app64', 'SQLConnect', IBM_DB_LIB) ||
    have_library('db2cli', 'SQLConnect') ||
    find_library('db2cli', 'SQLConnect', IBM_DB_LIB)
  else
    have_library('db2', 'SQLConnect') ||
    find_library('db2', 'SQLConnect', IBM_DB_LIB)
  end

unless lib_found
  crash(<<EOL)
Unable to locate DB2 CLI library under #{IBM_DB_LIB}

Follow the steps below and retry

Step 1: - Install IBM DB2 Universal Database Server/Client

step 2: - Set the environment variable IBM_DB_HOME as below

             (assuming bash shell)

             export IBM_DB_HOME=<DB2/IBM_Data_Server_Driver installation directory> #(Eg: export IBM_DB_HOME=/opt/ibm/db2/v10)

step 3: - Retry gem install

EOL
end

if(RUBY_VERSION =~ /2./ || RUBY_VERSION =~ /3./ || RUBY_VERSION =~ /4./)
  require 'rbconfig'
end

alias :libpathflag0 :libpathflag
def libpathflag(libpath)
  if(RUBY_PLATFORM =~ /darwin/i)
    if(RUBY_VERSION =~ /2./ || RUBY_VERSION =~ /3./ || RUBY_VERSION =~ /4./)
      libpathflag0 + case RbConfig::CONFIG["arch"]
      when /solaris2/
        libpath[0..-2].map {|path| " -R#{path}"}.join
      when /linux/
        libpath[0..-2].map {|path| " -R#{path} "}.join
      else
        ""
      end
    else
      libpathflag0 + case Config::CONFIG["arch"]
      when /solaris2/
        libpath[0..-2].map {|path| " -R#{path}"}.join
      when /linux/
        libpath[0..-2].map {|path| " -R#{path} "}.join
      else
        ""
      end
    end
  else
    if(RUBY_VERSION =~ /2./ || RUBY_VERSION =~ /3./ || RUBY_VERSION =~ /4./)
      ldflags =  case RbConfig::CONFIG["arch"]
      when /solaris2/
        libpath[0..-2].map {|path| " -R#{path}"}.join
      when /linux/
        libpath[0..-2].map {|path| " -R#{path} "}.join
      else
        ""
      end
    else
      ldflags =  case Config::CONFIG["arch"]
      when /solaris2/
        libpath[0..-2].map {|path| " -R#{path}"}.join
      when /linux/
        libpath[0..-2].map {|path| " -R#{path} "}.join
      else
        ""
      end
    end
    libpathflag0 + " '-Wl,-R$$ORIGIN/clidriver/lib' "
  end
end

have_header('gil_release_version.h')
have_header('unicode_support_version.h')

create_makefile('ibm_db')

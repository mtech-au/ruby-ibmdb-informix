if RUBY_PLATFORM.match?(/darwin/i)
  cliPackagePath = File.dirname(__FILE__) + '/clidriver'
  if Dir.exist?(cliPackagePath)
    currentPath = "#{File.expand_path(File.dirname(File.dirname(__FILE__)))}"

    cmd = "chmod 755 #{currentPath}/lib/ibm_db.bundle "
    `#{cmd}`

    cmd = "chmod 755 #{currentPath}/lib/clidriver/lib/libdb2.dylib"
    `#{cmd}`

    # Only rewrite the load command while it still references the bare
    # libdb2.dylib name; requires the bundle to be linked with
    # -headerpad_max_install_names (see ext/extconf.rb).
    if `otool -L #{currentPath}/lib/ibm_db.bundle`[/^\s+libdb2\.dylib/]
      cmd = "install_name_tool -change libdb2.dylib #{currentPath}/lib/clidriver/lib/libdb2.dylib #{currentPath}/lib/ibm_db.bundle"
      `#{cmd}`
    end

    $LOAD_PATH.unshift("#{currentPath}/lib")
  end

  require 'ibm_db.bundle'

elsif RUBY_PLATFORM =~ /mswin32/ || RUBY_PLATFORM =~ /mingw32/
  require 'mswin32/ibm_db'
else
  require 'ibm_db.so'
end

require 'active_record'
require 'active_record/connection_adapters/ibm_db_adapter'

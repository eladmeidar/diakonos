#!/usr/bin/env ruby

require './lib/diakonos/version.rb'
require 'fileutils'
require 'pp'

module Diakonos
  class Installer

    def initialize( argv = ARGV.dup )
      want_help = false
      @prefix = '/usr'
      @lib_dir = $LOAD_PATH.grep( /site_ruby/ ).first
      @conf_dir = nil
      @bin_dir = nil
      @doc_dir = nil
      @verbose = false
      @pretend = false
      @bin_suffix = 'bin'
      @conf_suffix = '../etc'
      @doc_suffix = 'share/doc'

      while argv.any?
        arg = argv.shift
        case arg
        when '-h', '--help'
          want_help = true
        when '--prefix'
          @prefix = argv.shift
        when '-p', '--pretend', '--dry-run'
          @pretend = true
        when '--bin-dir'
          @bin_dir = argv.shift
        when '--conf-dir'
          @conf_dir = argv.shift
        when '--doc-dir'
          @doc_dir = argv.shift
        when '--lib-dir'
          @lib_dir = argv.shift
        when '-v', '--verbose'
          @verbose = true
        end
      end

      @bin_dir ||= "#{@prefix}/#{@bin_suffix}"
      @doc_dir ||= "#{@prefix}/#{@doc_suffix}"
      @conf_dir ||= "#{@prefix}/#{@conf_suffix}"

      @versioned_package = "diakonos-#{Diakonos::VERSION}"

      if want_help
        print_usage_and_exit
      end

      if @pretend
        puts "(Dry run only; not actually writing any files or directories)"
        puts
      end

      if @verbose && @pretend
        self.extend FileUtils::DryRun
      elsif @verbose
        self.extend FileUtils::Verbose
      elsif @pretend
        self.extend FileUtils::NoWrite
      else
        self.extend FileUtils
      end

      @installed_files = []
      @installed_dirs = []
    end

    def print_usage_and_exit
      puts "#{$0} [options]"
      puts "    -h / --help          show usage (can be used with other options to preview paths)"
      puts "    -v / --verbose       print each step"
      puts "    -p / --pretend       don't actually do anything"
      puts "    --prefix <path>      set installation prefix (default #{@prefix})"
      puts "    --bin-dir <path>     set executable installation dir (default <prefix>/#{@bin_suffix})"
      puts "    --doc-dir <path>     set documentation installation dir (default <prefix>/#{@doc_suffix})"
      puts "    --conf-dir <path>    set configuration installation dir (default <prefix>/#{@conf_suffix})"
      puts "    --lib-dir <path>     set library installation dir (default on this system: #{@lib_dir})"
      exit 2
    end

    def write_installation_settings
      installation_file = "#{@lib_dir}/diakonos/installation.rb"
      if @verbose
        puts "Writing installation settings to #{installation_file}"
      end
      return  if @pretend
      File.open( installation_file, 'w' ) do |f|
        f.puts %|
module Diakonos
  INSTALL_SETTINGS = {
    :prefix   => '#{@prefix}',
    :bin_dir  => '#{@bin_dir}',
    :doc_dir  => '#{@doc_dir}',
    :help_dir => '#{@help_dir}',
    :conf_dir => '#{@conf_dir}',
    :lib_dir  => '#{@lib_dir}',
    :installed => {
      :files => #{@installed_files.pretty_inspect.strip},
      :dirs => #{@installed_dirs.pretty_inspect.strip},
    },
  }
end
|
      end
    end

    def cp_( source, dest )
      cp source, dest
      case source
        when Array
          source.each do |f|
            @installed_files << "#{dest}/#{File.basename(f)}"
          end
        else
          @installed_files << "#{dest}/#{File.basename(source)}"
      end
    end

    def mkdir_( dir )
      begin
        mkdir_p dir, :mode => 0755
      rescue Errno::EEXIST
        # Don't panic if the directory already exists
      end
      @installed_dirs << dir
    end

    def install_( source, dest )
      # Rewrite bang line
      current_interpreter = File.readlink( "/proc/#{Process.pid}/exe" )
      tmp = "diakonos-#{rand(9999999)}.tmp"
      command = %{/bin/bash -c 'cat <( echo "#!#{current_interpreter}" ) <( tail -n +2 #{source} ) > #{tmp}'}
      if @verbose
        puts command
      end
      if ! @pretend
        system command
      end

      installed = "#{dest}/#{File.basename(source)}"
      install tmp, installed, :mode => 0755
      rm_f tmp
      @installed_files << installed
    end

    def run
      # Libraries
      cp_ 'lib/diakonos.rb', @lib_dir

      dir = "#{@lib_dir}/diakonos"
      mkdir_ dir
      lib_files = Dir[ 'lib/diakonos/*.rb' ].reject { |f| f =~ /installation\.rb/ }
      cp_ lib_files, dir

      dir = "#{@lib_dir}/diakonos/vendor"
      mkdir_ dir
      cp_ Dir[ 'lib/diakonos/vendor/*.rb' ], dir

      # Configuration
      cp_ %w( diakonos.conf diakonos-256-colour.conf ), @conf_dir

      # Executables
      install_ 'bin/diakonos', @bin_dir

      # Documentation
      dir = "#{@doc_dir}/#{@versioned_package}"
      @help_dir = "#{dir}/help"
      mkdir_ @help_dir
      cp_ %w( README CHANGELOG LICENCE ), dir
      cp_ Dir[ 'help/*' ], @help_dir

      write_installation_settings
    end
  end
end

installer = Diakonos::Installer.new
installer.run

puts %{
Diakonos #{Diakonos::VERSION} (#{Diakonos::LAST_MODIFIED}) installed.
Diakonos can be uninstalled by running:

  diakonos --uninstall

Thank you for installing Diakonos.  Have a stupendous day!  :)

}
module Diakonos
  class Diakonos

    def new_session( filepath )
      basename = File.basename( filepath )
      if ! pid_session?( filepath )
        name = basename
      end
      @session = {
        'filename' => File.expand_path( filepath ),
        'settings' => Hash.new,
        'name' => name,
        'buffers' => [],
        'buffer_current' => 1,
        'dir' => Dir.getwd,
      }
    end

    def initialize_session
      @session_dir = "#{@diakonos_home}/sessions"
      mkdir @session_dir
      new_session "#{@session_dir}/#{Process.pid}"
    end

    def session_file_hash_for( filepath )
      filepath, line_number = parse_filename_and_line_number( filepath )
      {
        'filepath'  => filepath,
        'read_only' => false,
        'cursor'    => {
          'row' => line_number || 0,
          'col' => 0,
        },
        'display'   => {
          'top_line'    => 0,
          'left_column' => 0
        },
      }
    end

    def load_session_data( filename )
      return  if ! File.exist? filename

      File.open( filename ) do |f|
        loaded = YAML::load( f ) or break

        if(
          loaded[ 'filename' ] &&
          loaded[ 'settings' ] &&
          loaded[ 'settings' ].respond_to?( :values ) &&
          loaded.has_key?( 'name' ) &&
          (
            loaded[ 'files' ] &&
            loaded[ 'files' ].respond_to?( :each ) ||
            loaded[ 'buffers' ] &&
            loaded[ 'buffers' ].respond_to?( :each )
          )
        )
          # Convert old sessions
          if loaded[ 'files' ]
            loaded[ 'buffers' ] = loaded[ 'files' ].map { |f|
              session_file_hash_for f
            }
            loaded.delete 'files'
          end
          @session = loaded
        end
      end
    end

    def load_session( session_file )
      load_session_data session_file
      if @session
        @files.concat @session['buffers']
        rlh = @session['readline_histories']
        if rlh
          @rlh_general  = rlh['general'] || @rlh_general
          @rlh_files    = rlh['files'] || @rlh_files
          @rlh_search   = rlh['search'] || @rlh_search
          @rlh_shell    = rlh['shell'] || @rlh_shell
          @rlh_help     = rlh['help'] || @rlh_help
          @rlh_sessions = rlh['sessions'] || @rlh_sessions
        end
        merge_session_settings
      end
    end

    def save_session( session_file = @session[ 'filename' ] )
      return  if session_file.nil?
      return  if @testing && pid_session?( session_file )

      @session[ 'buffers' ] = @buffers.reject { |buffer|
        buffer.name.nil?
      }.collect { |buffer|
        {
          'filepath' => buffer.name,
          'read_only' => buffer.read_only,
          'cursor'   => {
            'row' => buffer.last_row,
            'col' => buffer.last_col,
          },
          'display'  => {
            'top_line'    => buffer.top_line,
            'left_column' => buffer.left_column
          },
          'last_search_regexps' => buffer.last_search_regexps.map { |r| r.to_s },
        }
      }.compact

      @session['readline_histories'] = {
        'general'  => @rlh_general,
        'files'    => @rlh_files,
        'search'   => @rlh_search,
        'shell'    => @rlh_shell,
        'help'     => @rlh_help,
        'sessions' => @rlh_sessions,
      }

      File.open( session_file, 'w' ) do |f|
        f.puts @session.to_yaml
      end
    end

    def session_filepath_for( session_id )
      if session_id && session_id !~ %r{/}
        "#{@session_dir}/#{session_id}"
      else
        session_id
      end
    end

    def pid_session?( path = @session[ 'filename' ] )
      %r{/\d+$} === path
    end

    def session_filepaths
      @session[ 'buffers' ].map { |b| b[ 'filepath' ] }
    end

    def session_startup
      if @session_to_load
        pid_session = @session
        @session = nil
        session_path = session_filepath_for( @session_to_load )
        load_session session_path
        if ! @session
          new_session session_path
        end
      else
        session_buffers = []

        session_files = Dir[ "#{@session_dir}/*" ].grep( %r{/\d+$} )
        pids = session_files.map { |sf| sf[ %r{/(\d+)$}, 1 ].to_i }
        pids.each do |pid|
          begin
            Process.kill 0, pid
            session_files.reject! { |sf| pid_session? sf }
          rescue Errno::ESRCH, Errno::EPERM
            # Process is no longer alive, so we consider the session stale
          end
        end

        session_files.each_with_index do |session_file,index|
          session_buffers << open_file( session_file )

          choice = get_choice(
            "#{session_files.size} unclosed session(s) found.  Open the above files?  (session #{index+1} of #{session_files.size})",
            [ CHOICE_YES, CHOICE_NO, CHOICE_DELETE ],
            index > 0 ?  CHOICE_NO : nil
          )

          case choice
          when CHOICE_YES
            load_session session_file
            if @session
              File.delete session_file
              break
            end
          when CHOICE_DELETE
            File.delete session_file
          end
        end

        if session_buffers.empty? && @files.empty? && @settings[ 'session.default_session' ]
          session_file = session_filepath_for( @settings[ 'session.default_session' ] )
          if File.exist? session_file
            load_session session_file
          end
        end
      end

      session_buffers
    end

    def cleanup_session
      if pid_session? && File.exists?( @session[ 'filename' ] )
        File.delete @session[ 'filename' ]
      end
    end
  end
end

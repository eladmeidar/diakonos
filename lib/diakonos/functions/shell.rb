module Diakonos
  module Functions

    def chdir( dir = nil )
      dir ||= get_user_input( "Change to directory: ", initial_text: Dir.pwd )
      if dir
        Dir.chdir dir
      end
    end

    def sub_shell_variables( string )
      return  if string.nil?

      retval = string.dup

      # Current buffer filename
      retval.gsub!( /\$f/, ( $1 or "" ) + File.expand_path( @current_buffer.name || "" ) )
      # Current buffer dir
      retval.gsub!( /\$d/, ( $1 or "" ) + File.dirname( File.expand_path( @current_buffer.name || '' ) ) )

      # space-separated list of all buffer filenames
      name_array = Array.new
      @buffers.each_value do |b|
        name_array.push b.name
      end
      retval.gsub!( /\$F/, ( $1 or "" ) + ( name_array.join(' ') or "" ) )

      # Get user input, sub it in
      if retval =~ /\$i/
        user_input = get_user_input(
          "Argument: ",
          history: @rlh_shell,
          initial_text: @current_buffer.selected_string
        )
        retval.gsub!( /\$i/, user_input )
      end

      # Current clipboard text
      if retval =~ /\$[ck]/
        clip_filename = @diakonos_home + "/clip.txt"
        File.open( clip_filename, "w" ) do |clipfile|
          if @clipboard.clip
            clipfile.puts( @clipboard.clip.join( "\n" ) )
          end
        end
        retval.gsub!( /\$[ck]/, clip_filename )
      end

      # Currently selected text
      if retval =~ /\$s/
        text_filename = @diakonos_home + "/selected.txt"

        File.open( text_filename, "w" ) do |textfile|
          selected_text = @current_buffer.selected_text
          if selected_text
            textfile.puts( selected_text.join( "\n" ) )
          end
        end
        retval.gsub!( /\$s/, text_filename )
      end

      retval
    end

    def shell( command_ = nil, result_filename = 'shell-result.txt' )
      command = command_ || get_user_input( "Command: ", history: @rlh_shell )

      return  if command.nil?

      command = sub_shell_variables( command )

      completed = false
      result_file = "#{@diakonos_home}/#{result_filename}"
      File.open( result_file , "w" ) do |f|
        Curses::close_screen

        stdin, stdout, stderr = Open3.popen3( command )

        t1 = Thread.new do
          stdout.each_line do |line|
            f.puts line
          end
        end
        t2 = Thread.new do
          stderr.each_line do |line|
            f.puts line
          end
        end

        catch :stop do
          loop do
            begin
              Timeout::timeout( 5 ) do
                t1.join
                t2.join
                Curses::init_screen
                refresh_all
                completed = true
                throw :stop
              end
            rescue Timeout::Error => e
              choice = get_choice(
                "Keep waiting for shell results?",
                [ CHOICE_YES, CHOICE_NO ],
                CHOICE_YES
              )
              if choice != CHOICE_YES
                t1.terminate
                t2.terminate
                throw :stop
              end
            end
          end
        end

      end
      if File.size?( result_file )
        open_file result_file
        set_iline "#{completed ? '' : '(interrupted) '}Results for: #{command}"
      else
        set_iline "Empty result for: #{command}"
      end
    end

    def execute( command_ = nil )
      command = command_ || get_user_input( "Command: ", history: @rlh_shell )

      return  if command.nil?

      command = sub_shell_variables( command )

      Curses::close_screen

      success = system( command )
      if not success
        result = "Could not execute: #{command}"
      else
        result = "Return code: #{$?}"
      end

      Curses::init_screen
      refresh_all

      set_iline result
    end

    def paste_shell_result( command_ = nil )
      command = command_ || get_user_input( "Command: ", history: @rlh_shell )

      return  if command.nil?

      command = sub_shell_variables( command )

      Curses::close_screen

      begin
        @current_buffer.paste( `#{command} 2<&1`.split( /\n/, -1 ) )
      rescue Exception => e
        debug_log e.message
        debug_log e.backtrace.join( "\n\t" )
        show_exception e
      end

      Curses::init_screen
      refresh_all
    end

    def spawn( command_ = nil )
      command = command_ || get_user_input( "Command: ", history: @rlh_shell )

      return  if command.nil?

      command = sub_shell_variables( command )

      Thread.new do
        if system( command )
          set_iline "Return code #{$?} from '#{command}'"
        else
          set_iline "Error code #{$?} executing '#{command}'"
        end
      end
    end

  end
end
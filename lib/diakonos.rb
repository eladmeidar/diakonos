#!/usr/bin/env ruby

# == Diakonos
#
# A usable console text editor.
# :title: Diakonos
#
# Author:: Pistos (irc.freenode.net)
# http://purepistos.net/diakonos
#
# This software is released under the GNU General Public License.
# http://www.gnu.org/copyleft/gpl.html
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

require "curses"
require "open3"
require "thread"
require "English"
require 'set'

#$profiling = true

#if $profiling
    #require 'ruby-prof'
#end

include Curses

class Object
    def deep_clone
        Marshal::load( Marshal.dump( self ) )
    end
end

module Enumerable
    # Returns [array-index, string-index, string-index] triples for each match.
    def grep_indices( regexp )
        array = Array.new
        each_with_index do |element,index|
            element.scan( regexp ) do |match_text|
                match = Regexp.last_match
                strindex = match.begin( 0 )
                array.push [ index, strindex, strindex + match_text.length ]
            end
        end
        return array
    end
end

class Regexp
    def uses_bos
        return ( source[ 0 ] == ?^ )
    end
end

class SizedArray < Array
    attr_reader :capacity
    
    def initialize( capacity = 10, *args )
        @capacity = capacity
        super( *args )
    end
    
    def resize
        if size > @capacity
            slice!( (0...-@capacity) )
        end
    end
    private :resize
    
    def concat( other_array )
        super( other_array )
        resize
        return self
    end
    
    def fill( *args )
        retval = super( *args )
        resize
        return self
    end
    
    def <<( item )
        retval = super( item )
        if size > @capacity
            retval = shift
        end
        return retval
    end
    
    def push( item )
        self << item
    end
    
    def unshift( item )
        retval = super( item )
        if size > @capacity
            retval = pop
        end
        return retval
    end
end

class Hash
    # path is an array of hash keys
    # This method deletes a path of hash keys, with each step in the path
    # being a recursively deeper key in a hash tree.
    # Returns the possibly modified hash.
    def deleteKeyPath( path )
        if path.length > 1
            subtree = self[ path[ 0 ] ]
            if subtree.respond_to?( :deleteKeyPath )
                subtree.deleteKeyPath( path[ 1..-1 ] )
                if subtree.empty?
                    delete( path[ 0 ] )
                end
            end
        elsif path.length == 1
            delete( path[ 0 ] )
        end
        
        return self
    end
    
    def setKeyPath( path, leaf )
        if path.length > 1
            node = self[ path[ 0 ] ]
            if not node.respond_to?( :setKeyPath )
                node = self[ path[ 0 ] ] = Hash.new
            end
            node.setKeyPath( path[ 1..-1 ], leaf )
        elsif path.length == 1
            self[ path[ 0 ] ] = leaf
        end
        
        return self
    end
    
    def getNode( path )
        node = self[ path[ 0 ] ]
        if path.length > 1
            if node != nil and node.respond_to?( :getNode )
                return node.getNode( path[ 1..-1 ] )
            end
        elsif path.length == 1
            return node
        end
        
        return nil
    end
    
    def getLeaf( path )
        node = getNode( path )
        if node.respond_to?( :getNode )
            # Only want a leaf node
            return nil
        else
            return node
        end
    end
    
    def leaves( _leaves = Set.new )
        each_value do |value|
            if value.respond_to?( :leaves )
                _leaves.merge value.leaves( _leaves )
            else
                _leaves << value
            end
        end
        
        return _leaves
    end
    
    def paths_and_leaves( path_so_far = [], _paths_and_leaves = Set.new )
        each do |key, value|
            if value.respond_to?( :paths_and_leaves )
                _paths_and_leaves.merge(
                    value.paths_and_leaves(
                        path_so_far + [ key ],
                        _paths_and_leaves
                    )
                )
            else
                _paths_and_leaves << {
                    :path => path_so_far + [ key ],
                    :leaf => value
                }
            end
        end
        
        return _paths_and_leaves
    end
    
    def each_path_and_leaf( path_so_far = [] )
        each do |key, value|
            if value.respond_to?( :each_path_and_leaf )
                value.each_path_and_leaf( path_so_far + [ key ] ) { |path, leaf| yield( path, leaf ) }
            else
                yield( path_so_far + [ key ], value )
            end
        end
    end
end

class BufferHash < Hash
    def [] ( key )
        case key
            when String
                key = File.expand_path( key )
        end
        return super
    end
    
    def []= ( key, value )
        case key
            when String
                key = File.expand_path( key )
        end
        super
    end
end

class Array
    def to_keychain_s
        chain_str = ""
        each do |key|
            chain_str << key.keyString + " "
        end
        return chain_str
    end
end

class String
    def subHome
        return gsub( /~/, ENV[ "HOME" ] )
    end

    def keyCode
        retval = nil
        case downcase
            when "down"
                retval = KEY_DOWN
            when "up"
                retval = KEY_UP
            when "left"
                retval = KEY_LEFT
            when "right"
                retval = KEY_RIGHT
            when "home"
                retval = KEY_HOME
            when "end"
                retval = KEY_END
            when "insert", "ins"
                retval = KEY_IC
            when "delete", "del"
                retval = KEY_DC
            when "backspace"
                retval = Diakonos::BACKSPACE
            when "tab"
                retval = 9
            when "pageup", "page-up"
                retval = KEY_PPAGE
            when "pagedown", "page-down"
                retval = KEY_NPAGE
            when "enter", "return"
                retval = Diakonos::ENTER
            when "numpad7", "keypad7", "kp-7"
                retval = KEY_A1
            when "numpad9", "keypad9", "kp-9"
                retval = KEY_A3
            when "numpad5", "keypad5", "kp-5"
                retval = KEY_B2
            when "numpad1", "keypad1", "kp-1"
                retval = KEY_C1
            when "numpad3", "keypad3", "kp-3"
                retval = KEY_C3
            when "escape", "esc"
                retval = Diakonos::ESCAPE
            when "space"
                retval = 32
            when "ctrl+space"
                retval = 0
            when "find"
                retval = KEY_FIND
            when "select"
                retval = KEY_SELECT
            when "suspend"
                retval = KEY_SUSPEND
            when /^f(\d\d?)$/
                retval = KEY_F0 + $1.to_i
            when /^ctrl\+[a-gi-z]$/
                retval = downcase[ -1 ] - 96
            when /^ctrl\+h$/
                retval = Diakonos::CTRL_H
            when /^alt\+(.)$/
                retval = [ Diakonos::ESCAPE, $1[ 0 ] ]
            when /^ctrl\+alt\+(.)$/, /^alt\+ctrl\+(.)$/
                retval = [ Diakonos::ESCAPE, downcase[ -1 ] - 96 ]
            when /^keycode(\d+)$/
                retval = $1.to_i
            when /^.$/
                retval = self[ 0 ]
        end
        if retval.class != Array
            retval = [ retval ]
        end
        return retval
    end

    def toFormatting
        formatting = A_NORMAL
        split( /\s+/ ).each do |format|
            case format.downcase
                when "normal"
                    formatting = A_NORMAL
                when "black", "0"
                    formatting = formatting | color_pair( COLOR_BLACK )
                when "red", "1"
                    formatting = formatting | color_pair( COLOR_RED )
                when "green", "2"
                    formatting = formatting | color_pair( COLOR_GREEN )
                when "yellow", "brown", "3"
                    formatting = formatting | color_pair( COLOR_YELLOW )
                when "blue", "4"
                    formatting = formatting | color_pair( COLOR_BLUE )
                when "magenta", "purple", "5"
                    formatting = formatting | color_pair( COLOR_MAGENTA )
                when "cyan", "6"
                    formatting = formatting | color_pair( COLOR_CYAN )
                when "white", "7"
                    formatting = formatting | color_pair( COLOR_WHITE )
                when "standout", "s", "so"
                    formatting = formatting | A_STANDOUT
                when "underline", "u", "un", "ul"
                    formatting = formatting | A_UNDERLINE
                when "reverse", "r", "rev", "inverse", "i", "inv"
                    formatting = formatting | A_REVERSE
                when "blink", "bl", "blinking"
                    formatting = formatting | A_BLINK
                when "dim", "d"
                    formatting = formatting | A_DIM
                when "bold", "b", "bo"
                    formatting = formatting | A_BOLD
                else
                    if ( colour_number = format.to_i ) > COLOR_WHITE
                        formatting = formatting | color_pair( colour_number )
                    end
            end
        end
        return formatting
    end

    def toColourConstant
        retval = COLOR_WHITE
        case downcase
            when "black", "0"
                retval = COLOR_BLACK
            when "red", "1"
                retval = COLOR_RED
            when "green", "2"
                retval = COLOR_GREEN
            when "yellow", "brown", "3"
                retval = COLOR_YELLOW
            when "blue", "4"
                retval = COLOR_BLUE
            when "magenta", "purple", "5"
                retval = COLOR_MAGENTA
            when "cyan", "6"
                retval = COLOR_CYAN
            when "white", "7"
                retval = COLOR_WHITE
        end
    end
    
    def toDirection( default = :down )
        direction = nil
        case self
            when "up"
                direction = :up
            when /other/
                direction = :opposite
            when "down"
                direction = :down
            when "forward"
                direction = :forward
            when "backward"
                direction = :backward
            else
                direction = default
        end
        return direction
    end
    
    def to_a
        return [ self ]
    end

    def to_b
        retval = false
        case downcase
            when "true", "t", "1", "yes", "y", "on", "+"
                retval = true
        end
        return retval
    end

    def indentation_level( indent_size, indent_roundup, tab_size = Diakonos::DEFAULT_TAB_SIZE, indent_ignore_charset = nil )
        if indent_ignore_charset == nil
            level = 0
            if self =~ /^([\s]+)/
                #whitespace = $1.gsub( /\t/, ' ' * tab_size )
                whitespace = $1.expandTabs( tab_size )
                level = whitespace.length / indent_size
                if indent_roundup and ( whitespace.length % indent_size > 0 )
                    level += 1
                end
            end
        else
            if self =~ /^[\s#{indent_ignore_charset}]*$/ or self == ""
                level = -1
            elsif self =~ /^([\s#{indent_ignore_charset}]+)/
                #whitespace = $1.gsub( /\t/, ' ' * tab_size )
                whitespace = $1.expandTabs( tab_size )
                level = whitespace.length / indent_size
                if indent_roundup and ( whitespace.length % indent_size > 0 )
                    level += 1
                end
            else
                level = 0
            end
        end
        
        return level
    end
    
    def expandTabs( tab_size = Diakonos::DEFAULT_TAB_SIZE )
        s = dup
        while s.sub!( /\t/ ) { |match_text|
                match = Regexp.last_match
                index = match.begin( 0 )
                # Return value for block:
                " " * ( tab_size - ( index % tab_size ) )
            }
        end
        return s
    end
    
    def newlineSplit
        retval = split( /\\n/ )
        if self =~ /\\n$/
            retval << ""
        end
        if retval.length > 1
            retval[ 0 ] << "$"
            retval[ 1..-2 ].collect do |el|
                "^" << el << "$"
            end
            retval[ -1 ] = "^" << retval[ -1 ]
        end
        return retval
    end
    
    # Works like normal String#index except returns the index
    # of the first matching regexp group if one or more groups are specified
    # in the regexp. Both the index and the matched text are returned.
    def group_index( regexp, offset = 0 )
        if regexp.class != Regexp
            return index( regexp, offset )
        end
        
        i = nil
        match_text = nil
        working_offset = 0
        loop do
            index( regexp, working_offset )
            match = Regexp.last_match
            if match
                i = match.begin( 0 )
                match_text = match[ 0 ]
                if match.length > 1
                    # Find first matching group
                    1.upto( match.length - 1 ) do |match_item_index|
                        if match[ match_item_index ] != nil
                            i = match.begin( match_item_index )
                            match_text = match[ match_item_index ]
                            break
                        end
                    end
                end
                
                break if i >= offset
            else
                i = nil
                break
            end
            working_offset += 1
        end
        
        return i, match_text
    end
    
    # Works like normal String#rindex except returns the index
    # of the first matching regexp group if one or more groups are specified
    # in the regexp. Both the index and the matched text are returned.
    def group_rindex( regexp, offset = length )
        if regexp.class != Regexp
            return rindex( regexp, offset )
        end
        
        i = nil
        match_text = nil
        working_offset = length
        loop do
            rindex( regexp, working_offset )
            match = Regexp.last_match
            if match
                i = match.end( 0 ) - 1
                match_text = match[ 0 ]
                if match.length > 1
                    # Find first matching group
                    1.upto( match.length - 1 ) do |match_item_index|
                        if match[ match_item_index ] != nil
                            i = match.end( match_item_index ) - 1
                            match_text = match[ match_item_index ]
                            break
                        end
                    end
                end
                
                if match_text == ""
                    # Assume that an empty string means that it matched $
                    i += 1
                end
                
                break if i <= offset
            else
                i = nil
                break
            end
            working_offset -= 1
        end
        
        return i, match_text
    end
    
    def movement?
        return ( ( self =~ /^((cursor|page|scroll)(Up|Down|Left|Right)|find)/ ) != nil )
    end
end

module KeyCode
    KEYSTRINGS = [
        "ctrl+space",   # 0
        "ctrl+a",       # 1
        "ctrl+b",       # 2
        "ctrl+c",       # 3
        "ctrl+d",       # 4
        "ctrl+e",       # 5
        "ctrl+f",       # 6
        "ctrl+g",       # 7
        nil,            # 8
        "tab",          # 9
        "ctrl+j",       # 10
        "ctrl+k",       # 11
        "ctrl+l",       # 12
        "enter",        # 13
        "ctrl+n",       # 14
        "ctrl+o",       # 15
        "ctrl+p",       # 16
        "ctrl+q",       # 17
        "ctrl+r",       # 18
        "ctrl+s",       # 19
        "ctrl+t",       # 20
        "ctrl+u",       # 21
        "ctrl+v",       # 22
        "ctrl+w",       # 23
        "ctrl+x",       # 24
        "ctrl+y",       # 25
        "ctrl+z",       # 26
        "esc",          # 27
        nil,            # 28
        nil,            # 29
        nil,            # 30
        nil,            # 31
        "space",        # 32
        33.chr, 34.chr, 35.chr, 36.chr, 37.chr, 38.chr, 39.chr,
        40.chr, 41.chr, 42.chr, 43.chr, 44.chr, 45.chr, 46.chr, 47.chr, 48.chr, 49.chr,
        50.chr, 51.chr, 52.chr, 53.chr, 54.chr, 55.chr, 56.chr, 57.chr, 58.chr, 59.chr,
        60.chr, 61.chr, 62.chr, 63.chr, 64.chr, 65.chr, 66.chr, 67.chr, 68.chr, 69.chr,
        70.chr, 71.chr, 72.chr, 73.chr, 74.chr, 75.chr, 76.chr, 77.chr, 78.chr, 79.chr,
        80.chr, 81.chr, 82.chr, 83.chr, 84.chr, 85.chr, 86.chr, 87.chr, 88.chr, 89.chr,
        90.chr, 91.chr, 92.chr, 93.chr, 94.chr, 95.chr, 96.chr, 97.chr, 98.chr, 99.chr,
        100.chr, 101.chr, 102.chr, 103.chr, 104.chr, 105.chr, 106.chr, 107.chr, 108.chr, 109.chr,
        110.chr, 111.chr, 112.chr, 113.chr, 114.chr, 115.chr, 116.chr, 117.chr, 118.chr, 119.chr,
        120.chr, 121.chr, 122.chr, 123.chr, 124.chr, 125.chr, 126.chr,
        "backspace"    # 127
    ]

    def keyString
        if self.class == Fixnum
            retval = KEYSTRINGS[ self ]
        end
        if retval == nil
            case self
                when KEY_DOWN
                    retval = "down"
                when KEY_UP
                    retval = "up"
                when KEY_LEFT
                    retval = "left"
                when KEY_RIGHT
                    retval = "right"
                when KEY_HOME
                    retval = "home"
                when KEY_END
                    retval = "end"
                when KEY_IC
                    retval = "insert"
                when KEY_DC
                    retval = "delete"
                when KEY_PPAGE
                    retval = "page-up"
                when KEY_NPAGE
                    retval = "page-down"
                when KEY_A1
                    retval = "numpad7"
                when KEY_A3
                    retval = "numpad9"
                when KEY_B2
                    retval = "numpad5"
                when KEY_C1
                    retval = "numpad1"
                when KEY_C3
                    retval = "numpad3"
                when KEY_FIND
                    retval = "find"
                when KEY_SELECT
                    retval = "select"
                when KEY_SUSPEND
                    retval = "suspend"
                when KEY_F0..(KEY_F0 + 24)
                    retval = "f" + (self - KEY_F0).to_s
                when Diakonos::CTRL_H
                    retval = "ctrl+h"
                when KEY_RESIZE
                    retval = "resize"
                when Diakonos::RESIZE2
                    retval = "resize2"
            end
        end
        if retval == nil and self.class == Fixnum
            retval = "keycode#{self}"
        end
        return retval
    end
end

class Fixnum
    include KeyCode

    def fit( min, max )
        return self if max < min
        return min if self < min
        return max if self > max
        return self
    end
end

class Bignum
    include KeyCode
end

class TextMark
    attr_reader :formatting, :start_row, :start_col, :end_row, :end_col

    def initialize( start_row, start_col, end_row, end_col, formatting )
        @start_row = start_row
        @start_col = start_col
        @end_row = end_row
        @end_col = end_col
        @formatting = formatting
    end

    def to_s
        return "(#{start_row},#{start_col})-(#{end_row},#{end_col}) #{formatting}"
    end
end

class Bookmark
    attr_reader :buffer, :row, :col, :name

    def initialize( buffer, row, col, name = nil )
        @buffer = buffer
        @row = row
        @col = col
        @name = name
    end

    def == (other)
        return false if other == nil
        return ( @buffer == other.buffer and @row == other.row and @col == other.col )
    end

    def <=> (other)
        return nil if other == nil
        comparison = ( $diakonos.bufferToNumber( @buffer ) <=> $diakonos.bufferToNumber( other.buffer ) )
        return comparison if comparison != 0
        comparison = ( @row <=> other.row )
        return comparison if comparison != 0
        comparison = ( @col <=> other.col )
        return comparison
    end

    def < (other)
        return ( ( self <=> other ) < 0 )
    end
    def > (other)
        return ( ( self <=> other ) > 0 )
    end
    
    def incRow( increment )
        row += increment
    end
    def incCol( increment )
        col += increment
    end
    def shift( row_inc, col_inc )
        row += row_inc
        col += col_inc
    end

    def to_s
        return "[#{@name}|#{@buffer.name}:#{@row+1},#{@col+1}]"
    end
end

class CTag
    attr_reader :file, :command, :kind, :rest
    
    def initialize( file, command, kind, rest )
        @file = file
        @command = command
        @kind = kind
        @rest = rest
    end
    
    def to_s
        return "#{@file}:#{@command} (#{@kind}) #{@rest}"
    end
    
    def == ( other )
        return (
            other != nil and
            @file == other.file and
            @command == other.command and
            @kind == other.kind and
            @rest == other.rest
        )
    end
end

class Finding
    attr_reader :start_row, :start_col, :end_row, :end_col
    attr_writer :end_row, :end_col
    
    def initialize( start_row, start_col, end_row, end_col )
        @start_row = start_row
        @start_col = start_col
        @end_row = end_row
        @end_col = end_col
    end
    
    def match( regexps, lines )
        retval = true
        
        i = @start_row + 1
        regexps[ 1..-1 ].each do |re|
            if lines[ i ] !~ re
                retval = false
                break
            end
            @end_row = i
            @end_col = Regexp.last_match[ 0 ].length
            i += 1
        end
        
        return retval
    end
end

class Buffer
    attr_reader :name, :modified, :original_language, :changing_selection, :read_only,
        :last_col, :last_row, :tab_size, :last_screen_x, :last_screen_y, :last_screen_col
    attr_writer :desired_column, :read_only

    SELECTION = 0
    TYPING = true
    STOPPED_TYPING = true
    STILL_TYPING = false
    NO_SNAPSHOT = true
    DO_DISPLAY = true
    DONT_DISPLAY = false
    READ_ONLY = true
    READ_WRITE = false
    ROUND_DOWN = false
    ROUND_UP = true
    PAD_END = true
    DONT_PAD_END = false
    MATCH_CLOSE = true
    MATCH_ANY = false
    START_FROM_BEGINNING = -1
    DO_PITCH_CURSOR = true
    DONT_PITCH_CURSOR = false
    CLEAR_STACK_POINTER = true
    DONT_CLEAR_STACK_POINTER = false

    # Set name to nil to create a buffer that is not associated with a file.
    def initialize( diakonos, name, read_only = false )
        @diakonos = diakonos
        @name = name
        @modified = false
        @last_modification_check = Time.now

        @buffer_states = Array.new
        @cursor_states = Array.new
        if @name != nil
            @name = @name.subHome
            if FileTest.exists? @name
                @lines = IO.readlines( @name )
                if ( @lines.length == 0 ) or ( @lines[ -1 ][ -1..-1 ] == "\n" )
                    @lines.push ""
                end
                @lines = @lines.collect do |line|
                    line.chomp
                end
            else
                @lines = Array.new
                @lines[ 0 ] = ""
            end
        else
            @lines = Array.new
            @lines[ 0 ] = ""
        end
        @current_buffer_state = 0

        @top_line = 0
        @left_column = 0
        @desired_column = 0
        @mark_anchor = nil
        @text_marks = Array.new
        @last_search_regexps = nil
        @highlight_regexp = nil
        @last_search = nil
        @changing_selection = false
        @typing = false
        @last_col = 0
        @last_screen_col = 0
        @last_screen_y = 0
        @last_screen_x = 0
        @last_row = 0
        @read_only = read_only
        @bookmarks = Array.new
        @lang_stack = Array.new
        @cursor_stack = Array.new
        @cursor_stack_pointer = nil

        configure

        if @settings[ "convert_tabs" ]
            tabs_subbed = false
            @lines.collect! do |line|
                new_line = line.expandTabs( @tab_size )
                tabs_subbed = ( tabs_subbed or new_line != line )
                # Return value for collect:
                new_line
            end
            @modified = ( @modified or tabs_subbed )
            if tabs_subbed
                @diakonos.setILine "(spaces substituted for tab characters)"
            end
        end
            
        @buffer_states[ @current_buffer_state ] = @lines
        @cursor_states[ @current_buffer_state ] = [ @last_row, @last_col ]
    end

    def configure(
            language = (
                @diakonos.getLanguageFromShaBang( @lines[ 0 ] ) or
                @diakonos.getLanguageFromName( @name ) or
                Diakonos::LANG_TEXT
            )
        )
        reset_win_main
        setLanguage language
        @original_language = @language
    end
    
    def reset_win_main
        @win_main = @diakonos.win_main
    end

    def setLanguage( language )
        @settings = @diakonos.settings
        @language = language
        @token_regexps = ( @diakonos.token_regexps[ @language ] or Hash.new )
        @close_token_regexps = ( @diakonos.close_token_regexps[ @language ] or Hash.new )
        @token_formats = ( @diakonos.token_formats[ @language ] or Hash.new )
        @indenters = @diakonos.indenters[ @language ]
        @unindenters = @diakonos.unindenters[ @language ]
        @preventers = @settings[ "lang.#{@language}.indent.preventers" ]
        @auto_indent = @settings[ "lang.#{@language}.indent.auto" ]
        @indent_size = ( @settings[ "lang.#{@language}.indent.size" ] or 4 )
        @indent_roundup = ( @settings[ "lang.#{@language}.indent.roundup" ] or true )
        @default_formatting = ( @settings[ "lang.#{@language}.format.default" ] or A_NORMAL )
        @selection_formatting = ( @settings[ "lang.#{@language}.format.selection" ] or A_REVERSE )
        @indent_ignore_charset = ( @settings[ "lang.#{@language}.indent.ignore.charset" ] or "" )
        @tab_size = ( @settings[ "lang.#{@language}.tabsize" ] or Diakonos::DEFAULT_TAB_SIZE )
    end
    protected :setLanguage

    def [] ( arg )
        return @lines[ arg ]
    end
    
    def == (other)
        return false if other == nil
        return ( name == other.name )
    end

    def length
        return @lines.length
    end

    def nice_name
        return ( @name || @settings[ "status.unnamed_str" ] )
    end

    def display
        return if not @diakonos.do_display
        
        Thread.new do
            #if $profiling
                #RubyProf.start
            #end
                    
            if @diakonos.display_mutex.try_lock
                begin
                    curs_set 0
                    
                    @continued_format_class = nil
                    
                    @pen_down = true
                    
                    # First, we have to "draw" off-screen, in order to check for opening of
                    # multi-line highlights.
                    
                    # So, first look backwards from the @top_line to find the first opening
                    # regexp match, if any.
                    index = @top_line - 1
                    @lines[ [ 0, @top_line - @settings[ "view.lookback" ] ].max...@top_line ].reverse_each do |line|
                        open_index = -1
                        open_token_class = nil
                        open_match_text = nil
                        
                        open_index, open_token_class, open_match_text = findOpeningMatch( line )
                        
                        if open_token_class != nil
                            @pen_down = false
                            @lines[ index...@top_line ].each do |line|
                                printLine line
                            end
                            @pen_down = true
                            
                            break
                        end
                        
                        index = index - 1
                    end
                    
                    # Draw each on-screen line.
                    y = 0
                    @lines[ @top_line...(@diakonos.main_window_height + @top_line) ].each_with_index do |line, row|
                        @win_main.setpos( y, 0 )
                        printLine line.expandTabs( @tab_size )
                        @win_main.setpos( y, 0 )
                        paintMarks @top_line + row
                        y += 1
                    end
                    
                    # Paint the empty space below the file if the file is too short to fit in one screen.
                    ( y...@diakonos.main_window_height ).each do |y|
                        @win_main.setpos( y, 0 )
                        @win_main.attrset @default_formatting
                        linestr = " " * cols
                        if @settings[ "view.nonfilelines.visible" ]
                            linestr[ 0 ] = ( @settings[ "view.nonfilelines.character" ] or "~" )
                        end
                        
                        @win_main.addstr_ linestr
                    end
                    
                    @win_main.setpos( @last_screen_y , @last_screen_x )
                    @win_main.refresh
                    
                    if @language != @original_language
                        setLanguage( @original_language )
                    end
                    
                    curs_set 1
                rescue Exception => e
                    $diakonos.log( "Display Exception:" )
                    $diakonos.log( e.message )
                    $diakonos.log( e.backtrace.join( "\n" ) )
                    showException e
                end
                @diakonos.display_mutex.unlock
                @diakonos.displayDequeue
            else
                @diakonos.displayEnqueue( self )
            end
            
            #if $profiling
                #result = RubyProf.stop
                #printer = RubyProf::GraphHtmlPrinter.new( result )
                #File.open( "#{ENV['HOME']}/svn/diakonos/profiling/diakonos-profile-#{Time.now.to_i}.html", 'w' ) do |f|
                    #printer.print( f )
                #end
            #end
        end
        
    end

    def findOpeningMatch( line, match_close = true, bos_allowed = true )
        open_index = line.length
        open_token_class = nil
        open_match_text = nil
        match = nil
        match_text = nil
        @token_regexps.each do |token_class,regexp|
            if match = regexp.match( line )
                if match.length > 1
                    index = match.begin 1
                    match_text = match[ 1 ]
                    whole_match_index = match.begin 0
                else
                    whole_match_index = index = match.begin( 0 )
                    match_text = match[ 0 ]
                end
                if ( not regexp.uses_bos ) or ( bos_allowed and ( whole_match_index == 0 ) )
                    if index < open_index
                        if ( ( not match_close ) or @close_token_regexps[ token_class ] != nil )
                            open_index = index
                            open_token_class = token_class
                            open_match_text = match_text
                        end
                    end
                end
            end
        end

        return [ open_index, open_token_class, open_match_text ]
    end

    def findClosingMatch( line_, regexp, bos_allowed = true, start_at = 0 )
        close_match_text = nil
        close_index = nil
        if start_at > 0
            line = line_[ start_at..-1 ]
        else
            line = line_
        end
        line.scan( regexp ) do |m|
            match = Regexp.last_match
            if match.length > 1
                index = match.begin 1
                match_text = match[ 1 ]
            else
                index = match.begin 0
                match_text = match[ 0 ]
            end
            if ( not regexp.uses_bos ) or ( bos_allowed and ( index == 0 ) )
                close_index = index
                close_match_text = match_text
                break
            end
        end

        return [ close_index, close_match_text ]
    end
    protected :findClosingMatch

    # @mark_start[ "col" ] is inclusive,
    # @mark_end[ "col" ] is exclusive.
    def recordMarkStartAndEnd
        if @mark_anchor != nil
            crow = @last_row
            ccol = @last_col
            anchor_first = true
            if crow < @mark_anchor[ "row" ]
                anchor_first = false
            elsif crow > @mark_anchor[ "row" ]
                anchor_first = true
            else
                if ccol < @mark_anchor[ "col" ]
                    anchor_first = false
                end
            end
            if anchor_first
                @text_marks[ SELECTION ] = TextMark.new(
                    @mark_anchor[ "row" ],
                    @mark_anchor[ "col" ],
                    crow,
                    ccol,
                    @selection_formatting
                )
            else
                @text_marks[ SELECTION ] = TextMark.new(
                    crow,
                    ccol,
                    @mark_anchor[ "row" ],
                    @mark_anchor[ "col" ],
                    @selection_formatting
                )
            end
        else
            @text_marks[ SELECTION ] = nil
        end
    end
    
    def selection_mark
        return @text_marks[ SELECTION ]
    end

    # Prints text to the screen, truncating where necessary.
    # Returns nil if the string is completely off-screen.
    # write_cursor_col is buffer-relative, not screen-relative
    def truncateOffScreen( string, write_cursor_col )
        retval = string
        
        # Truncate based on left edge of display area
        if write_cursor_col < @left_column
            retval = retval[ (@left_column - write_cursor_col)..-1 ]
            write_cursor_col = @left_column
        end

        if retval != nil
            # Truncate based on right edge of display area
            if write_cursor_col + retval.length > @left_column + cols - 1
                new_length = ( @left_column + cols - write_cursor_col )
                if new_length <= 0
                    retval = nil
                else
                    retval = retval[ 0...new_length ]
                end
            end
        end
        
        return ( retval == "" ? nil : retval )
    end
    
    # For debugging purposes
    def quotedOrNil( str )
        if str == nil
            return "nil"
        else
            return "'#{str}'"
        end
    end
    
    def paintMarks( row )
        string = @lines[ row ][ @left_column ... @left_column + cols ]
        return if string == nil or string == ""
        string = string.expandTabs( @tab_size )
        cury = @win_main.cury
        curx = @win_main.curx
        
        @text_marks.reverse_each do |text_mark|
            if text_mark != nil
                @win_main.attrset text_mark.formatting
                if ( (text_mark.start_row + 1) .. (text_mark.end_row - 1) ) === row
                    @win_main.setpos( cury, curx )
                    @win_main.addstr_ string
                elsif row == text_mark.start_row and row == text_mark.end_row
                    expanded_col = tabExpandedColumn( text_mark.start_col, row )
                    if expanded_col < @left_column + cols
                        left = [ expanded_col - @left_column, 0 ].max
                        right = tabExpandedColumn( text_mark.end_col, row ) - @left_column
                        if left < right
                            @win_main.setpos( cury, curx + left )
                            @win_main.addstr_ string[ left...right ]
                        end
                    end
                elsif row == text_mark.start_row
                    expanded_col = tabExpandedColumn( text_mark.start_col, row )
                    if expanded_col < @left_column + cols
                        left = [ expanded_col - @left_column, 0 ].max
                        @win_main.setpos( cury, curx + left )
                        @win_main.addstr_ string[ left..-1 ]
                    end
                elsif row == text_mark.end_row
                    right = tabExpandedColumn( text_mark.end_col, row ) - @left_column
                    @win_main.setpos( cury, curx )
                    @win_main.addstr_ string[ 0...right ]
                else
                    # This row not in selection.
                end
            end
        end
    end

    def printString( string, formatting = ( @token_formats[ @continued_format_class ] or @default_formatting ) )
        return if not @pen_down
        return if string == nil

        @win_main.attrset formatting
        @win_main.addstr_ string
    end

    # This method assumes that the cursor has been setup already at
    # the left-most column of the correct on-screen row.
    # It merely unintelligently prints the characters on the current curses line,
    # refusing to print characters of the in-buffer line which are offscreen.
    def printLine( line )
        i = 0
        substr = nil
        index = nil
        while i < line.length
            substr = line[ i..-1 ]
            if @continued_format_class != nil
                close_index, close_match_text = findClosingMatch( substr, @close_token_regexps[ @continued_format_class ], i == 0 )

                if close_match_text == nil
                    printString truncateOffScreen( substr, i )
                    printPaddingFrom( line.length )
                    i = line.length
                else
                    end_index = close_index + close_match_text.length
                    printString truncateOffScreen( substr[ 0...end_index ], i )
                    @continued_format_class = nil
                    i += end_index
                end
            else
                first_index, first_token_class, first_word = findOpeningMatch( substr, MATCH_ANY, i == 0 )

                if @lang_stack.length > 0
                    prev_lang, close_token_class = @lang_stack[ -1 ]
                    close_index, close_match_text = findClosingMatch( substr, @diakonos.close_token_regexps[ prev_lang ][ close_token_class ], i == 0 )
                    if close_match_text != nil and close_index <= first_index
                        if close_index > 0
                            # Print any remaining text in the embedded language
                            printString truncateOffScreen( substr[ 0...close_index ], i )
                            i += substr[ 0...close_index ].length
                        end

                        @lang_stack.pop
                        setLanguage prev_lang

                        printString(
                            truncateOffScreen( substr[ close_index...(close_index + close_match_text.length) ], i ),
                            @token_formats[ close_token_class ]
                        )
                        i += close_match_text.length

                        # Continue printing from here.
                        next
                    end
                end

                if first_word != nil
                    if first_index > 0
                        # Print any preceding text in the default format
                        printString truncateOffScreen( substr[ 0...first_index ], i )
                        i += substr[ 0...first_index ].length
                    end
                    printString( truncateOffScreen( first_word, i ), @token_formats[ first_token_class ] )
                    i += first_word.length
                    if @close_token_regexps[ first_token_class ] != nil
                        if change_to = @settings[ "lang.#{@language}.tokens.#{first_token_class}.change_to" ]
                            @lang_stack.push [ @language, first_token_class ]
                            setLanguage change_to
                        else
                            @continued_format_class = first_token_class
                        end
                    end
                else
                    printString truncateOffScreen( substr, i )
                    i += substr.length
                    break
                end
            end
        end

        printPaddingFrom i
    end

    def printPaddingFrom( col )
        return if not @pen_down

        if col < @left_column
            remainder = cols
        else
            remainder = @left_column + cols - col
        end
        
        if remainder > 0
            printString( " " * remainder )
        end
    end

    def save( filename = nil, prompt_overwrite = Diakonos::DONT_PROMPT_OVERWRITE )
        if filename != nil
            name = filename.subHome
        else
            name = @name
        end
        
        if @read_only and FileTest.exists?( @name ) and FileTest.exists?( name ) and ( File.stat( @name ).ino == File.stat( name ).ino )
            @diakonos.setILine "#{name} cannot be saved since it is read-only."
        else
            @name = name
            @read_only = false
            if @name == nil
                @diakonos.saveFileAs
            #elsif name.empty?
                #@diakonos.setILine "(file not saved)"
                #@name = nil
            else
                proceed = true
                
                if prompt_overwrite and FileTest.exists? @name
                    proceed = false
                    choice = @diakonos.getChoice(
                        "Overwrite existing '#{@name}'?",
                        [ Diakonos::CHOICE_YES, Diakonos::CHOICE_NO ],
                        Diakonos::CHOICE_NO
                    )
                    case choice
                        when Diakonos::CHOICE_YES
                            proceed = true
                        when Diakonos::CHOICE_NO
                            proceed = false
                    end
                end
                
                if file_modified
                    proceed = ! @diakonos.revert( "File has been altered externally.  Load on-disk version?" )
                end
                
                if proceed
                    File.open( @name, "w" ) do |f|
                        @lines[ 0..-2 ].each do |line|
                            f.puts line
                        end
                        if @lines[ -1 ] != ""
                            # No final newline character
                            f.print @lines[ -1 ]
                            f.print "\n" if @settings[ "eof_newline" ]
                        end
                    end
                    @last_modification_check = File.mtime( @name )
                        
                    if @name == @diakonos.diakonos_conf
                        @diakonos.loadConfiguration
                        @diakonos.initializeDisplay
                    end
                    
                    @modified = false
                    
                    display
                    @diakonos.updateStatusLine
                end
            end
        end
    end

    # Returns true on successful write.
    def saveCopy( filename )
        return false if filename.nil?
        
        name = filename.subHome
        
        File.open( name, "w" ) do |f|
            @lines[ 0..-2 ].each do |line|
                f.puts line
            end
            if @lines[ -1 ] != ""
                # No final newline character
                f.print @lines[ -1 ]
                f.print "\n" if @settings[ "eof_newline" ]
            end
        end
        
        return true
    end

    def replaceChar( c )
        row = @last_row
        col = @last_col
        takeSnapshot( TYPING )
        @lines[ row ][ col ] = c
        setModified
    end

    def insertChar( c )
        row = @last_row
        col = @last_col
        takeSnapshot( TYPING )
        line = @lines[ row ]
        @lines[ row ] = line[ 0...col ] + c.chr + line[ col..-1 ]
        setModified
    end
    
    def insertString( str )
        row = @last_row
        col = @last_col
        takeSnapshot( TYPING )
        line = @lines[ row ]
        @lines[ row ] = line[ 0...col ] + str + line[ col..-1 ]
        setModified
    end

    # x and y are given window-relative, not buffer-relative.
    def delete
        if selection_mark != nil
            deleteSelection
        else
            row = @last_row
            col = @last_col
            if ( row >= 0 ) and ( col >= 0 )
                line = @lines[ row ]
                if col == line.length
                    if row < @lines.length - 1
                        # Delete newline, and concat next line
                        takeSnapshot( TYPING )
                        @lines[ row ] << @lines.delete_at( row + 1 )
                        cursorTo( @last_row, @last_col )
                        setModified
                    end
                else
                    takeSnapshot( TYPING )
                    @lines[ row ] = line[ 0...col ] + line[ (col + 1)..-1 ]
                    setModified
                end
            end
        end
    end
    
    def collapseWhitespace
        removeSelection( DONT_DISPLAY ) if selection_mark != nil
        
        line = @lines[ @last_row ]
        head = line[ 0...@last_col ]
        tail = line[ @last_col..-1 ]
        new_head = head.sub( /\s+$/, '' )
        new_line = new_head + tail.sub( /^\s+/, ' ' )
        if new_line != line
            takeSnapshot( TYPING )
            @lines[ @last_row ] = new_line
            cursorTo( @last_row, @last_col - ( head.length - new_head.length ) )
            setModified
        end
    end

    def deleteLine
        removeSelection( DONT_DISPLAY ) if selection_mark != nil

        row = @last_row
        takeSnapshot
        retval = nil
        if @lines.length == 1
            retval = @lines[ 0 ]
            @lines[ 0 ] = ""
        else
            retval = @lines[ row ]
            @lines.delete_at row
        end
        cursorTo( row, 0 )
        setModified

        return retval
    end

    def deleteToEOL
        removeSelection( DONT_DISPLAY ) if selection_mark != nil

        row = @last_row
        col = @last_col
        takeSnapshot
        retval = [ @lines[ row ][ col..-1 ] ]
        @lines[ row ] = @lines[ row ][ 0...col ]
        setModified

        return retval
    end

    def carriageReturn
        takeSnapshot
        row = @last_row
        col = @last_col
        @lines = @lines[ 0...row ] +
            [ @lines[ row ][ 0...col ] ] +
            [ @lines[ row ][ col..-1 ] ] +
            @lines[ (row+1)..-1 ]
        cursorTo( row + 1, 0 )
        parsedIndent if @auto_indent
        setModified
    end

    def lineAt( y )
        row = @top_line + y
        if row < 0
            return nil
        else
            return @lines[ row ]
        end
    end

    # Returns true iff the given column, x, is less than the length of the given line, y.
    def inLine( x, y )
        return ( x + @left_column < lineAt( y ).length )
    end

    # Translates the window column, x, to a buffer-relative column index.
    def columnOf( x )
        return @left_column + x
    end

    # Translates the window row, y, to a buffer-relative row index.
    def rowOf( y )
        return @top_line + y
    end
    
    # Returns nil if the row is off-screen.
    def rowToY( row )
        return nil if row == nil
        y = row - @top_line
        y = nil if ( y < 0 ) or ( y > @top_line + @diakonos.main_window_height - 1 )
        return y
    end
    
    # Returns nil if the column is off-screen.
    def columnToX( col )
        return nil if col == nil
        x = col - @left_column
        x = nil if ( x < 0 ) or ( x > @left_column + cols - 1 )
        return x
    end

    def currentRow
        return @last_row
    end

    def currentColumn
        return @last_col
    end

    # Returns the amount the view was actually panned.
    def panView( x = 1, do_display = DO_DISPLAY )
        old_left_column = @left_column
        @left_column = [ @left_column + x, 0 ].max
        recordMarkStartAndEnd
        display if do_display
        return ( @left_column - old_left_column )
    end

    # Returns the amount the view was actually pitched.
    def pitchView( y = 1, do_pitch_cursor = DONT_PITCH_CURSOR, do_display = DO_DISPLAY )
        old_top_line = @top_line
        new_top_line = @top_line + y

        if new_top_line < 0
            @top_line = 0
        elsif new_top_line + @diakonos.main_window_height > @lines.length
            @top_line = [ @lines.length - @diakonos.main_window_height, 0 ].max
        else
            @top_line = new_top_line
        end
        
        old_row = @last_row
        old_col = @last_col
        
        changed = ( @top_line - old_top_line )
        if changed != 0 and do_pitch_cursor
            @last_row += changed
        end
        
        height = [ @diakonos.main_window_height, @lines.length ].min
        
        @last_row = @last_row.fit( @top_line, @top_line + height - 1 )
        if @last_row - @top_line < @settings[ "view.margin.y" ]
            @last_row = @top_line + @settings[ "view.margin.y" ]
            @last_row = @last_row.fit( @top_line, @top_line + height - 1 )
        elsif @top_line + height - 1 - @last_row < @settings[ "view.margin.y" ]
            @last_row = @top_line + height - 1 - @settings[ "view.margin.y" ]
            @last_row = @last_row.fit( @top_line, @top_line + height - 1 )
        end
        @last_col = @last_col.fit( @left_column, [ @left_column + cols - 1, @lines[ @last_row ].length ].min )
        @last_screen_y = @last_row - @top_line
        @last_screen_x = tabExpandedColumn( @last_col, @last_row ) - @left_column
        
        recordMarkStartAndEnd
        
        if changed != 0
            highlightMatches
            if @diakonos.there_was_non_movement
                pushCursorState( old_top_line, old_row, old_col )
            end
        end

        display if do_display

        return changed
    end
    
    def pushCursorState( top_line, row, col, clear_stack_pointer = CLEAR_STACK_POINTER )
        new_state = {
            :top_line => top_line,
            :row => row,
            :col => col
        }
        if not @cursor_stack.include? new_state
            @cursor_stack << new_state
            if clear_stack_pointer
                @cursor_stack_pointer = nil
            end
            @diakonos.clearNonMovementFlag
        end
    end

    # Returns true iff the cursor changed positions in the buffer.
    def cursorTo( row, col, do_display = DONT_DISPLAY, stopped_typing = STOPPED_TYPING, adjust_row = Diakonos::ADJUST_ROW )
        old_last_row = @last_row
        old_last_col = @last_col
        
        row = row.fit( 0, @lines.length - 1 )

        if col < 0
            if adjust_row
                if row > 0
                    row = row - 1
                    col = @lines[ row ].length
                else
                    col = 0
                end
            else
                col = 0
            end
        elsif col > @lines[ row ].length
            if adjust_row
                if row < @lines.length - 1
                    row = row + 1
                    col = 0
                else
                    col = @lines[ row ].length
                end
            else
                col = @lines[ row ].length
            end
        end

        if adjust_row
            @desired_column = col
        else
            goto_col = [ @desired_column, @lines[ row ].length ].min
            if col < goto_col
                col = goto_col
            end
        end

        new_col = tabExpandedColumn( col, row )
        view_changed = showCharacter( row, new_col )
        @last_screen_y = row - @top_line
        @last_screen_x = new_col - @left_column
        
        @typing = false if stopped_typing
        @last_row = row
        @last_col = col
        @last_screen_col = new_col
        changed = ( @last_row != old_last_row or @last_col != old_last_col )
        if changed
            recordMarkStartAndEnd
            
            removed = false
            if not @changing_selection and selection_mark != nil
                removeSelection( DONT_DISPLAY )
                removed = true
            end
            if removed or ( do_display and ( selection_mark != nil or view_changed ) )
                display
            else
                @diakonos.display_mutex.synchronize do
                    @win_main.setpos( @last_screen_y, @last_screen_x )
                end
            end
            @diakonos.updateStatusLine
            @diakonos.updateContextLine
        end
        
        return changed
    end
    
    def cursorReturn( direction )
        delta = 0
        if @cursor_stack_pointer.nil?
            pushCursorState( @top_line, @last_row, @last_col, DONT_CLEAR_STACK_POINTER )
            delta = 1
        end
        case direction
            when :forward
                @cursor_stack_pointer = ( @cursor_stack_pointer || 0 ) + 1
            #when :backward
            else
                @cursor_stack_pointer = ( @cursor_stack_pointer || @cursor_stack.length ) - 1 - delta
        end
        
        return_pointer = @cursor_stack_pointer
        
        if @cursor_stack_pointer < 0
            return_pointer = @cursor_stack_pointer = 0
        elsif @cursor_stack_pointer >= @cursor_stack.length
            return_pointer = @cursor_stack_pointer = @cursor_stack.length - 1
        else
            cursor_state = @cursor_stack[ @cursor_stack_pointer ]
            if cursor_state != nil
                pitchView( cursor_state[ :top_line ] - @top_line, DONT_PITCH_CURSOR, DO_DISPLAY )
                cursorTo( cursor_state[ :row ], cursor_state[ :col ] )
                @diakonos.updateStatusLine
            end
        end
        
        return return_pointer, @cursor_stack.size
    end
    
    def tabExpandedColumn( col, row )
        delta = 0
        line = @lines[ row ]
        for i in 0...col
            if line[ i ] == Diakonos::TAB
                delta += ( @tab_size - ( (i+delta) % @tab_size ) ) - 1
            end
        end
        return ( col + delta )
    end

    def cursorToEOF
        cursorTo( @lines.length - 1, @lines[ -1 ].length, DO_DISPLAY )
    end

    def cursorToBOL
        row = @last_row
        case @settings[ "bol_behaviour" ]
            when Diakonos::BOL_ZERO
                col = 0
            when Diakonos::BOL_FIRST_CHAR
                col = ( ( @lines[ row ] =~ /\S/ ) or 0 )
            when Diakonos::BOL_ALT_ZERO
                if @last_col == 0
                    col = ( @lines[ row ] =~ /\S/ )
                else
                    col = 0
                end
            #when Diakonos::BOL_ALT_FIRST_CHAR
            else
                first_char_col = ( ( @lines[ row ] =~ /\S/ ) or 0 )
                if @last_col == first_char_col
                    col = 0
                else
                    col = first_char_col
                end
        end
        cursorTo( row, col, DO_DISPLAY )
    end

    # Top of view
    def cursorToTOV
        cursorTo( rowOf( 0 ), @last_col, DO_DISPLAY )
    end
    # Bottom of view
    def cursorToBOV
        cursorTo( rowOf( 0 + @diakonos.main_window_height - 1 ), @last_col, DO_DISPLAY )
    end

    # col and row are given relative to the buffer, not any window or screen.
    # Returns true if the view changed positions.
    def showCharacter( row, col )
        old_top_line = @top_line
        old_left_column = @left_column

        while row < @top_line + @settings[ "view.margin.y" ]
            amount = (-1) * @settings[ "view.jump.y" ]
            break if( pitchView( amount, DONT_PITCH_CURSOR, DONT_DISPLAY ) != amount )
        end
        while row > @top_line + @diakonos.main_window_height - 1 - @settings[ "view.margin.y" ]
            amount = @settings[ "view.jump.y" ]
            break if( pitchView( amount, DONT_PITCH_CURSOR, DONT_DISPLAY ) != amount )
        end

        while col < @left_column + @settings[ "view.margin.x" ]
            amount = (-1) * @settings[ "view.jump.x" ]
            break if( panView( amount, DONT_DISPLAY ) != amount )
        end
        while col > @left_column + @diakonos.main_window_width - @settings[ "view.margin.x" ] - 2
            amount = @settings[ "view.jump.x" ]
            break if( panView( amount, DONT_DISPLAY ) != amount )
        end

        return ( @top_line != old_top_line or @left_column != old_left_column )
    end

    def setIndent( row, level, do_display = DO_DISPLAY )
        @lines[ row ] =~ /^([\s#{@indent_ignore_charset}]*)(.*)$/
        current_indent_text = ( $1 or "" )
        rest = ( $2 or "" )
        current_indent_text.gsub!( /\t/, ' ' * @tab_size )
        indentation = @indent_size * [ level, 0 ].max
        if current_indent_text.length >= indentation
            indent_text = current_indent_text[ 0...indentation ]
        else
            indent_text = current_indent_text + " " * ( indentation - current_indent_text.length )
        end
        if @settings[ "lang.#{@language}.indent.using_tabs" ]
            num_tabs = 0
            indent_text.gsub!( / {#{@tab_size}}/ ) { |match|
                num_tabs += 1
                "\t"
            }
            indentation -= num_tabs * ( @tab_size - 1 )
        end

        takeSnapshot( TYPING ) if do_display
        @lines[ row ] = indent_text + rest
        cursorTo( row, indentation ) if do_display
        setModified
    end

    def parsedIndent( row = @last_row, do_display = DO_DISPLAY )
        if row == 0
            level = 0
        else
            # Look upwards for the nearest line on which to base this line's indentation.
            i = 1
            while ( @lines[ row - i ] =~ /^[\s#{@indent_ignore_charset}]*$/ ) or
                  ( @lines[ row - i ] =~ @settings[ "lang.#{@language}.indent.ignore" ] )
                i += 1
            end
            if row - i < 0
                level = 0
            else
                prev_line = @lines[ row - i ]
                level = prev_line.indentation_level( @indent_size, @indent_roundup, @tab_size, @indent_ignore_charset )

                line = @lines[ row ]
                if @preventers != nil
                    prev_line = prev_line.gsub( @preventers, "" )
                    line = line.gsub( @preventers, "" )
                end

                indenter_index = ( prev_line =~ @indenters )
                if indenter_index
                    level += 1
                    unindenter_index = (prev_line =~ @unindenters)
                    if unindenter_index and unindenter_index != indenter_index
                        level += -1
                    end
                end
                if line =~ @unindenters
                    level += -1
                end
            end
        end

        setIndent( row, level, do_display )

    end

    def indent( row = @last_row, do_display = DO_DISPLAY )
        level = @lines[ row ].indentation_level( @indent_size, @indent_roundup, @tab_size )
        setIndent( row, level + 1, do_display )
    end

    def unindent( row = @last_row, do_display = DO_DISPLAY )
        level = @lines[ row ].indentation_level( @indent_size, @indent_roundup, @tab_size )
        setIndent( row, level - 1, do_display )
    end

    def anchorSelection( row = @last_row, col = @last_col, do_display = DO_DISPLAY )
        @mark_anchor = ( @mark_anchor or Hash.new )
        @mark_anchor[ "row" ] = row
        @mark_anchor[ "col" ] = col
        recordMarkStartAndEnd
        @changing_selection = true
        display if do_display
    end

    def removeSelection( do_display = DO_DISPLAY )
        return if selection_mark.nil?
        @mark_anchor = nil
        recordMarkStartAndEnd
        @changing_selection = false
        @last_finding = nil
        display if do_display
    end
    
    def toggleSelection
        if @changing_selection
            removeSelection
        else
            anchorSelection
        end
    end

    def copySelection
        return selected_text
    end
    def selected_text
        selection = selection_mark
        if selection == nil
            text = nil
        elsif selection.start_row == selection.end_row
            text = [ @lines[ selection.start_row ][ selection.start_col...selection.end_col ] ]
        else
            text = [ @lines[ selection.start_row ][ selection.start_col..-1 ] ] +
                ( @lines[ (selection.start_row + 1) .. (selection.end_row - 1) ] or [] ) +
                [ @lines[ selection.end_row ][ 0...selection.end_col ] ]
        end

        return text
    end
    def selected_string
        lines = selected_text
        if lines
            lines.join( "\n" )
        else
            nil
        end
    end

    def deleteSelection( do_display = DO_DISPLAY )
        return if @text_marks[ SELECTION ] == nil

        takeSnapshot

        selection = @text_marks[ SELECTION ]
        start_row = selection.start_row
        start_col = selection.start_col
        start_line = @lines[ start_row ]

        if selection.end_row == selection.start_row
            @lines[ start_row ] = start_line[ 0...start_col ] + start_line[ selection.end_col..-1 ]
        else
            end_line = @lines[ selection.end_row ]
            @lines[ start_row ] = start_line[ 0...start_col ] + end_line[ selection.end_col..-1 ]
            @lines = @lines[ 0..start_row ] + @lines[ (selection.end_row + 1)..-1 ]
        end

        cursorTo( start_row, start_col )
        removeSelection( DONT_DISPLAY )
        setModified( do_display )
    end

    # text is an array of Strings
    def paste( text )
        return if text == nil
        
        if not text.kind_of? Array
            s = text.to_s
            if s.include?( "\n" )
                text = s.split( "\n", -1 )
            else
                text = [ s ]
            end
        end

        takeSnapshot

        deleteSelection( DONT_DISPLAY )

        row = @last_row
        col = @last_col
        line = @lines[ row ]
        if text.length == 1
            @lines[ row ] = line[ 0...col ] + text[ 0 ] + line[ col..-1 ]
            cursorTo( @last_row, @last_col + text[ 0 ].length )
        elsif text.length > 1
            @lines[ row ] = line[ 0...col ] + text[ 0 ]
            @lines[ row + 1, 0 ] = text[ -1 ] + line[ col..-1 ]
            @lines[ row + 1, 0 ] = text[ 1..-2 ]
            cursorTo( @last_row + text.length - 1, columnOf( text[ -1 ].length ) )
        end

        setModified
    end

    # Takes an array of Regexps, which represents a user-provided regexp,
    # split across newline characters.  Once the first element is found,
    # each successive element must match against lines following the first
    # element.
    def find( regexps, direction = :down, replacement = nil )
        return if regexps.nil?
        regexp = regexps[ 0 ]
        return if regexp == nil or regexp == //
        
        if direction == :opposite
            case @last_search_direction
                when :up
                    direction = :down
                else
                    direction = :up
            end
        end
        @last_search_regexps = regexps
        @last_search_direction = direction
        
        finding = nil
        wrapped = false
        
        catch :found do
        
            if direction == :down
                # Check the current row first.
                
                if index = @lines[ @last_row ].index( regexp, ( @last_finding ? @last_finding.start_col : @last_col ) + 1 )
                    found_text = Regexp.last_match[ 0 ]
                    finding = Finding.new( @last_row, index, @last_row, index + found_text.length )
                    if finding.match( regexps, @lines )
                        throw :found
                    else
                        finding = nil
                    end
                end
                
                # Check below the cursor.
                
                ( (@last_row + 1)...@lines.length ).each do |i|
                    if index = @lines[ i ].index( regexp )
                        found_text = Regexp.last_match[ 0 ]
                        finding = Finding.new( i, index, i, index + found_text.length )
                        if finding.match( regexps, @lines )
                            throw :found
                        else
                            finding = nil
                        end
                    end
                end
                
                # Wrap around.
                
                wrapped = true
                
                ( 0...@last_row ).each do |i|
                    if index = @lines[ i ].index( regexp )
                        found_text = Regexp.last_match[ 0 ]
                        finding = Finding.new( i, index, i, index + found_text.length )
                        if finding.match( regexps, @lines )
                            throw :found
                        else
                            finding = nil
                        end
                    end
                end
                
                # And finally, the other side of the current row.
                
                #if index = @lines[ @last_row ].index( regexp, ( @last_finding ? @last_finding.start_col : @last_col ) - 1 )
                if index = @lines[ @last_row ].index( regexp )
                    if index <= ( @last_finding ? @last_finding.start_col : @last_col )
                        found_text = Regexp.last_match[ 0 ]
                        finding = Finding.new( @last_row, index, @last_row, index + found_text.length )
                        if finding.match( regexps, @lines )
                            throw :found
                        else
                            finding = nil
                        end
                    end
                end
                
            elsif direction == :up
                # Check the current row first.
                
                col_to_check = ( @last_finding ? @last_finding.end_col : @last_col ) - 1
                if ( col_to_check >= 0 ) and ( index = @lines[ @last_row ][ 0...col_to_check ].rindex( regexp ) )
                    found_text = Regexp.last_match[ 0 ]
                    finding = Finding.new( @last_row, index, @last_row, index + found_text.length )
                    if finding.match( regexps, @lines )
                        throw :found
                    else
                        finding = nil
                    end
                end
                
                # Check above the cursor.
                
                (@last_row - 1).downto( 0 ) do |i|
                    if index = @lines[ i ].rindex( regexp )
                        found_text = Regexp.last_match[ 0 ]
                        finding = Finding.new( i, index, i, index + found_text.length )
                        if finding.match( regexps, @lines )
                            throw :found
                        else
                            finding = nil
                        end
                    end
                end
                
                # Wrap around.
                
                wrapped = true
                
                (@lines.length - 1).downto(@last_row + 1) do |i|
                    if index = @lines[ i ].rindex( regexp )
                        found_text = Regexp.last_match[ 0 ]
                        finding = Finding.new( i, index, i, index + found_text.length )
                        if finding.match( regexps, @lines )
                            throw :found
                        else
                            finding = nil
                        end
                    end
                end
                
                # And finally, the other side of the current row.
                
                search_col = ( @last_finding ? @last_finding.start_col : @last_col ) + 1
                if index = @lines[ @last_row ].rindex( regexp )
                    if index > search_col
                        found_text = Regexp.last_match[ 0 ]
                        finding = Finding.new( @last_row, index, @last_row, index + found_text.length )
                        if finding.match( regexps, @lines )
                            throw :found
                        else
                            finding = nil
                        end
                    end
                end
            end
        end
        
        if finding != nil
            @diakonos.setILine( "(search wrapped around BOF/EOF)" ) if wrapped
            
            removeSelection( DONT_DISPLAY )
            @last_finding = finding
            if @settings[ "found_cursor_start" ]
                anchorSelection( finding.end_row, finding.end_col, DONT_DISPLAY )
                cursorTo( finding.start_row, finding.start_col )
            else
                anchorSelection( finding.start_row, finding.start_col, DONT_DISPLAY )
                cursorTo( finding.end_row, finding.end_col )
            end

            @changing_selection = false
            
            if regexps.length == 1
                @highlight_regexp = regexp
                highlightMatches
            else
                clearMatches
            end
            display
            
            if replacement != nil
                choice = @diakonos.getChoice(
                    "Replace?",
                    [ Diakonos::CHOICE_YES, Diakonos::CHOICE_NO, Diakonos::CHOICE_ALL, Diakonos::CHOICE_CANCEL ],
                    Diakonos::CHOICE_YES
                )
                case choice
                    when Diakonos::CHOICE_YES
                        paste [ replacement ]
                        find( regexps, direction, replacement )
                    when Diakonos::CHOICE_ALL
                        replaceAll( regexp, replacement )
                    when Diakonos::CHOICE_NO
                        find( regexps, direction, replacement )
                    when Diakonos::CHOICE_CANCEL
                        # Do nothing further.
                end
            end
        else
            @diakonos.setILine "/#{regexp.source}/ not found."
        end
    end

    def replaceAll( regexp, replacement )
        return if( regexp == nil or replacement == nil )

        @lines = @lines.collect { |line|
            line.gsub( regexp, replacement )
        }
        setModified

        clearMatches

        display
    end
    
    def highlightMatches
        if @highlight_regexp != nil
            found_marks = @lines[ @top_line...(@top_line + @diakonos.main_window_height) ].grep_indices( @highlight_regexp ).collect do |line_index, start_col, end_col|
                TextMark.new( @top_line + line_index, start_col, @top_line + line_index, end_col, @settings[ "lang.#{@language}.format.found" ] )
            end
            #@text_marks = [ nil ] + found_marks
            @text_marks = [ @text_marks[ 0 ] ] + found_marks
        end
    end

    def clearMatches( do_display = DONT_DISPLAY )
        selection = @text_marks[ SELECTION ]
        @text_marks = Array.new
        @text_marks[ SELECTION ] = selection
        @highlight_regexp = nil
        display if do_display
    end

    def findAgain( last_search_regexps, direction = @last_search_direction )
        if @last_search_regexps == nil
            @last_search_regexps = last_search_regexps
        end
        find( @last_search_regexps, direction ) if( @last_search_regexps != nil )
    end
    
    def seek( regexp, direction = :down )
        return if regexp == nil or regexp == //
        
        found_row = nil
        found_col = nil
        found_text = nil
        wrapped = false
        
        catch :found do
            if direction == :down
                # Check the current row first.
                
                index, match_text = @lines[ @last_row ].group_index( regexp, @last_col + 1 )
                if index != nil
                    found_row = @last_row
                    found_col = index
                    found_text = match_text
                    throw :found
                end
                
                # Check below the cursor.
                
                ( (@last_row + 1)...@lines.length ).each do |i|
                    index, match_text = @lines[ i ].group_index( regexp )
                    if index != nil
                        found_row = i
                        found_col = index
                        found_text = match_text
                        throw :found
                    end
                end
                
            else
                # Check the current row first.
                
                #col_to_check = ( @last_found_col or @last_col ) - 1
                col_to_check = @last_col - 1
                if col_to_check >= 0
                    index, match_text = @lines[ @last_row ].group_rindex( regexp, col_to_check )
                    if index != nil
                        found_row = @last_row
                        found_col = index
                        found_text = match_text
                        throw :found
                    end
                end
                
                # Check above the cursor.
                
                (@last_row - 1).downto( 0 ) do |i|
                    index, match_text = @lines[ i ].group_rindex( regexp )
                    if index != nil
                        found_row = i
                        found_col = index
                        found_text = match_text
                        throw :found
                    end
                end
            end
        end
        
        if found_text != nil
            #@last_found_row = found_row
            #@last_found_col = found_col
            cursorTo( found_row, found_col )
            
            display
        end
    end    

    def setModified( do_display = DO_DISPLAY )
        if @read_only
            @diakonos.setILine "Warning: Modifying a read-only file."
        end

        fmod = false
        if not @modified
            @modified = true
            fmod = file_modified
        end
        
        reverted = false
        if fmod
            reverted = @diakonos.revert( "File has been altered externally.  Load on-disk version?" )
        end
        
        if not reverted
            clearMatches
            if do_display
                @diakonos.updateStatusLine
                display
            end
        end
    end
    
    # Check if the file which is being edited has been modified since
    # the last time we checked it; return true if so, false otherwise.
    def file_modified
        modified = false
        
        if @name != nil
            begin
                mtime = File.mtime( @name )
                
                if mtime > @last_modification_check
                    modified = true
                    @last_modification_check = mtime
                end
            rescue Errno::ENOENT
                # Ignore if file doesn't exist
            end
        end
        
        return modified
    end

    def takeSnapshot( typing = false )
        take_snapshot = false
        if @typing != typing
            @typing = typing
            # If we just started typing, take a snapshot, but don't continue
            # taking snapshots for every keystroke
            if typing
                take_snapshot = true
            end
        end
        if not @typing
            take_snapshot = true
        end

        if take_snapshot
            undo_size = 0
            @buffer_states[ 1..-1 ].each do |state|
                undo_size += state.length
            end
            while ( ( undo_size + @lines.length ) >= @settings[ "max_undo_lines" ] ) and @buffer_states.length > 1
                @cursor_states.pop
                popped_state = @buffer_states.pop
                undo_size = undo_size - popped_state.length
            end
            if @current_buffer_state > 0
                @buffer_states.unshift @lines.deep_clone
                @cursor_states.unshift [ @last_row, @last_col ]
            end
            @buffer_states.unshift @lines.deep_clone
            @cursor_states.unshift [ @last_row, @last_col ]
            @current_buffer_state = 0
            @lines = @buffer_states[ @current_buffer_state ]
        end
    end

    def undo
        if @current_buffer_state < @buffer_states.length - 1
            @current_buffer_state += 1
            @lines = @buffer_states[ @current_buffer_state ]
            cursorTo( @cursor_states[ @current_buffer_state - 1 ][ 0 ], @cursor_states[ @current_buffer_state - 1 ][ 1 ] )
            @diakonos.setILine "Undo level: #{@current_buffer_state} of #{@buffer_states.length - 1}"
            setModified
        end
    end

    # Since redo is a Ruby keyword...
    def unundo
        if @current_buffer_state > 0
            @current_buffer_state += -1
            @lines = @buffer_states[ @current_buffer_state ]
            cursorTo( @cursor_states[ @current_buffer_state ][ 0 ], @cursor_states[ @current_buffer_state ][ 1 ] )
            @diakonos.setILine "Undo level: #{@current_buffer_state} of #{@buffer_states.length - 1}"
            setModified
        end
    end

    def goToLine( line = nil, column = nil )
        cursorTo( line || @last_row, column || 0, DO_DISPLAY )
    end

    def goToNextBookmark
        cur_pos = Bookmark.new( self, @last_row, @last_col )
        next_bm = @bookmarks.find do |bm|
            bm > cur_pos
        end
        if next_bm != nil
            cursorTo( next_bm.row, next_bm.col, DO_DISPLAY )
        end
    end

    def goToPreviousBookmark
        cur_pos = Bookmark.new( self, @last_row, @last_col )
        # There's no reverse_find method, so, we have to do this manually.
        prev = nil
        @bookmarks.reverse_each do |bm|
            if bm < cur_pos
                prev = bm
                break
            end
        end
        if prev != nil
            cursorTo( prev.row, prev.col, DO_DISPLAY )
        end
    end

    def toggleBookmark
        bookmark = Bookmark.new( self, @last_row, @last_col )
        existing = @bookmarks.find do |bm|
            bm == bookmark
        end
        if existing
            @bookmarks.delete existing
            @diakonos.setILine "Bookmark #{existing.to_s} deleted."
        else
            @bookmarks.push bookmark
            @bookmarks.sort
            @diakonos.setILine "Bookmark #{bookmark.to_s} set."
        end
    end

    def context
        retval = Array.new
        row = @last_row
        clevel = @lines[ row ].indentation_level( @indent_size, @indent_roundup, @tab_size, @indent_ignore_charset )
        while row > 0 and clevel < 0
            row = row - 1
            clevel = @lines[ row ].indentation_level( @indent_size, @indent_roundup, @tab_size, @indent_ignore_charset )
        end
        clevel = 0 if clevel < 0
        while row > 0
            row = row - 1
            line = @lines[ row ]
            if line !~ @settings[ "lang.#{@language}.context.ignore" ]
                level = line.indentation_level( @indent_size, @indent_roundup, @tab_size, @indent_ignore_charset )
                if level < clevel and level > -1
                    retval.unshift line
                    clevel = level
                    break if clevel == 0
                end
            end
        end
        return retval
    end

    def setType( type )
        success = false
        if type != nil
            configure( type )
            display
            success = true
        end
        return success
    end
    
    def wordUnderCursor
        word = nil
        
        @lines[ @last_row ].scan( /\w+/ ) do |match_text|
            last_match = Regexp.last_match
            if last_match.begin( 0 ) <= @last_col and @last_col < last_match.end( 0 )
                word = match_text
                break
            end
        end
        
        return word
    end
end

class Curses::Window
    def puts( string = "" )
        addstr( string + "\n" )
    end
    
    # setpos, but with some boundary checks
    def setpos_( y, x )
        $diakonos.debugLog "setpos: y < 0 (#{y})" if y < 0
        $diakonos.debugLog "setpos: x < 0 (#{x})" if x < 0
        $diakonos.debugLog "setpos: y > lines (#{y})" if y > lines
        $diakonos.debugLog "setpos: x > cols (#{x})" if x > cols
        setpos( y, x )
    end
    
    def addstr_( string )
        x = curx
        y = cury
        x2 = curx + string.length
        
        if y < 0 or x < 0 or y > lines or x > cols or x2 < 0 or x2 > cols
            begin
                raise Exception
            rescue Exception => e
                $diakonos.debugLog e.backtrace[ 1 ]
                $diakonos.debugLog e.backtrace[ 2 ]
            end
        end
        
        addstr( string )
    end
end

class Clipboard
    def initialize( max_clips )
        @clips = Array.new
        @max_clips = max_clips
    end

    def [] ( arg )
        return @clips[ arg ]
    end

    def clip
        return @clips[ 0 ]
    end

    # text is an array of Strings
    # Returns true iff a clip was added,
    # and only non-nil text can be added.
    def addClip( text )
        return false if text == nil
        @clips.unshift text
        @clips.pop if @clips.length > @max_clips
        return true
    end
    
    def each
        @clips.each do |clip|
            yield clip
        end
    end
    
    # text is an array of Strings (lines)
    # Appends the lines to the current clip.
    # If no current clip, then a new clip is created.
    # Returns true iff the text was successfully appended.
    def appendToClip( text )
        return false if text.nil?
        return addClip( text ) if @clips.length == 0
        last_clip = @clips[ 0 ]
        last_clip.pop if last_clip[ -1 ] == ""
        @clips[ 0 ] = last_clip + text
        return true
    end
end

class Diakonos
    attr_reader :win_main, :settings, :token_regexps, :close_token_regexps,
        :token_formats, :diakonos_home, :script_dir, :diakonos_conf, :display_mutex,
        :indenters, :unindenters, :clipboard, :do_display,
        :current_buffer, :list_filename, :hooks, :last_commands, :there_was_non_movement

    VERSION = "0.8.3"
    LAST_MODIFIED = "August 17, 2006"

    DONT_ADJUST_ROW = false
    ADJUST_ROW = true
    PROMPT_OVERWRITE = true
    DONT_PROMPT_OVERWRITE = false
    DO_REDRAW = true
    DONT_REDRAW = false

    PRINTABLE_CHARACTERS = 32..254
    TAB = 9
    ENTER = 13
    ESCAPE = 27
    BACKSPACE = 127
    CTRL_C = 3
    CTRL_D = 4
    CTRL_K = 11
    CTRL_Q = 17
    CTRL_H = 263
    RESIZE2 = 4294967295
    
    DEFAULT_TAB_SIZE = 8

    CHOICE_NO = 0
    CHOICE_YES = 1
    CHOICE_ALL = 2
    CHOICE_CANCEL = 3
    CHOICE_YES_TO_ALL = 4
    CHOICE_NO_TO_ALL = 5
    CHOICE_KEYS = [
        [ ?n, ?N ],
        [ ?y, ?Y ],
        [ ?a, ?A ],
        [ ?c, ?C, ESCAPE, CTRL_C, CTRL_D, CTRL_Q ],
        [ ?e ],
        [ ?o ]
    ]
    CHOICE_STRINGS = [ "(n)o", "(y)es", "(a)ll", "(c)ancel", "y(e)s to all", "n(o) to all" ]

    BOL_ZERO = 0
    BOL_FIRST_CHAR = 1
    BOL_ALT_ZERO = 2
    BOL_ALT_FIRST_CHAR = 3

    FORCE_REVERT = true
    ASK_REVERT = false
    
    ASK_REPLACEMENT = true
    
    CASE_SENSITIVE = true
    CASE_INSENSITIVE = false

    FUNCTIONS = [
        "addNamedBookmark",
        "anchorSelection",
        "backspace",
        "carriageReturn",
        "changeSessionSetting",
        "clearMatches",
        "closeFile",
        "collapseWhitespace",
        "copySelection",
        "cursorBOF",
        "cursorBOL",
        "cursorDown",
        "cursorEOF",
        "cursorEOL",
        "cursorBOV",
        "cursorTOV",
        "cursorLeft",
        "cursorReturn",
        "cursorRight",
        "cursorUp",
        "cutSelection",
        "delete",
        "deleteAndStoreLine",
        "deleteLine",
        "deleteToEOL",
        "evaluate",
        "execute",
        "find",
        "findAgain",
        "findAndReplace",
        "findExact",
        "goToLineAsk",
        "goToNamedBookmark",
        "goToNextBookmark",
        "goToPreviousBookmark",
        "goToTag",
        "goToTagUnderCursor",
        "help",
        "indent",
        "insertSpaces",
        "insertTab",
        "loadConfiguration",
        "loadScript",
        "newFile",
        "openFile",
        "openFileAsk",
        "operateOnEachLine",
        "operateOnLines",
        "operateOnString",
        "pageDown",
        "pageUp",
        "parsedIndent",
        "paste",
        "pasteShellResult",
        "playMacro",
        "popTag",
        "printKeychain",
        "quit",
        "redraw",
        "removeNamedBookmark",
        "removeSelection",
        "repeatLast",
        "revert",
        "saveFile",
        "saveFileAs",
        "scrollDown",
        "scrollUp",
        "searchAndReplace",
        "seek",
        "setBufferType",
        "setReadOnly",
        "shell",
        "showClips",
        "suspend",
        "switchToBufferNumber",
        "switchToNextBuffer",
        "switchToPreviousBuffer",
        "toggleBookmark",
        "toggleMacroRecording",
        "toggleSelection",
        "toggleSessionSetting",
        "undo",
        "unindent",
        "unundo"
    ]
    LANG_TEXT = "text"
    
    NUM_LAST_COMMANDS = 2

    def initialize( argv = [] )
        @diakonos_home = ( ( ENV[ "HOME" ] or "" ) + "/.diakonos" ).subHome
        if not FileTest.exists? @diakonos_home
            Dir.mkdir @diakonos_home
        end
        @script_dir = "#{@diakonos_home}/scripts"
        if not FileTest.exists? @script_dir
            Dir.mkdir @script_dir
        end
        @debug = File.new( "#{@diakonos_home}/debug.log", "w" )
        @list_filename = @diakonos_home + "/listing.txt"
        @diff_filename = @diakonos_home + "/text.diff"

        @files = Array.new
        @read_only_files = Array.new
        @config_filename = nil
        
        parseOptions argv
        
        @session_settings = Hash.new
        @win_main = nil
        @win_context = nil
        @win_status = nil
        @win_interaction = nil
        @buffers = BufferHash.new
        
        loadConfiguration
        
        @quitting = false
        @untitled_id = 0

        @x = 0
        @y = 0

        @buffer_stack = Array.new
        @current_buffer = nil
        @bookmarks = Hash.new
        @macro_history = nil
        @macro_input_history = nil
        @macros = Hash.new
        @last_commands = SizedArray.new( NUM_LAST_COMMANDS )
        @playing_macro = false
        @display_mutex = Mutex.new
        @display_queue_mutex = Mutex.new
        @display_queue = nil
        @do_display = true
        @iline_mutex = Mutex.new
        @tag_stack = Array.new
        @last_search_regexps = nil
        @iterated_choice = nil
        @choice_iterations = 0
        @there_was_non_movement = false
        
        # Readline histories
        @rlh_general = Array.new
        @rlh_files = Array.new
        @rlh_search = Array.new
        @rlh_shell = Array.new
    end

    def parseOptions( argv )
        while argv.length > 0
            arg = argv.shift
            case arg
                when "--help"
                    printUsage
                    exit 1
                when "-ro"
                    filename = argv.shift
                    if filename == nil
                        printUsage
                        exit 1
                    else
                        @read_only_files.push filename
                    end
                when "-c", "--config"
                    @config_filename = argv.shift
                    if @config_filename == nil
                        printUsage
                        exit 1
                    end
                when "-e", "--execute"
                    post_load_script = argv.shift
                    if post_load_script == nil
                        printUsage
                        exit 1
                    else
                        @post_load_script = post_load_script
                    end                        
                else
                    # a name of a file to open
                    @files.push arg
            end
        end
    end
    protected :parseOptions

    def printUsage
        puts "Usage: #{$0} [options] [file] [file...]"
        puts "\t--help\tDisplay usage"
        puts "\t-ro <file>\tLoad file as read-only"
        puts "\t-c <config file>\tLoad this config file instead of ~/.diakonos/diakonos.conf"
        puts "\t-e, --execute <Ruby code>\tExecute Ruby code (such as Diakonos commands) after startup"
    end
    protected :printUsage
    
    def initializeDisplay
        if @win_main != nil
            @win_main.close
        end
        if @win_status != nil
            @win_status.close
        end
        if @win_interaction != nil
            @win_interaction.close
        end
        if @win_context != nil
            @win_context.close
        end

        init_screen
        nonl
        raw
        noecho

        if has_colors?
            start_color
            init_pair( COLOR_BLACK, COLOR_BLACK, COLOR_BLACK )
            init_pair( COLOR_RED, COLOR_RED, COLOR_BLACK )
            init_pair( COLOR_GREEN, COLOR_GREEN, COLOR_BLACK )
            init_pair( COLOR_YELLOW, COLOR_YELLOW, COLOR_BLACK )
            init_pair( COLOR_BLUE, COLOR_BLUE, COLOR_BLACK )
            init_pair( COLOR_MAGENTA, COLOR_MAGENTA, COLOR_BLACK )
            init_pair( COLOR_CYAN, COLOR_CYAN, COLOR_BLACK )
            init_pair( COLOR_WHITE, COLOR_WHITE, COLOR_BLACK )
            @colour_pairs.each do |cp|
                init_pair( cp[ :number ], cp[ :fg ], cp[ :bg ] )
            end
        end
        
        @win_main = Window.new( main_window_height, cols, 0, 0 )
        @win_main.keypad( true )
        @win_status = Window.new( 1, cols, lines - 2, 0 )
        @win_status.keypad( true )
        @win_status.attrset @settings[ "status.format" ]
        @win_interaction = Window.new( 1, cols, lines - 1, 0 )
        @win_interaction.keypad( true )
        
        if @settings[ "context.visible" ]
            if @settings[ "context.combined" ]
                pos = 1
            else
                pos = 3
            end
            @win_context = Window.new( 1, cols, lines - pos, 0 )
            @win_context.keypad( true )
        else
            @win_context = nil
        end

        @win_interaction.refresh
        @win_main.refresh
        
        @buffers.each_value do |buffer|
            buffer.reset_win_main
        end
    end
    
    def loadConfiguration
        # Set defaults first

        existent = 0
        conf_dirs = [
            "/usr/local/etc/diakonos.conf",
            "/usr/etc/diakonos.conf",
            "/etc/diakonos.conf",
            "/usr/local/share/diakonos/diakonos.conf",
            "/usr/share/diakonos/diakonos.conf"
        ]
        
        conf_dirs.each do |conf_dir|
            @global_diakonos_conf = conf_dir
            if FileTest.exists? @global_diakonos_conf
                existent += 1
                break
            end
        end
        
        @diakonos_conf = ( @config_filename or ( @diakonos_home + "/diakonos.conf" ) )
        existent += 1 if FileTest.exists? @diakonos_conf

        if existent < 1
            puts "diakonos.conf not found in any of:"
            puts "   /usr/local/share/diakonos/"
            puts "   /usr/share/diakonos/"
            puts "   ~/.diakonos/"
            puts "At least one configuration file must exist."
            puts "Download a sample configuration file from http://purepistos.net/diakonos ."
            exit( 1 )
        end

        @logfilename = @diakonos_home + "/diakonos.log"
        @keychains = Hash.new
        @token_regexps = Hash.new
        @close_token_regexps = Hash.new
        @token_formats = Hash.new
        @indenters = Hash.new
        @unindenters = Hash.new
        @filemasks = Hash.new
        @bangmasks = Hash.new

        @settings = Hash.new
        # Setup some defaults
        @settings[ "context.format" ] = A_REVERSE
        
        @keychains[ KEY_RESIZE ] = [ "redraw", nil ]
        @keychains[ RESIZE2 ] = [ "redraw", nil ]
        
        @colour_pairs = Array.new

        begin
            parseConfigurationFile( @global_diakonos_conf )
            parseConfigurationFile( @diakonos_conf )
            
            # Session settings override config file settings.
            
            @session_settings.each do |key,value|
                @settings[ key ] = value
            end
            
            @clipboard = Clipboard.new @settings[ "max_clips" ]
            @log = File.open( @logfilename, "a" )

            if @buffers != nil
                @buffers.each_value do |buffer|
                    buffer.configure
                end
            end
        rescue Errno::ENOENT
            # No config file found or readable
        end
    end
    
    def parseConfigurationFile( filename )
        return if not FileTest.exists? filename

        lines = IO.readlines( filename ).collect { |l| l.chomp }
        lines.each do |line|
            # Skip comments
            next if line[ 0 ] == ?#

            command, arg = line.split( /\s+/, 2 )
            next if command == nil
            command = command.downcase
            case command
                when "include"
                    parseConfigurationFile arg.subHome
                when "key"
                    if arg != nil
                        if /  / === arg
                            keystrings, function_and_args = arg.split( / {2,}/, 2 )
                        else
                            keystrings, function_and_args = arg.split( /;/, 2 )
                        end
                        keystrokes = Array.new
                        keystrings.split( /\s+/ ).each do |ks_str|
                            code = ks_str.keyCode
                            if code != nil
                                keystrokes.concat code
                            else
                                puts "unknown keystring: #{ks_str}"
                            end
                        end
                        if function_and_args == nil
                            @keychains.deleteKeyPath( keystrokes )
                        else
                            function, function_args = function_and_args.split( /\s+/, 2 )
                            if FUNCTIONS.include? function
                                @keychains.setKeyPath(
                                    keystrokes,
                                    [ function, function_args ]
                                )
                            end
                        end
                    end
                when /^lang\.(.+?)\.tokens\.([^.]+)(\.case_insensitive)?$/
                    getTokenRegexp( @token_regexps, arg, Regexp.last_match )
                when /^lang\.(.+?)\.tokens\.([^.]+)\.open(\.case_insensitive)?$/
                    getTokenRegexp( @token_regexps, arg, Regexp.last_match )
                when /^lang\.(.+?)\.tokens\.([^.]+)\.close(\.case_insensitive)?$/
                    getTokenRegexp( @close_token_regexps, arg, Regexp.last_match )
                when /^lang\.(.+?)\.tokens\.(.+?)\.format$/
                    language = $1
                    token_class = $2
                    @token_formats[ language ] = ( @token_formats[ language ] or Hash.new )
                    @token_formats[ language ][ token_class ] = arg.toFormatting
                when /^lang\.(.+?)\.format\..+$/
                    @settings[ command ] = arg.toFormatting
                when /^colou?r$/
                    number, fg, bg = arg.split( /\s+/ )
                    number = number.to_i
                    fg = fg.toColourConstant
                    bg = bg.toColourConstant
                    @colour_pairs << {
                        :number => number,
                        :fg => fg,
                        :bg => bg
                    }
                when /^lang\.(.+?)\.indent\.indenters(\.case_insensitive)?$/
                    case_insensitive = ( $2 != nil )
                    if case_insensitive
                        @indenters[ $1 ] = Regexp.new( arg, Regexp::IGNORECASE )
                    else
                        @indenters[ $1 ] = Regexp.new arg
                    end
                when /^lang\.(.+?)\.indent\.unindenters(\.case_insensitive)?$/
                    case_insensitive = ( $2 != nil )
                    if case_insensitive
                        @unindenters[ $1 ] = Regexp.new( arg, Regexp::IGNORECASE )
                    else
                        @unindenters[ $1 ] = Regexp.new arg
                    end
                when /^lang\.(.+?)\.indent\.preventers(\.case_insensitive)?$/,
                        /^lang\.(.+?)\.indent\.ignore(\.case_insensitive)?$/,
                        /^lang\.(.+?)\.context\.ignore(\.case_insensitive)?$/
                    case_insensitive = ( $2 != nil )
                    if case_insensitive
                        @settings[ command ] = Regexp.new( arg, Regexp::IGNORECASE )
                    else
                        @settings[ command ] = Regexp.new arg
                    end
                when /^lang\.(.+?)\.filemask$/
                    @filemasks[ $1 ] = Regexp.new arg
                when /^lang\.(.+?)\.bangmask$/
                    @bangmasks[ $1 ] = Regexp.new arg
                when "context.visible", "context.combined", "eof_newline", "view.nonfilelines.visible",
                        /^lang\.(.+?)\.indent\.(?:auto|roundup|using_tabs)$/,
                        "found_cursor_start", "convert_tabs"
                    @settings[ command ] = arg.to_b
                when "context.format", "context.separator.format", "status.format"
                    @settings[ command ] = arg.toFormatting
                when "logfile"
                    @logfilename = arg.subHome
                when "context.separator", "status.left", "status.right", "status.filler",
                        "status.modified_str", "status.unnamed_str", "status.selecting_str",
                        "status.read_only_str", /^lang\..+?\.indent\.ignore\.charset$/,
                        /^lang\.(.+?)\.tokens\.([^.]+)\.change_to$/, "view.nonfilelines.character",
                        'interaction.blink_string', 'diff_command'
                    @settings[ command ] = arg
                when "status.vars"
                    @settings[ command ] = arg.split( /\s+/ )
                when /^lang\.(.+?)\.indent\.size$/, /^lang\.(.+?)\.tabsize$/
                    @settings[ command ] = arg.to_i
                when "context.max_levels", "context.max_segment_width", "max_clips", "max_undo_lines",
                        "view.margin.x", "view.margin.y", "view.scroll_amount", "view.lookback"
                    @settings[ command ] = arg.to_i
                when "view.jump.x", "view.jump.y"
                    value = arg.to_i
                    if value < 1
                        value = 1
                    end
                    @settings[ command ] = value
                when "bol_behaviour", "bol_behavior"
                    case arg.downcase
                        when "zero"
                            @settings[ "bol_behaviour" ] = BOL_ZERO
                        when "first-char"
                            @settings[ "bol_behaviour" ] = BOL_FIRST_CHAR
                        when "alternating-zero"
                            @settings[ "bol_behaviour" ] = BOL_ALT_ZERO
                        else # default
                            @settings[ "bol_behaviour" ] = BOL_ALT_FIRST_CHAR
                    end
                when "context.delay", 'interaction.blink_duration', 'interaction.choice_delay'
                    @settings[ command ] = arg.to_f
            end
        end
    end
    protected :parseConfigurationFile

    def getTokenRegexp( hash, arg, match )
        language = match[ 1 ]
        token_class = match[ 2 ]
        case_insensitive = ( match[ 3 ] != nil )
        hash[ language ] = ( hash[ language ] or Hash.new )
        if case_insensitive
            hash[ language ][ token_class ] = Regexp.new( arg, Regexp::IGNORECASE )
        else
            hash[ language ][ token_class ] = Regexp.new arg
        end
    end

    def redraw
        loadConfiguration
        initializeDisplay
        updateStatusLine
        updateContextLine
        @current_buffer.display
    end

    def log( string )
        @log.puts string
        @log.flush
    end
    
    def debugLog( string )
        @debug.puts( Time.now.strftime( "[%a %H:%M:%S] #{string}" ) )
        @debug.flush
    end
    
    def registerProc( proc, hook_name, priority = 0 )
        @hooks[ hook_name ] << { :proc => proc, :priority => priority }
    end
    
    def clearNonMovementFlag
        @there_was_non_movement = false
    end
    
    # -----------------------------------------------------------------------

    def main_window_height
        # One line for the status line
        # One line for the input line
        # One line for the context line
        retval = lines - 2
        if @settings[ "context.visible" ] and not @settings[ "context.combined" ]
            retval = retval - 1
        end
        return retval
    end

    def main_window_width
        return cols
    end

    def start
        initializeDisplay
        
        @hooks = {
            :after_save => [],
            :after_startup => [],
        }
        Dir[ "#{@script_dir}/*" ].each do |script|
            begin
                require script
            rescue Exception => e
                showException(
                    e,
                    [
                        "There is a syntax error in the script.",
                        "An invalid hook name was used."
                    ]
                )
            end
        end
        @hooks.each do |hook_name, hook|
            hook.sort { |a,b| a[ :priority ] <=> b[ :priority ] }
        end

        setILine "Diakonos #{VERSION} (#{LAST_MODIFIED})   F1 for help  F12 to configure"
        
        num_opened = 0
        if @files.length == 0 and @read_only_files.length == 0
            num_opened += 1 if openFile
        else
            @files.each do |file|
                num_opened += 1 if openFile file
            end
            @read_only_files.each do |file|
                num_opened += 1 if openFile( file, Buffer::READ_ONLY )
            end
        end
        
        if num_opened > 0
            switchToBufferNumber 1
            
            updateStatusLine
            updateContextLine
            
            if @post_load_script != nil
                eval @post_load_script
            end
            
            runHookProcs( :after_startup )
            
            begin
                # Main keyboard loop.
                while not @quitting
                    processKeystroke
                    @win_main.refresh
                end
            rescue SignalException => e
                debugLog "Terminated by signal (#{e.message})"
            end
            
            @debug.close
        end
    end
    
    # context is an array of characters (bytes) which are keystrokes previously
    # typed (in a chain of keystrokes)
    def processKeystroke( context = [] )
        c = @win_main.getch
        
        if @capturing_keychain
            if c == ENTER
                @capturing_keychain = false
                @current_buffer.deleteSelection
                str = context.to_keychain_s.strip
                @current_buffer.insertString str 
                cursorRight( Buffer::STILL_TYPING, str.length )
            else
                keychain_pressed = context.concat [ c ]
                
                function_and_args = @keychains.getLeaf( keychain_pressed )
                
                if function_and_args != nil
                    function, args = function_and_args
                end
                
                partial_keychain = @keychains.getNode( keychain_pressed )
                if partial_keychain != nil
                    setILine( "Part of existing keychain: " + keychain_pressed.to_keychain_s + "..." )
                else
                    setILine keychain_pressed.to_keychain_s + "..."
                end
                processKeystroke( keychain_pressed )
            end
        else
        
            if context.empty?
                case c
                    when PRINTABLE_CHARACTERS
                        if @macro_history != nil
                            @macro_history.push "typeCharacter #{c}"
                        end
                        if not @there_was_non_movement
                            @there_was_non_movement = true
                        end
                        typeCharacter c
                        return
                end
            end
            keychain_pressed = context.concat [ c ]
            
            function_and_args = @keychains.getLeaf( keychain_pressed )
            
            if function_and_args != nil
                function, args = function_and_args
                setILine if not @settings[ "context.combined" ]
                
                if args != nil
                    to_eval = "#{function}( #{args} )"
                else
                    to_eval = function
                end
                
                if @macro_history != nil
                    @macro_history.push to_eval
                end
                
                begin
                    eval to_eval, nil, "eval"
                    @last_commands << to_eval unless to_eval == "repeatLast"
                    if not @there_was_non_movement
                        @there_was_non_movement = ( not to_eval.movement? )
                    end
                rescue Exception => e
                    debugLog e.message
                    debugLog e.backtrace.join( "\n\t" )
                    showException e
                end
            else
                partial_keychain = @keychains.getNode( keychain_pressed )
                if partial_keychain != nil
                    setILine( keychain_pressed.to_keychain_s + "..." )
                    processKeystroke( keychain_pressed )
                else
                    setILine "Nothing assigned to #{keychain_pressed.to_keychain_s}"
                end
            end
        end
    end
    protected :processKeystroke

    # Display text on the interaction line.
    def setILine( string = "" )
        curs_set 0
        @win_interaction.setpos( 0, 0 )
        @win_interaction.addstr( "%-#{cols}s" % string )
        @win_interaction.refresh
        curs_set 1
        return string.length
    end
    
    def showClips
        clip_filename = @diakonos_home + "/clips.txt"
        File.open( clip_filename, "w" ) do |f|
            @clipboard.each do |clip|
                log clip
                f.puts clip
                f.puts "---------------------------"
            end
        end
        openFile clip_filename
    end

    def switchTo( buffer )
        switched = false
        if buffer != nil
            @buffer_stack -= [ @current_buffer ]
            @buffer_stack.push @current_buffer if @current_buffer != nil
            @current_buffer = buffer
            updateStatusLine
            updateContextLine
            buffer.display
            switched = true
        end
        
        return switched
    end
    protected :switchTo

    def buildStatusLine( truncation = 0 )
        var_array = Array.new
        @settings[ "status.vars" ].each do |var|
            case var
                when "buffer_number"
                    var_array.push bufferToNumber( @current_buffer )
                when "col"
                    var_array.push( @current_buffer.last_screen_col + 1 )
                when "filename"
                    name = @current_buffer.nice_name
                    var_array.push( name[ ([ truncation, name.length ].min)..-1 ] )
                when "modified"
                    if @current_buffer.modified
                        var_array.push @settings[ "status.modified_str" ]
                    else
                        var_array.push ""
                    end
                when "num_buffers"
                    var_array.push @buffers.length
                when "num_lines"
                    var_array.push @current_buffer.length
                when "row", "line"
                    var_array.push( @current_buffer.last_row + 1 )
                when "read_only"
                    if @current_buffer.read_only
                        var_array.push @settings[ "status.read_only_str" ]
                    else
                        var_array.push ""
                    end
                when "selecting"
                    if @current_buffer.changing_selection
                        var_array.push @settings[ "status.selecting_str" ]
                    else
                        var_array.push ""
                    end
                when "type"
                    var_array.push @current_buffer.original_language
            end
        end
        str = nil
        begin
            status_left = @settings[ "status.left" ]
            field_count = status_left.count "%"
            status_left = status_left % var_array[ 0...field_count ]
            status_right = @settings[ "status.right" ] % var_array[ field_count..-1 ]
            filler_string = @settings[ "status.filler" ]
            fill_amount = (cols - status_left.length - status_right.length) / filler_string.length
            if fill_amount > 0
                filler = filler_string * fill_amount
            else
                filler = ""
            end
            str = status_left + filler + status_right
        rescue ArgumentError => e
            str = "%-#{cols}s" % "(status line configuration error)"
        end
        return str
    end
    protected :buildStatusLine

    def updateStatusLine
        str = buildStatusLine
        if str.length > cols
            str = buildStatusLine( str.length - cols )
        end
        curs_set 0
        @win_status.setpos( 0, 0 )
        @win_status.addstr str
        @win_status.refresh
        curs_set 1
    end

    def updateContextLine
        if @win_context != nil
            @context_thread.exit if @context_thread != nil
            @context_thread = Thread.new do ||

                context = @current_buffer.context

                curs_set 0
                @win_context.setpos( 0, 0 )
                chars_printed = 0
                if context.length > 0
                    truncation = [ @settings[ "context.max_levels" ], context.length ].min
                    max_length = [
                        ( cols / truncation ) - @settings[ "context.separator" ].length,
                        ( @settings[ "context.max_segment_width" ] or cols )
                    ].min
                    line = nil
                    context_subset = context[ 0...truncation ]
                    context_subset = context_subset.collect do |line|
                        line.strip[ 0...max_length ]
                    end

                    context_subset.each do |line|
                        @win_context.attrset @settings[ "context.format" ]
                        @win_context.addstr line
                        chars_printed += line.length
                        @win_context.attrset @settings[ "context.separator.format" ]
                        @win_context.addstr @settings[ "context.separator" ]
                        chars_printed += @settings[ "context.separator" ].length
                    end
                end

                @iline_mutex.synchronize do
                    @win_context.attrset @settings[ "context.format" ]
                    @win_context.addstr( " " * ( cols - chars_printed ) )
                    @win_context.refresh
                end
                @display_mutex.synchronize do
                    @win_main.setpos( @current_buffer.last_screen_y, @current_buffer.last_screen_x )
                    @win_main.refresh
                end
                curs_set 1
            end
            
            @context_thread.priority = -2
        end
    end
    
    def displayEnqueue( buffer )
        @display_queue_mutex.synchronize do
            @display_queue = buffer
        end
    end
    
    def displayDequeue
        @display_queue_mutex.synchronize do
            if @display_queue != nil
                Thread.new( @display_queue ) do |b|
                    @display_mutex.lock
                    @display_mutex.unlock
                    b.display
                end
                @display_queue = nil
            end
        end
    end

    # completion_array is the array of strings that tab completion can use
    def getUserInput( prompt, history = @rlh_general, initial_text = "", completion_array = nil )
        if @playing_macro
            retval = @macro_input_history.shift
        else
            pos = setILine prompt
            @win_interaction.setpos( 0, pos )
            retval = Diakonos::Readline.new( self, @win_interaction, initial_text, completion_array, history ).readline
            if @macro_history != nil
                @macro_input_history.push retval
            end
            setILine
        end
        return retval
    end

    def getLanguageFromName( name )
        retval = nil
        @filemasks.each do |language,filemask|
            if name =~ filemask
                retval = language
                break
            end
        end
        return retval
    end
    
    def getLanguageFromShaBang( first_line )
        retval = nil
        @bangmasks.each do |language,bangmask|
            if first_line =~ /^#!/ and first_line =~ bangmask
                retval = language
                break
            end
        end
        return retval
    end
    
    def showException( e, probable_causes = [ "Unknown" ] )
        begin
            File.open( @diakonos_home + "/diakonos.err", "w" ) do |f|
                f.puts "Diakonos Error:"
                f.puts
                f.puts e.message
                f.puts
                f.puts "Probable Causes:"
                f.puts
                probable_causes.each do |pc|
                    f.puts "- #{pc}"
                end
                f.puts
                f.puts "----------------------------------------------------"
                f.puts "If you can reproduce this error, please report it at"
                f.puts "http://rome.purepistos.net/issues/diakonos/newticket !"
                f.puts "----------------------------------------------------"
                f.puts e.backtrace
            end
            openFile( @diakonos_home + "/diakonos.err" )
        rescue Exception => e2
            debugLog "EXCEPTION: #{e.message}"
            debugLog "\t#{e.backtrace}"
        end
    end
    
    def logBacktrace
        begin
            raise Exception
        rescue Exception => e
            e.backtrace[ 1..-1 ].each do |x|
                debugLog x
            end
        end
    end

    # The given buffer_number should be 1-based, not zero-based.
    # Returns nil if no such buffer exists.
    def bufferNumberToName( buffer_number )
        return nil if buffer_number < 1

        number = 1
        buffer_name = nil
        @buffers.each_key do |name|
            if number == buffer_number
                buffer_name = name
                break
            end
            number += 1
        end
        return buffer_name
    end

    # The returned value is 1-based, not zero-based.
    # Returns nil if no such buffer exists.
    def bufferToNumber( buffer )
        number = 1
        buffer_number = nil
        @buffers.each_value do |b|
            if b == buffer
                buffer_number = number
                break
            end
            number += 1
        end
        return buffer_number
    end

    def subShellVariables( string )
        return nil if string == nil

        retval = string
        retval = retval.subHome
        
        # Current buffer filename
        retval.gsub!( /\$f/, ( $1 or "" ) + ( @current_buffer.name or "" ) )
        
        # space-separated list of all buffer filenames
        name_array = Array.new
        @buffers.each_value do |b|
            name_array.push b.name
        end
        retval.gsub!( /\$F/, ( $1 or "" ) + ( name_array.join(' ') or "" ) )
        
        # Get user input, sub it in
        if retval =~ /\$i/
            user_input = getUserInput( "Argument: ", @rlh_shell )
            retval.gsub!( /\$i/, user_input )
        end
        
        # Current clipboard text
        if retval =~ /\$c/
            clip_filename = @diakonos_home + "/clip.txt"
            File.open( clip_filename, "w" ) do |clipfile|
                if @clipboard.clip != nil
                    clipfile.puts( @clipboard.clip.join( "\n" ) )
                end
            end
            retval.gsub!( /\$c/, clip_filename )
        end
        
        # Currently selected text
        if retval =~ /\$s/
            text_filename = @diakonos_home + "/selected.txt"
            
            File.open( text_filename, "w" ) do |textfile|
                selected_text = @current_buffer.selected_text
                if selected_text != nil
                    textfile.puts( selected_text.join( "\n" ) )
                end
            end
            retval.gsub!( /\$s/, text_filename )
        end
        
        return retval
    end
    
    def showMessage( message, non_interaction_duration = @settings[ 'interaction.choice_delay' ] )
        terminateMessage
        
        @message_expiry = Time.now + non_interaction_duration
        @message_thread = Thread.new do
            time_left = @message_expiry - Time.now
            while time_left > 0
                setILine "(#{time_left.round}) #{message}"
                @win_main.setpos( @saved_main_y, @saved_main_x )
                sleep 1
                time_left = @message_expiry - Time.now
            end
            setILine message
            @win_main.setpos( @saved_main_y, @saved_main_x )
        end
    end
    
    def terminateMessage
        if @message_thread != nil and @message_thread.alive?
            @message_thread.terminate
            @message_thread = nil
        end
    end
    
    def interactionBlink( message = nil )
        terminateMessage
        setILine @settings[ 'interaction.blink_string' ]
        sleep @settings[ 'interaction.blink_duration' ]
        setILine message if message != nil
    end
    
    # choices should be an array of CHOICE_* constants.
    # default is what is returned when Enter is pressed.
    def getChoice( prompt, choices, default = nil )
        retval = @iterated_choice
        if retval != nil
            @choice_iterations -= 1
            if @choice_iterations < 1
                @iterated_choice = nil
                @do_display = true
            end
            return retval 
        end
        
        @saved_main_x = @win_main.curx
        @saved_main_y = @win_main.cury

        msg = prompt + " "
        choice_strings = choices.collect do |choice|
            CHOICE_STRINGS[ choice ]
        end
        msg << choice_strings.join( ", " )
        
        if default.nil?
            showMessage msg
        else
            setILine msg
        end
        
        c = nil
        while retval.nil?
            c = @win_interaction.getch
            
            case c
                when KEY_NPAGE
                    pageDown
                when KEY_PPAGE
                    pageUp
                else
                    if @message_expiry != nil and Time.now < @message_expiry
                        interactionBlink
                        showMessage msg
                    else
                        case c
                            when Diakonos::ENTER
                                retval = default
                            when ?0..?9
                                if @choice_iterations < 1
                                    @choice_iterations = ( c - ?0 )
                                else
                                    @choice_iterations = @choice_iterations * 10 + ( c - ?0 )
                                end
                            else
                                choices.each do |choice|
                                    if CHOICE_KEYS[ choice ].include? c
                                        retval = choice
                                        break
                                    end
                                end
                        end
                        
                        if retval.nil?
                            interactionBlink( msg )
                        end
                    end
            end
        end
        
        terminateMessage
        setILine

        if @choice_iterations > 0
            @choice_iterations -= 1
            @iterated_choice = retval
            @do_display = false
        end
        
        return retval
    end

    def startRecordingMacro( name = nil )
        return if @macro_history != nil
        @macro_name = name
        @macro_history = Array.new
        @macro_input_history = Array.new
        setILine "Started macro recording."
    end
    protected :startRecordingMacro

    def stopRecordingMacro
        @macro_history.pop  # Remove the stopRecordingMacro command itself
        @macros[ @macro_name ] = [ @macro_history, @macro_input_history ]
        @macro_history = nil
        @macro_input_history = nil
        setILine "Stopped macro recording."
    end
    protected :stopRecordingMacro

    def typeCharacter( c )
        @current_buffer.deleteSelection( Buffer::DONT_DISPLAY )
        @current_buffer.insertChar c
        cursorRight( Buffer::STILL_TYPING )
    end
    
    def loadTags
        @tags = Hash.new
        if @current_buffer != nil and @current_buffer.name != nil
            path = File.expand_path( File.dirname( @current_buffer.name ) )
            tagfile = path + "/tags"
        else
            tagfile = "./tags"
        end
        if FileTest.exists? tagfile
            IO.foreach( tagfile ) do |line_|
                line = line_.chomp
                # <tagname>\t<filepath>\t<line number or regexp>\t<kind of tag>
                tag, file, command, kind, rest = line.split( /\t/ )
                command.gsub!( /;"$/, "" )
                if command =~ /^\/.*\/$/
                    command = command[ 1...-1 ]
                end
                @tags[ tag ] ||= Array.new
                @tags[ tag ].push CTag.new( file, command, kind, rest )
            end
        else
            setILine "(tags file not found)"
        end
    end
    
    def refreshAll
        @win_main.refresh
        if @win_context != nil
            @win_context.refresh
        end
        @win_status.refresh
        @win_interaction.refresh
    end
    
    def openListBuffer
        @list_buffer = openFile( @list_filename )
    end
    
    def closeListBuffer
        closeFile( @list_buffer )
    end
    
    def runHookProcs( hook_id, *args )
        @hooks[ hook_id ].each do |hook_proc|
            hook_proc[ :proc ].call( *args )
        end
    end
    
    # --------------------------------------------------------------------
    #
    # Program Functions

    def addNamedBookmark( name_ = nil )
        if name_ == nil
            name = getUserInput "Bookmark name: "
        else
            name = name_
        end

        if name != nil
            @bookmarks[ name ] = Bookmark.new( @current_buffer, @current_buffer.currentRow, @current_buffer.currentColumn, name )
            setILine "Added bookmark #{@bookmarks[ name ].to_s}."
        end
    end

    def anchorSelection
        @current_buffer.anchorSelection
        updateStatusLine
    end

    def backspace
        delete if( @current_buffer.changing_selection or cursorLeft( Buffer::STILL_TYPING ) )
    end

    def carriageReturn
        @current_buffer.carriageReturn
        @current_buffer.deleteSelection
    end
    
    def changeSessionSetting( key_ = nil, value = nil, do_redraw = DONT_REDRAW )
        if key_ == nil
            key = getUserInput( "Setting: " )
        else
            key = key_
        end

        if key != nil
            if value == nil
                value = getUserInput( "Value: " )
            end
            case @settings[ key ]
                when String
                    value = value.to_s
                when Fixnum
                    value = value.to_i
                when TrueClass, FalseClass
                    value = value.to_b
            end
            @session_settings[ key ] = value
            redraw if do_redraw
            setILine "#{key} = #{value}"
        end
    end

    def clearMatches
        @current_buffer.clearMatches Buffer::DO_DISPLAY
    end

    # Returns the choice the user made, or nil if the user was not prompted to choose.
    def closeFile( buffer = @current_buffer, to_all = nil )
        return nil if buffer == nil
        
        choice = nil
        if @buffers.has_value?( buffer )
            do_closure = true

            if buffer.modified
                if not buffer.read_only
                    if to_all == nil
                        choices = [ CHOICE_YES, CHOICE_NO, CHOICE_CANCEL ]
                        if @quitting
                            choices.concat [ CHOICE_YES_TO_ALL, CHOICE_NO_TO_ALL ]
                        end
                        choice = getChoice(
                            "Save changes to #{buffer.nice_name}?",
                            choices,
                            CHOICE_CANCEL
                        )
                    else
                        choice = to_all
                    end
                    case choice
                        when CHOICE_YES, CHOICE_YES_TO_ALL
                            do_closure = true
                            saveFile( buffer )
                        when CHOICE_NO, CHOICE_NO_TO_ALL
                            do_closure = true
                        when CHOICE_CANCEL
                            do_closure = false
                    end
                end
            end

            if do_closure
                del_buffer_key = nil
                previous_buffer = nil
                to_switch_to = nil
                switching = false
                
                # Search the buffer hash for the buffer we want to delete,
                # and mark the one we will switch to after deletion.
                @buffers.each do |buffer_key,buf|
                    if switching
                        to_switch_to = buf
                        break
                    end
                    if buf == buffer
                        del_buffer_key = buffer_key
                        switching = true
                        next
                    end
                    previous_buffer = buf
                end
                
                buf = nil
                while(
                    ( not @buffer_stack.empty? ) and
                    ( not @buffers.values.include?( buf ) ) or
                    ( @buffers.index( buf ) == del_buffer_key )
                ) do
                    buf = @buffer_stack.pop
                end
                if @buffers.values.include?( buf )
                    to_switch_to = buf
                end
                
                if to_switch_to != nil
                    switchTo( to_switch_to )
                elsif previous_buffer != nil
                    switchTo( previous_buffer )
                else
                    # No buffers left.  Open a new blank one.
                    openFile
                end

                @buffers.delete del_buffer_key

                updateStatusLine
                updateContextLine
            end
        else
            log "No such buffer: #{buffer.name}"
        end

        return choice
    end
    
    def collapseWhitespace
        @current_buffer.collapseWhitespace
    end

    def copySelection
        @clipboard.addClip @current_buffer.copySelection
        removeSelection
    end

    # Returns true iff the cursor changed positions
    def cursorDown
        return @current_buffer.cursorTo( @current_buffer.last_row + 1, @current_buffer.last_col, Buffer::DO_DISPLAY, Buffer::STOPPED_TYPING, DONT_ADJUST_ROW )
    end

    # Returns true iff the cursor changed positions
    def cursorLeft( stopped_typing = Buffer::STOPPED_TYPING )
        return @current_buffer.cursorTo( @current_buffer.last_row, @current_buffer.last_col - 1, Buffer::DO_DISPLAY, stopped_typing )
    end

    def cursorRight( stopped_typing = Buffer::STOPPED_TYPING, amount = 1 )
        return @current_buffer.cursorTo( @current_buffer.last_row, @current_buffer.last_col + amount, Buffer::DO_DISPLAY, stopped_typing )
    end

    # Returns true iff the cursor changed positions
    def cursorUp
        return @current_buffer.cursorTo( @current_buffer.last_row - 1, @current_buffer.last_col, Buffer::DO_DISPLAY, Buffer::STOPPED_TYPING, DONT_ADJUST_ROW )
    end

    def cursorBOF
        @current_buffer.cursorTo( 0, 0, Buffer::DO_DISPLAY )
    end

    def cursorBOL
        @current_buffer.cursorToBOL
    end

    def cursorEOL
        y = @win_main.cury
        @current_buffer.cursorTo( @current_buffer.last_row, @current_buffer.lineAt( y ).length, Buffer::DO_DISPLAY )
    end

    def cursorEOF
        @current_buffer.cursorToEOF
    end

    # Top of view
    def cursorTOV
        @current_buffer.cursorToTOV
    end

    # Bottom of view
    def cursorBOV
        @current_buffer.cursorToBOV
    end
    
    def cursorReturn( dir_str = "backward" )
        stack_pointer, stack_size = @current_buffer.cursorReturn( dir_str.toDirection( :backward ) )
        setILine( "Location: #{stack_pointer+1}/#{stack_size}" )
    end

    def cutSelection
        delete if @clipboard.addClip( @current_buffer.copySelection )
    end

    def delete
        @current_buffer.delete
    end

    def deleteAndStoreLine
        removed_text = @current_buffer.deleteLine
        if removed_text
            if @last_commands[ -1 ] =~ /^deleteAndStoreLine/
                @clipboard.appendToClip( [ removed_text, "" ] )
            else
                @clipboard.addClip( [ removed_text, "" ] )
            end
        end
    end

    def deleteLine
        removed_text = @current_buffer.deleteLine
        @clipboard.addClip( [ removed_text, "" ] ) if removed_text
    end

    def deleteToEOL
        removed_text = @current_buffer.deleteToEOL
        @clipboard.addClip( removed_text ) if removed_text
    end
    
    def evaluate( code_ = nil )
        if code_ == nil
            if @current_buffer.changing_selection
                selected_text = @current_buffer.copySelection[ 0 ]
            end
            code = getUserInput( "Ruby code: ", @rlh_general, ( selected_text or "" ), FUNCTIONS )
        else
            code = code_
        end
        
        if code != nil
            begin
                eval code
            rescue Exception => e
                showException(
                    e,
                    [
                        "The code given to evaluate has a syntax error.",
                        "The code given to evaluate refers to a Diakonos command which does not exist, or is misspelled.",
                        "The code given to evaluate refers to a Diakonos command with missing arguments.",
                        "The code given to evaluate refers to a variable or method which does not exist.",
                    ]
                )
            end
        end
    end
    
    def find( dir_str = "down", case_sensitive = CASE_INSENSITIVE, regexp_source_ = nil, replacement = nil )
        if regexp_source_ == nil
            if @current_buffer.changing_selection
                selected_text = @current_buffer.copySelection[ 0 ]
            end
            regexp_source = getUserInput( "Search regexp: ", @rlh_search, ( selected_text or "" ) )
        else
            regexp_source = regexp_source_
        end

        if regexp_source != nil
            direction = dir_str.toDirection
            rs_array = regexp_source.newlineSplit
            regexps = Array.new
            begin
                rs_array.each do |regexp_source|
                    if not case_sensitive
                        regexps.push Regexp.new( regexp_source, Regexp::IGNORECASE )
                    else
                        regexps.push Regexp.new( regexp_source )
                    end
                end
            rescue Exception => e
                exception_thrown = true
                rs_array.each do |regexp_source|
                    if not case_sensitive
                        regexps.push Regexp.new( Regexp.escape( regexp_source ), Regexp::IGNORECASE )
                    else
                        regexps.push Regexp.new( Regexp.escape( regexp_source ) )
                    end
                end
            end
            if replacement == ASK_REPLACEMENT
                replacement = getUserInput( "Replace with: ", @rlh_search )
            end
            
            setILine( "Searching literally; #{e.message}" ) if exception_thrown
            
            @current_buffer.find( regexps, direction, replacement )
            @last_search_regexps = regexps
        end
    end

    def findAgain( dir_str = nil )
        if dir_str != nil
            direction = dir_str.toDirection
            @current_buffer.findAgain( @last_search_regexps, direction )
        else
            @current_buffer.findAgain( @last_search_regexps )
        end
    end

    def findAndReplace
        searchAndReplace
    end

    def findExact( dir_str = "down", search_term_ = nil )
        if search_term_ == nil
            if @current_buffer.changing_selection
                selected_text = @current_buffer.copySelection[ 0 ]
            end
            search_term = getUserInput( "Search for: ", @rlh_search, ( selected_text or "" ) )
        else
            search_term = search_term_
        end
        if search_term != nil
            direction = dir_str.toDirection
            regexp = Regexp.new( Regexp.escape( search_term ) )
            @current_buffer.find( regexp, direction )
            @last_search_regexps = regexp
        end
    end

    def goToLineAsk
        input = getUserInput( "Go to [line number|+lines][,column number]: " )
        if input != nil
            row = nil
            
            if input =~ /([+-]\d+)/
                row = @current_buffer.last_row + $1.to_i
                col = @current_buffer.last_col
            else
                input = input.split( /\D+/ ).collect { |n| n.to_i }
                if input.size > 0
                    if input[ 0 ] == 0
                        row = nil
                    else
                        row = input[ 0 ] - 1
                    end
                    if input[ 1 ] != nil
                        col = input[ 1 ] - 1
                    end
                end
            end
            
            if row
                @current_buffer.goToLine( row, col )
            end
        end
    end

    def goToNamedBookmark( name_ = nil )
        if name_ == nil
            name = getUserInput "Bookmark name: "
        else
            name = name_
        end

        if name != nil
            bookmark = @bookmarks[ name ]
            if bookmark != nil
                switchTo( bookmark.buffer )
                bookmark.buffer.cursorTo( bookmark.row, bookmark.col, Buffer::DO_DISPLAY )
            else
                setILine "No bookmark named '#{name}'."
            end
        end
    end

    def goToNextBookmark
        @current_buffer.goToNextBookmark
    end

    def goToPreviousBookmark
        @current_buffer.goToPreviousBookmark
    end

    def goToTag( tag_ = nil )
        loadTags
        
        # If necessary, prompt for tag name.
        
        if tag_ == nil
            if @current_buffer.changing_selection
                selected_text = @current_buffer.copySelection[ 0 ]
            end
            tag_name = getUserInput( "Tag name: ", @rlh_general, ( selected_text or "" ), @tags.keys )
        else
            tag_name = tag_
        end

        tag_array = @tags[ tag_name ]
        if tag_array != nil and tag_array.length > 0
            if i = tag_array.index( @last_tag )
                tag = ( tag_array[ i + 1 ] or tag_array[ 0 ] )
            else
                tag = tag_array[ 0 ]
            end
            @last_tag = tag
            @tag_stack.push [ @current_buffer.name, @current_buffer.last_row, @current_buffer.last_col ]
            if switchTo( @buffers[ tag.file ] )
                #@current_buffer.goToLine( 0 )
            else
                openFile( tag.file )
            end
            line_number = tag.command.to_i
            if line_number > 0
                @current_buffer.goToLine( line_number - 1 )
            else
                find( "down", CASE_SENSITIVE, tag.command )
            end
        elsif tag_name != nil
            setILine "No such tag: '#{tag_name}'"
        end
    end
    
    def goToTagUnderCursor
        goToTag @current_buffer.wordUnderCursor
    end
    
    def help
        help_filename = @diakonos_home + "/diakonos.help"
        File.open( help_filename, "w" ) do |help_file|
            sorted_keychains = @keychains.paths_and_leaves.sort { |a,b|
                a[ :leaf ][ 0 ] <=> b[ :leaf ][ 0 ]
            }
            sorted_keychains.each do |keystrokes_and_function_and_args|
                keystrokes = keystrokes_and_function_and_args[ :path ]
                function, args = keystrokes_and_function_and_args[ :leaf ]
                function_string = function.deep_clone
                if args != nil and args.length > 0
                    function_string << "( #{args} )"
                end
                keychain_width = [ cols - function_string.length - 2, cols / 2 ].min
                help_file.puts(
                    "%-#{keychain_width}s%s" % [
                        keystrokes.to_keychain_s,
                        function_string
                    ]
                )
            end
        end
        openFile help_filename
    end

    def indent
        if( @current_buffer.changing_selection )
            @do_display = false
            mark = @current_buffer.selection_mark
            if mark.end_col > 0
                end_row = mark.end_row
            else
                end_row = mark.end_row - 1
            end
            (mark.start_row...end_row).each do |row|
                @current_buffer.indent row, Buffer::DONT_DISPLAY
            end
            @do_display = true
            @current_buffer.indent( end_row ) 
        else
            @current_buffer.indent
        end
    end
    
    def insertSpaces( num_spaces )
        if num_spaces > 0
            @current_buffer.deleteSelection
            @current_buffer.insertString( " " * num_spaces )
            cursorRight( Buffer::STILL_TYPING, num_spaces )
        end
    end
    
    def insertTab
        typeCharacter( TAB )
    end

    def loadScript( name_ = nil )
        if name_ == nil
            name = getUserInput( "File to load as script: ", @rlh_files )
        else
            name = name_
        end

        if name != nil
            thread = Thread.new( name ) do |f|
                begin
                    load( f )
                rescue Exception => e
                    showException(
                        e,
                        [
                            "The filename given does not exist.",
                            "The filename given is not accessible or readable.",
                            "The loaded script does not reference Diakonos commands as members of the global Diakonos object.  e.g. cursorBOL instead of $diakonos.cursorBOL",
                            "The loaded script has syntax errors.",
                            "The loaded script references objects or object members which do not exist."
                        ]
                    )
                end
                setILine "Loaded script '#{name}'."
            end

            loop do
                if thread.status != "run"
                    break
                else
                    sleep 0.1
                end
            end
            thread.join
        end
    end

    def newFile
        openFile
    end

    # Returns the buffer of the opened file, or nil.
    def openFile( filename = nil, read_only = false, force_revert = ASK_REVERT )
        do_open = true
        buffer = nil
        if filename != nil
            buffer_key = filename
            if(
                (not force_revert) and
                    ( (existing_buffer = @buffers[ filename ]) != nil ) and
                    ( filename !~ /\.diakonos/ )
            )
                switchTo( existing_buffer )
                choice = getChoice(
                    "Revert to on-disk version of #{existing_buffer.nice_name}?",
                    [ CHOICE_YES, CHOICE_NO ]
                )
                case choice
                    when CHOICE_NO
                        do_open = false
                end
            end
            
            if FileTest.exist?( filename )
                # Don't try to open non-files (i.e. directories, pipes, sockets, etc.)
                do_open &&= FileTest.file?( filename )
            end
        else
            buffer_key = @untitled_id
            @untitled_id += 1
        end
        
        if do_open
            # Is file readable?
            
            # Does the "file" utility exist?
            if @settings[ 'use_magic_file' ] and FileTest.exist?( "/usr/bin/file" ) and filename != nil and FileTest.exist?( filename )
                file_type = `/usr/bin/file -L #{filename}`
                if file_type !~ /text/ and file_type !~ /empty$/
                    choice = getChoice(
                        "#{filename} does not appear to be readable.  Try to open it anyway?",
                        [ CHOICE_YES, CHOICE_NO ],
                        CHOICE_NO
                    )
                    case choice
                        when CHOICE_NO
                            do_open = false
                    end
                    
                end
            end
            
            if do_open
                buffer = Buffer.new( self, filename, read_only )
                @buffers[ buffer_key ] = buffer
                switchTo( buffer )
            end
        end
        
        return buffer
    end

    def openFileAsk
        if @current_buffer != nil and @current_buffer.name != nil
            path = File.expand_path( File.dirname( @current_buffer.name ) ) + "/"
            file = getUserInput( "Filename: ", @rlh_files, path )
        else
            file = getUserInput( "Filename: ", @rlh_files )
        end
        if file != nil
            openFile file
            updateStatusLine
            updateContextLine
        end
    end
    
    def operateOnString(
        ruby_code = getUserInput( 'Ruby code: ', @rlh_general, 'str.' )
    )
        if ruby_code != nil
            str = @current_buffer.selected_string
            if str != nil and not str.empty?
                @current_buffer.paste eval( ruby_code )
            end
        end
    end

    def operateOnLines(
        ruby_code = getUserInput( 'Ruby code: ', @rlh_general, 'lines.collect { |l| l }' )
    )
        if ruby_code != nil
            lines = @current_buffer.selected_text
            if lines != nil and not lines.empty?
                if lines[ -1 ].empty?
                    lines.pop
                    popped = true
                end
                new_lines = eval( ruby_code )
                if popped
                    new_lines << ''
                end
                @current_buffer.paste new_lines
            end
        end
    end

    def operateOnEachLine(
        ruby_code = getUserInput( 'Ruby code: ', @rlh_general, 'line.' )
    )
        if ruby_code != nil
            lines = @current_buffer.selected_text
            if lines != nil and not lines.empty?
                if lines[ -1 ].empty?
                    lines.pop
                    popped = true
                end
                new_lines = eval( "lines.collect { |line| #{ruby_code} }" )
                if popped
                    new_lines << ''
                end
                @current_buffer.paste new_lines
            end
        end
    end

    def pageUp
        if @current_buffer.pitchView( -main_window_height, Buffer::DO_PITCH_CURSOR ) == 0
            cursorBOF
        end
        updateStatusLine
        updateContextLine
    end

    def pageDown
        if @current_buffer.pitchView( main_window_height, Buffer::DO_PITCH_CURSOR ) == 0
            @current_buffer.cursorToEOF
        end
        updateStatusLine
        updateContextLine
    end

    def parsedIndent
        if( @current_buffer.changing_selection )
            @do_display = false
            mark = @current_buffer.selection_mark
            (mark.start_row...mark.end_row).each do |row|
                @current_buffer.parsedIndent row, Buffer::DONT_DISPLAY
            end
            @do_display = true
            @current_buffer.parsedIndent mark.end_row
        else
            @current_buffer.parsedIndent
        end
        updateStatusLine
        updateContextLine
    end

    def paste
        @current_buffer.paste @clipboard.clip
    end

    def playMacro( name = nil )
        macro, input_history = @macros[ name ]
        if input_history != nil
            @macro_input_history = input_history.deep_clone
            if macro != nil
                @playing_macro = true
                macro.each do |command|
                    eval command
                end
                @playing_macro = false
                @macro_input_history = nil
            end
        end
    end
    
    def popTag
        tag = @tag_stack.pop
        if tag != nil
            if not switchTo( @buffers[ tag[ 0 ] ] )
                openFile( tag[ 0 ] )
            end
            @current_buffer.cursorTo( tag[ 1 ], tag[ 2 ], Buffer::DO_DISPLAY )
        else
            setILine "Tag stack empty."
        end
    end
    
    def printKeychain
        @capturing_keychain = true
        setILine "Type any chain of keystrokes or key chords, then press Enter..."
    end

    def quit
        @quitting = true
        to_all = nil
        @buffers.each_value do |buffer|
            if buffer.modified
                switchTo buffer
                closure_choice = closeFile( buffer, to_all )
                case closure_choice
                    when CHOICE_CANCEL
                        @quitting = false
                        break
                    when CHOICE_YES_TO_ALL, CHOICE_NO_TO_ALL
                        to_all = closure_choice
                end
            end
        end
    end

    def removeNamedBookmark( name_ = nil )
        if name_ == nil
            name = getUserInput "Bookmark name: "
        else
            name = name_
        end

        if name != nil
            bookmark = @bookmarks.delete name
            setILine "Removed bookmark #{bookmark.to_s}."
        end
    end

    def removeSelection
        @current_buffer.removeSelection
        updateStatusLine
    end

    def repeatLast
        eval @last_commands[ -1 ] if not @last_commands.empty?
    end

    # If the prompt is non-nil, ask the user yes or no question first.
    def revert( prompt = nil )
        do_revert = true
        
        current_text_file = @diakonos_home + '/current-buffer'
        @current_buffer.saveCopy( current_text_file )
        `#{@settings[ 'diff_command' ]} #{current_text_file} #{@current_buffer.name} > #{@diff_filename}`
        diff_buffer = openFile( @diff_filename )
        
        if prompt != nil
            choice = getChoice(
                prompt,
                [ CHOICE_YES, CHOICE_NO ]
            )
            case choice
                when CHOICE_NO
                    do_revert = false
            end
        end
        
        closeFile( diff_buffer )
        
        if do_revert
            openFile( @current_buffer.name, Buffer::READ_WRITE, FORCE_REVERT )
        end
    end

    def saveFile( buffer = @current_buffer )
        buffer.save
        runHookProcs( :after_save, buffer )
    end

    def saveFileAs
        if @current_buffer != nil and @current_buffer.name != nil
            path = File.expand_path( File.dirname( @current_buffer.name ) ) + "/"
            file = getUserInput( "Filename: ", @rlh_files, path )
        else
            file = getUserInput( "Filename: ", @rlh_files )
        end
        if file != nil
            #old_name = @current_buffer.name
            @current_buffer.save( file, PROMPT_OVERWRITE )
            #if not @current_buffer.modified
                # Save was okay.
                #@buffers.delete old_name
                #@buffers[ @current_buffer.name ] = @current_buffer
                #switchTo( @current_buffer )
            #end
        end
    end

    def scrollDown
        @current_buffer.pitchView( @settings[ "view.scroll_amount" ] || 1 )
        updateStatusLine
        updateContextLine
    end

    def scrollUp
        if @settings[ "view.scroll_amount" ] != nil
            @current_buffer.pitchView( -@settings[ "view.scroll_amount" ] )
        else
            @current_buffer.pitchView( -1 )
        end
        updateStatusLine
        updateContextLine
    end

    def searchAndReplace( case_sensitive = CASE_INSENSITIVE )
        find( "down", case_sensitive, nil, ASK_REPLACEMENT )
    end
    
    def seek( regexp_source, dir_str = "down" )
        if regexp_source != nil
            direction = dir_str.toDirection
            regexp = Regexp.new( regexp_source )
            @current_buffer.seek( regexp, direction )
        end
    end

    def setBufferType( type_ = nil )
        if type_ == nil
            type = getUserInput "Content type: "
        else
            type = type_
        end

        if type != nil
            if @current_buffer.setType( type )
                updateStatusLine
                updateContextLine
            end
        end
    end

    # If read_only is nil, the read_only state of the current buffer is toggled.
    # Otherwise, the read_only state of the current buffer is set to read_only.
    def setReadOnly( read_only = nil )
        if read_only != nil
            @current_buffer.read_only = read_only
        else
            @current_buffer.read_only = ( not @current_buffer.read_only )
        end
        updateStatusLine
    end

    def shell( command_ = nil )
        if command_ == nil
            command = getUserInput( "Command: ", @rlh_shell )
        else
            command = command_
        end

        if command != nil
            command = subShellVariables( command )

            result_file = @diakonos_home + "/shell-result.txt"
            File.open( result_file , "w" ) do |f|
                f.puts command
                f.puts
                close_screen

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

                t1.join
                t2.join

                init_screen
                refreshAll
            end
            openFile result_file
        end
    end
    
    def execute( command_ = nil )
        if command_ == nil
            command = getUserInput( "Command: ", @rlh_shell )
        else
            command = command_
        end

        if command != nil
            command = subShellVariables( command )

            close_screen

            success = system( command )
            if not success
                result = "Could not execute: #{command}"
            else
                result = "Return code: #{$?}"
            end

            init_screen
            refreshAll
            
            setILine result
        end
    end
    
    def pasteShellResult( command_ = nil )
        if command_ == nil
            command = getUserInput( "Command: ", @rlh_shell )
        else
            command = command_
        end

        if command != nil
            command = subShellVariables( command )

            close_screen
            
            begin
                @current_buffer.paste( `#{command} 2<&1`.split( /\n/, -1 ) )
            rescue Exception => e
                debugLog e.message
                debugLog e.backtrace.join( "\n\t" )
                showException e
            end
            
            init_screen
            refreshAll
        end
    end
    
    # Send the Diakonos job to background, as if with Ctrl-Z
    def suspend
        close_screen
        Process.kill( "SIGSTOP", $PID )
        init_screen
        refreshAll
    end

    def toggleMacroRecording( name = nil )
        if @macro_history != nil
            stopRecordingMacro
        else
            startRecordingMacro( name )
        end
    end

    def switchToBufferNumber( buffer_number_ )
        buffer_number = buffer_number_.to_i
        return if buffer_number < 1
        buffer_name = bufferNumberToName( buffer_number )
        if buffer_name != nil
            switchTo( @buffers[ buffer_name ] )
        end
    end

    def switchToNextBuffer
        buffer_number = bufferToNumber( @current_buffer )
        switchToBufferNumber( buffer_number + 1 )
    end

    def switchToPreviousBuffer
        buffer_number = bufferToNumber( @current_buffer )
        switchToBufferNumber( buffer_number - 1 )
    end

    def toggleBookmark
        @current_buffer.toggleBookmark
    end
    
    def toggleSelection
        @current_buffer.toggleSelection
        updateStatusLine
    end

    def toggleSessionSetting( key_ = nil, do_redraw = DONT_REDRAW )
        if key_ == nil
            key = getUserInput( "Setting: " )
        else
            key = key_
        end

        if key != nil
            value = nil
            if @session_settings[ key ].class == TrueClass or @session_settings[ key ].class == FalseClass
                value = ! @session_settings[ key ]
            elsif @settings[ key ].class == TrueClass or @settings[ key ].class == FalseClass
                value = ! @settings[ key ]
            end
            if value != nil
                @session_settings[ key ] = value
                redraw if do_redraw
                setILine "#{key} = #{value}"
            end
        end
    end
    
    def undo( buffer = @current_buffer )
        buffer.undo
    end

    def unindent
        if( @current_buffer.changing_selection )
            @do_display = false
            mark = @current_buffer.selection_mark
            if mark.end_col > 0
                end_row = mark.end_row
            else
                end_row = mark.end_row - 1
            end
            (mark.start_row...end_row).each do |row|
                @current_buffer.unindent row, Buffer::DONT_DISPLAY
            end
            @do_display = true
            @current_buffer.unindent( end_row ) 
        else
            @current_buffer.unindent
        end
    end

    def unundo( buffer = @current_buffer )
        buffer.unundo
    end
end

class Diakonos::Readline

    # completion_array is the array of strings that tab completion can use
    def initialize( diakonos, window, initial_text = "", completion_array = nil, history = [] )
        @window = window
        @diakonos = diakonos
        @initial_text = initial_text
        @completion_array = completion_array
        @list_filename = @diakonos.list_filename
        
        @history = history
        @history << initial_text
        @history_index = @history.length - 1
    end

    # Returns nil on cancel.
    def readline
        @input = @initial_text
        @icurx = @window.curx
        @icury = @window.cury
        @window.addstr @initial_text
        @input_cursor = @initial_text.length
        @opened_list_file = false

        loop do
            c = @window.getch

            case c
                when Diakonos::PRINTABLE_CHARACTERS
                    if @input_cursor == @input.length
                        @input << c
                        @window.addch c
                    else
                        @input = @input[ 0...@input_cursor ] + c.chr + @input[ @input_cursor..-1 ]
                        @window.setpos( @window.cury, @window.curx + 1 )
                        redrawInput
                    end
                    @input_cursor += 1
                when KEY_DC
                    if @input_cursor < @input.length
                        @window.delch
                        @input = @input[ 0...@input_cursor ] + @input[ (@input_cursor + 1)..-1 ]
                    end
                when Diakonos::BACKSPACE, Diakonos::CTRL_H
                    # KEY_LEFT
                    if @input_cursor > 0
                        @input_cursor += -1
                        @window.setpos( @window.cury, @window.curx - 1 )
                        
                        # KEY_DC
                        if @input_cursor < @input.length
                            @window.delch
                            @input = @input[ 0...@input_cursor ] + @input[ (@input_cursor + 1)..-1 ]
                        end
                    end
                when Diakonos::ENTER
                    break
                when Diakonos::ESCAPE, Diakonos::CTRL_C, Diakonos::CTRL_D, Diakonos::CTRL_Q
                    @input = nil
                    break
                when KEY_LEFT
                    if @input_cursor > 0
                        @input_cursor += -1
                        @window.setpos( @window.cury, @window.curx - 1 )
                    end
                when KEY_RIGHT
                    if @input_cursor < @input.length
                        @input_cursor += 1
                        @window.setpos( @window.cury, @window.curx + 1 )
                    end
                when KEY_HOME
                    @input_cursor = 0
                    @window.setpos( @icury, @icurx )
                when KEY_END
                    @input_cursor = @input.length
                    @window.setpos( @window.cury, @icurx + @input.length )
                when Diakonos::TAB
                    completeInput
                when KEY_NPAGE
                    @diakonos.pageDown
                when KEY_PPAGE
                    @diakonos.pageUp
                when KEY_UP
                    if @history_index > 0
                        @history[ @history_index ] = @input
                        @history_index -= 1
                        @input = @history[ @history_index ]
                        cursorWriteInput
                    end
                when KEY_DOWN
                    if @history_index < @history.length - 1
                        @history[ @history_index ] = @input
                        @history_index += 1
                        @input = @history[ @history_index ]
                        cursorWriteInput
                    end
                when Diakonos::CTRL_K
                    @input = ""
                    cursorWriteInput
                else
                    @diakonos.log "Other input: #{c}"
            end
        end
        
        @diakonos.closeListBuffer

        @history[ -1 ] = @input
        
        return @input
    end

    def redrawInput
        curx = @window.curx
        cury = @window.cury
        @window.setpos( @icury, @icurx )
        @window.addstr "%-#{ cols - curx }s%s" % [ @input, " " * ( cols - @input.length ) ]
        @window.setpos( cury, curx )
        @window.refresh
    end

    # Redisplays the input text starting at the start of the user input area,
    # positioning the cursor at the end of the text.
    def cursorWriteInput
        if @input != nil
            @input_cursor = @input.length
            @window.setpos( @window.cury, @icurx + @input.length )
            redrawInput
        end
    end

    def completeInput
        if @completion_array != nil and @input.length > 0
            len = @input.length
            matches = @completion_array.find_all { |el| el[ 0...len ] == @input and len < el.length }
        else
            matches = Dir.glob( ( @input.subHome() + "*" ).gsub( /\*\*/, "*" ) )
        end
        
        if matches.length == 1
            @input = matches[ 0 ]
            cursorWriteInput
            File.open( @list_filename, "w" ) do |f|
                f.puts "(unique)"
            end
            if @completion_array == nil and FileTest.directory?( @input )
                @input << "/"
                cursorWriteInput
                completeInput
            end
        elsif matches.length > 1
            common = matches[ 0 ]
            File.open( @list_filename, "w" ) do |f|
                i = nil
                matches.each do |match|
                    f.puts match
                    
                    if match[ 0 ] != common[ 0 ]
                        common = nil
                        break
                    end
                    
                    up_to = [ common.length - 1, match.length - 1 ].min
                    i = 1
                    while ( i <= up_to ) and ( match[ 0..i ] == common[ 0..i ] )
                        i += 1
                    end
                    common = common[ 0...i ]
                end
            end
            if common == nil
                File.open( @list_filename, "w" ) do |f|
                    f.puts "(no matches)"
                end
            else
                @input = common
                cursorWriteInput
            end
        else
            File.open( @list_filename, "w" ) do |f|
                f.puts "(no matches)"
            end
        end
        @diakonos.openListBuffer
        @window.setpos( @window.cury, @window.curx )
    end
end

if __FILE__ == $PROGRAM_NAME
    $diakonos = Diakonos.new( ARGV )
    $diakonos.start
end
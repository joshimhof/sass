module Haml
  module Precompiler
    # Designates an XHTML/XML element.
    ELEMENT         = ?%

    # Designates a <tt><div></tt> element with the given class.
    DIV_CLASS       = ?.

    # Designates a <tt><div></tt> element with the given id.
    DIV_ID          = ?#

    # Designates an XHTML/XML comment.
    COMMENT         = ?/

    # Designates an XHTML doctype.
    DOCTYPE         = ?!

    # Designates script, the result of which is output.
    SCRIPT          = ?=

    # Designates script, the result of which is flattened and output.
    FLAT_SCRIPT     = ?~

    # Designates script which is run but not output.
    SILENT_SCRIPT   = ?-

    # When following SILENT_SCRIPT, designates a comment that is not output.
    SILENT_COMMENT  = ?#

    # Designates a non-parsed line.
    ESCAPE          = ?\\

    # Designates a block of filtered text.
    FILTER          = ?:

    # Designates a non-parsed line. Not actually a character.
    PLAIN_TEXT      = -1

    # Keeps track of the ASCII values of the characters that begin a
    # specially-interpreted line.
    SPECIAL_CHARACTERS   = [
      ELEMENT,
      DIV_CLASS,
      DIV_ID,
      COMMENT,
      DOCTYPE,
      SCRIPT,
      FLAT_SCRIPT,
      SILENT_SCRIPT,
      ESCAPE,
      FILTER
    ]

    # The value of the character that designates that a line is part
    # of a multiline string.
    MULTILINE_CHAR_VALUE = ?|

    # Characters that designate that a multiline string may be about
    # to begin.
    MULTILINE_STARTERS   = SPECIAL_CHARACTERS - [?/]

    # Keywords that appear in the middle of a Ruby block with lowered
    # indentation. If a block has been started using indentation,
    # lowering the indentation  with one of these won't end the block.
    # For example:
    #
    #   - if foo
    #     %p yes!
    #   - else
    #     %p no!
    #
    # The block is ended after <tt>%p no!</tt>, because <tt>else</tt>
    # is a member of this array.
    MID_BLOCK_KEYWORDS   = ['else', 'elsif', 'rescue', 'ensure', 'when']

    # The Regex that matches an HTML comment command.
    COMMENT_REGEX = /\/(\[[\w\s\.]*\])?(.*)/

    # The Regex that matches a Doctype command.
    DOCTYPE_REGEX = /(\d\.\d)?[\s]*([a-z]*)/i

    # The Regex that matches an HTML tag command.
    TAG_REGEX = /[%]([-:\w]+)([-\w\.\#]*)(\{.*\})?(\[.*\])?([=\/\~]?)?(.*)?/

    # The Regex that matches a literal string or symbol value
    LITERAL_VALUE_REGEX = /^\s*(:(\w*)|(('|")([^\\\#'"]*?)\4))\s*$/

    private

    # Returns the precompiled string with the preamble and postamble
    def precompiled_with_ambles(local_names)
      preamble = <<END.gsub("\n", ";")
extend Haml::Helpers
@haml_stack ||= Array.new
@haml_stack.push(Haml::Buffer.new(#{options_for_buffer.inspect}))
@haml_is_haml = true
_hamlout = @haml_stack[-1]
_erbout = _hamlout.buffer
begin
END
      postamble = <<END.gsub("\n", ";")
rescue Exception => e
  raise Haml::Engine.add_exception_info(e, #{@precompiled.inspect}, #{@options[:filename].inspect})
end
@haml_is_haml = false
_hamlout.buffer
END
      preamble + locals_code(local_names) + @precompiled + postamble
    end

    def locals_code(names)
      names = names.keys if Hash == names

      names.map do |name|
        "#{name} = _haml_locals[#{name.to_sym.inspect}] || _haml_locals[#{name.to_s.inspect}]"
      end.join(';') + ';'
    end

    def precompile
      @precompiled = ''

      old_line = nil
      old_index = nil
      old_spaces = nil
      old_tabs = nil
      old_uline = nil
      (@template + "\n-#\n-#").each_with_index do |line, index|
        spaces, tabs = count_soft_tabs(line)
        uline = line.lstrip.chomp
        line = uline.rstrip
        
        if !line.empty?
          if old_line
            block_opened = tabs > old_tabs && !line.empty?
            
            suppress_render = handle_multiline(old_tabs, old_line, old_index) unless @flat_spaces != -1
            
            if !suppress_render
              line_empty = old_line.empty?

              process_indent(old_tabs, old_line) unless line_empty
              flat = @flat_spaces != -1


              if !flat && old_spaces != old_tabs * 2
                raise SyntaxError.new("Illegal Indentation: Only two space characters are allowed as tabulation.")
              end

              if flat
                push_flat(old_uline, old_spaces)
              elsif !line_empty && !@haml_comment
                process_line(old_line, old_index, block_opened)
              end

              if @flat_spaces == -1 && tabs - old_tabs > 1
                raise SyntaxError.new("Illegal Indentation: Indenting more than once per line is illegal.")
              end
            end
          end
          
          old_line = line
          old_index = index
          old_spaces = spaces
          old_tabs = tabs
          old_uline = uline
        elsif @flat_spaces != -1
          process_indent(old_tabs, old_line) unless old_line.empty?

          if @flat_spaces != -1
            push_flat(old_line, old_spaces)
            old_line = ''
            old_uline = ''
            old_spaces = 0
          end
        end
      end

      # Close all the open tags
      @template_tabs.times { close }
      flush_merged_text
    end
        
    # Processes and deals with lowering indentation.
    def process_indent(count, line)
      if count <= @template_tabs && @template_tabs > 0
        to_close = @template_tabs - count

        to_close.times do |i|
          offset = to_close - 1 - i
          unless offset == 0 && mid_block_keyword?(line)
            close
          end
        end
      end
    end


    # Processes a single line of Haml.
    #
    # This method doesn't return anything; it simply processes the line and
    # adds the appropriate code to <tt>@precompiled</tt>.
    def process_line(line, index, block_opened)
      @index = index + 1
      @block_opened = block_opened

      case line[0]
      when DIV_CLASS, DIV_ID
        render_div(line)
      when ELEMENT
        render_tag(line)
      when COMMENT
        render_comment(line)
      when SCRIPT
        sub_line = line[1..-1]
        if sub_line[0] == SCRIPT
          push_script(unescape_interpolation(sub_line[1..-1].strip), false)
        else
          push_script(sub_line, false)
        end
      when FLAT_SCRIPT
        push_flat_script(line[1..-1])
      when SILENT_SCRIPT
        sub_line = line[1..-1]
        unless sub_line[0] == SILENT_COMMENT
          mbk = mid_block_keyword?(line)
          push_silent(sub_line, !mbk, true)
          if (@block_opened && !mbk) || line[1..-1].split(' ', 2)[0] == "case"
            push_and_tabulate([:script])
          end
        else
          start_haml_comment
        end
      when FILTER
        name = line[1..-1].downcase
        start_filtered(options[:filters][name.to_s] || name)
      when DOCTYPE
        if line[0...3] == '!!!'
          render_doctype(line)
        else
          push_plain line
        end
      when ESCAPE
        push_plain line[1..-1]
      else
        push_plain line
      end
    end
    
    # Returns whether or not the line is a silent script line with one
    # of Ruby's mid-block keywords.
    def mid_block_keyword?(line)
      line.length > 2 && line[0] == SILENT_SCRIPT && MID_BLOCK_KEYWORDS.include?(line[1..-1].split[0])
    end

    # Deals with all the logic of figuring out whether a given line is
    # the beginning, continuation, or end of a multiline sequence.
    #
    # This returns whether or not the line should be
    # rendered normally.
    def handle_multiline(count, line, index)
      suppress_render = false
      # Multilines are denoting by ending with a `|` (124)
      if is_multiline?(line) && @multiline_buffer
        # A multiline string is active, and is being continued
        @multiline_buffer += line[0...-1]
        suppress_render = true
      elsif is_multiline?(line) && (MULTILINE_STARTERS.include? line[0])
        # A multiline string has just been activated, start adding the lines
        @multiline_buffer = line[0...-1]
        @multiline_count = count
        @multiline_index = index
        process_indent(count, line)
        suppress_render = true
      elsif @multiline_buffer
        # A multiline string has just ended, make line into the result
        unless line.empty?
          process_line(@multiline_buffer, @multiline_index, count > @multiline_count)
          @multiline_buffer = nil
        end
      end

      return suppress_render
    end

    # Checks whether or not +line+ is in a multiline sequence.
    def is_multiline?(line)
      line && line.length > 1 && line[-1] == MULTILINE_CHAR_VALUE && line[-2] == ?\s
    end

    # Evaluates <tt>text</tt> in the context of the scope object, but
    # does not output the result.
    def push_silent(text, add_index = false, can_suppress = false)
      flush_merged_text
      
      unless (can_suppress && options[:suppress_eval])
        if add_index
          @precompiled << "#haml_lineno: #{@index}\n#{text}\n"
        else
          # Not really DRY, but probably faster
          @precompiled << "#{text}\n"
        end
      end
    end

    # Adds <tt>text</tt> to <tt>@buffer</tt> with appropriate tabulation
    # without parsing it.
    def push_merged_text(text, tab_change = 0, try_one_liner = false)
      @merged_text ||= ''
      @merged_text << "#{'  ' * @output_tabs}#{text}"
      @tab_change ||= 0
      @tab_change += tab_change
      @try_one_liner = try_one_liner
    end
    
    def push_text(text, tab_change = 0, try_one_liner = false)
      push_merged_text("#{text}\n", tab_change, try_one_liner)
    end
    
    def flush_merged_text
      if @merged_text && !@merged_text.empty?
        args = @merged_text.dump
        args << ", #{@tab_change}" if @tab_change != 0 || @try_one_liner
        @precompiled << "_hamlout.push_text(#{args})\n"
        @merged_text = nil
        @tab_change = 0
        @try_one_liner = false
      end
    end  

    # Renders a block of text as plain text.
    # Also checks for an illegally opened block.
    def push_plain(text)
      if @block_opened
        raise SyntaxError.new("Illegal Nesting: Nesting within plain text is illegal.")
      end
      push_text text
    end

    # Adds +text+ to <tt>@buffer</tt> while flattening text.
    def push_flat(text, spaces)
      tabulation = spaces - @flat_spaces
      tabulation = tabulation > -1 ? tabulation : 0
      @filter_buffer << "#{' ' * tabulation}#{text}\n"
    end

    # Causes <tt>text</tt> to be evaluated in the context of
    # the scope object and the result to be added to <tt>@buffer</tt>.
    #
    # If <tt>flattened</tt> is true, Haml::Helpers#find_and_flatten is run on
    # the result before it is added to <tt>@buffer</tt>
    def push_script(text, flattened, close_tag = nil)
      flush_merged_text
      
      unless options[:suppress_eval]
        push_silent("haml_temp = #{text}", true)
        out = "haml_temp = _hamlout.push_script(haml_temp, #{flattened}, #{close_tag.inspect})\n"
        if @block_opened
          push_and_tabulate([:loud, out])
        else
          @precompiled << out
        end
      end
    end
    
    # Causes <tt>text</tt> to be evaluated, and Haml::Helpers#find_and_flatten
    # to be run on it afterwards.
    def push_flat_script(text)
      flush_merged_text
      
      if text.empty?
        raise SyntaxError.new("Tag has no content.")
      else
        push_script(text, true)
      end
    end

    def start_haml_comment
      if @block_opened
        @haml_comment = true
        push_and_tabulate([:haml_comment])
      end
    end

    # Closes the most recent item in <tt>@to_close_stack</tt>.
    def close
      tag, value = @to_close_stack.pop
      case tag
      when :script
        close_block
      when :comment
        close_comment value
      when :element
        close_tag value
      when :loud
        close_loud value
      when :filtered
        close_filtered value
      when :haml_comment
        close_haml_comment
      end
    end

    # Puts a line in <tt>@precompiled</tt> that will add the closing tag of
    # the most recently opened tag.
    def close_tag(tag)
      @output_tabs -= 1
      @template_tabs -= 1
      push_text("</#{tag}>", -1)
    end

    # Closes a Ruby block.
    def close_block
      push_silent "end", false, true
      @template_tabs -= 1
    end

    # Closes a comment.
    def close_comment(has_conditional)
      @output_tabs -= 1
      @template_tabs -= 1
      close_tag = has_conditional ? "<![endif]-->" : "-->"
      push_text(close_tag, -1)
    end
    
    # Closes a loud Ruby block.
    def close_loud(command)
      push_silent 'end', false, true
      @precompiled << command
      @template_tabs -= 1
    end

    # Closes a filtered block.
    def close_filtered(filter)
      @flat_spaces = -1
      if filter.is_a? String
        if filter == 'redcloth' || filter == 'markdown' || filter == 'textile'
          raise HamlError.new("You must have the RedCloth gem installed to use #{filter}")
        else
          raise HamlError.new("Filter \"#{filter}\" is not defined!")
        end
      else
        filtered = filter.new(@filter_buffer).render

        unless filter == Haml::Filters::Preserve
          push_text(filtered.rstrip.gsub("\n", "\n#{'  ' * @output_tabs}"))
        else
          push_silent("_hamlout.buffer << #{filtered.dump} << \"\\n\"\n")
        end
      end

      @filter_buffer = nil
      @template_tabs -= 1
    end

    def close_haml_comment
      @haml_comment = false
      @template_tabs -= 1
    end
    
    # Iterates through the classes and ids supplied through <tt>.</tt>
    # and <tt>#</tt> syntax, and returns a hash with them as attributes,
    # that can then be merged with another attributes hash.
    def parse_class_and_id(list)
      attributes = {}
      list.scan(/([#.])([-_a-zA-Z0-9]+)/) do |type, property|
        case type
        when '.'
          if attributes['class']
            attributes['class'] += " "
          else
            attributes['class'] = ""
          end
          attributes['class'] += property
        when '#'
          attributes['id'] = property
        end
      end
      attributes
    end

    def parse_literal_value(text)
      text.match(LITERAL_VALUE_REGEX)

      # $2 holds the value matched by a symbol, but is nil for a string match
      # $5 holds the value matched by a string
      $2 || $5
    end
    
    def parse_literal_hash(text)  
      unless text
        return {}
      end
      
      attributes = {}
      if inner = text.scan(/^\{(.*)\}$/)[0]
        inner[0].split(',').each do |attrib|
          key, value, more = attrib.split('=>')

          # Make sure the key and value and only the key and value exist
          # Otherwise, it's too complicated and we'll defer it to the actual Ruby parser
          if more || (key = parse_literal_value(key)).nil? ||
              (value = parse_literal_value(value)).nil?
            return nil
          end

          attributes[key] = value
        end
      end
      attributes
    end

    # This is a class method so it can be accessed from Buffer.
    def self.build_attributes(attr_wrapper, attributes = {})
      quote_escape = attr_wrapper == '"' ? "&quot;" : "&apos;"
      other_quote_char = attr_wrapper == '"' ? "'" : '"'
  
      result = attributes.collect do |a,v|
        unless v.nil? 
          v = v.to_s
          this_attr_wrapper = attr_wrapper
          if v.include? attr_wrapper
            if v.include? other_quote_char
              v = v.gsub(attr_wrapper, quote_escape)
            else
              this_attr_wrapper = other_quote_char
            end
          end
          " #{a}=#{this_attr_wrapper}#{v}#{this_attr_wrapper}"
        end
      end
      result.compact.sort.join
    end

    def prerender_tag(name, atomic, attributes)
      if atomic
        str = " />"
      else
        str = ">"
      end
  
      "<#{name}#{Precompiler.build_attributes(@options[:attr_wrapper], attributes)}#{str}"
    end

    # Parses a line that will render as an XHTML tag, and adds the code that will
    # render that tag to <tt>@precompiled</tt>.
    def render_tag(line)
      matched = false
      line.scan(TAG_REGEX) do |tag_name, attributes, attributes_hash, object_ref, action, value|
        matched = true
        value = value.to_s.strip

        case action
        when '/'
          atomic = true
        when '=', '~'
          parse = true

          if value[0] == ?=
            value = value[1..-1].strip.dump.gsub('\\#', '#')
          end
        end

        flattened = (action == '~')
        
        value_exists = !value.empty?
        if value_exists && parse && @options[:suppress_eval]
          parse = false
          value = ''
        end
        
        literal_attributes = parse_literal_hash(attributes_hash)
        attributes_hash = "{nil}" if attributes_hash.nil? || literal_attributes || @options[:suppress_eval]
        object_ref = "nil" if object_ref.nil? || @options[:suppress_eval]

        if attributes =~ /[\.#](\.|#|\z)/
          raise SyntaxError.new("Illegal element: classes and ids must have values.")
        end
        
        # Preparse the attributes hash
        attributes = parse_class_and_id(attributes)
        Buffer.merge_attrs(attributes, literal_attributes) if literal_attributes

        if @block_opened
          if atomic
            raise SyntaxError.new("Illegal Nesting: Nesting within an atomic tag is illegal.")
          elsif action == '=' || value_exists
            raise SyntaxError.new("Illegal Nesting: Nesting within a tag that already has content is illegal.")
          end
        elsif atomic && value_exists
          raise SyntaxError.new("Atomic tags can't have content.")
        elsif parse && !value_exists
          raise SyntaxError.new("Tag has no content.")
        end

        if !@block_opened && !value_exists && @options[:autoclose].include?(tag_name)
          atomic = true
        end
        
        do_one_liner = value_exists && (parse || Buffer.one_liner?(value))
        
        if object_ref == "nil" && attributes_hash == "{nil}" && !flattened && (do_one_liner || !value_exists)
          # This means that we can render the tag directly to text and not process it in the buffer
          open_tag = prerender_tag(tag_name, atomic, attributes)
          
          tag_closed = do_one_liner && !parse
          if tag_closed
            open_tag += value
            open_tag += "</#{tag_name}>"
          end
          
          open_tag += "\n" unless parse
          push_merged_text(open_tag, tag_closed || atomic ? 0 : 1, parse)
          return if tag_closed
        else
          flush_merged_text
          content = !value_exists || parse ? 'nil' : value.dump
          push_silent "_hamlout.open_tag(#{tag_name.inspect}, #{atomic.inspect}, #{value_exists.inspect}, #{attributes.inspect}, #{object_ref}, #{content}, #{attributes_hash[1...-1]})", true
        end
          
        unless atomic
          unless value_exists
            push_and_tabulate([:element, tag_name])
            @output_tabs += 1
          end

          if value_exists
            if parse
              flush_merged_text
              push_script(value, flattened, tag_name)
            end
          elsif flattened
            raise SyntaxError.new("Tag has no content.")
          end
        end
      end

      unless matched
        raise SyntaxError.new("Invalid tag: \"#{line}\"")
      end
    end

    # Renders a line that creates an XHTML tag and has an implicit div because of
    # <tt>.</tt> or <tt>#</tt>.
    def render_div(line)
      render_tag('%div' + line)
    end

    # Renders an XHTML comment.
    def render_comment(line)
      conditional, content = line.scan(COMMENT_REGEX)[0]
      content.strip!
      conditional << ">" if conditional
      
      if @block_opened && !content.empty?
        raise SyntaxError.new('Illegal Nesting: Nesting within a tag that already has content is illegal.')
      end

      text_out = "<!--#{conditional.to_s} "
      if do_one_liner = !content.empty? && Buffer.one_liner?(content)
        close_tag = conditional ? "<![endif]-->" : "-->"
        push_text("#{text_out}#{content} #{close_tag}")
      else
        push_text(text_out, 1)
        @output_tabs += 1
        push_and_tabulate([:comment, !conditional.nil?])
        if !content.empty?
          push_text(content)
          close
        end
      end
    end
    
    # Renders an XHTML doctype or XML shebang.
    def render_doctype(line)
      if @block_opened
        raise SyntaxError.new("Illegal Nesting: Nesting within a header command is illegal.")
      end
      line = line[3..-1].lstrip.downcase
      if line[0...3] == "xml"
        encoding = line.split[1] || "utf-8"
        wrapper = @options[:attr_wrapper]
        doctype = "<?xml version=#{wrapper}1.0#{wrapper} encoding=#{wrapper}#{encoding}#{wrapper} ?>"
      else
        version, type = line.scan(DOCTYPE_REGEX)[0]
        if version == "1.1"
          doctype = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
        else
          case type
          when "strict"
            doctype = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">'
          when "frameset"
            doctype = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Frameset//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd">'
          else
            doctype = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">'
          end
        end
      end
      push_text doctype
    end

    # Starts a filtered block.
    def start_filtered(filter)
      unless @block_opened
        raise SyntaxError.new('Filters must have nested text.')
      end
      push_and_tabulate([:filtered, filter])
      @flat_spaces = @template_tabs * 2
      @filter_buffer = String.new
    end

    def unescape_interpolation(str)
      first = str.index(/(^|[^\\])\#\{/)

      if first.nil?
        return str.dump
      elsif first != 0
        first += 1
      end

      last = str.rindex '}'

      interpolation = str.slice!(first, last - first)
      str.insert(first, "_haml_interpolation")

      str = str.dump
      str.gsub("_haml_interpolation", interpolation)
    end

    # Counts the tabulation of a line.
    def count_soft_tabs(line)
      spaces = line.index(/[^ ]/)
      if line[spaces] == ?\t
        return nil if line.strip.empty?

        raise SyntaxError.new("Illegal Indentation: Only two space characters are allowed as tabulation.")
      end
      [spaces, spaces/2]
    end
    
    # Pushes value onto <tt>@to_close_stack</tt> and increases
    # <tt>@template_tabs</tt>.
    def push_and_tabulate(value)
      @to_close_stack.push(value)
      @template_tabs += 1
    end
  end
end

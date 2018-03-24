# frozen_string_literal: true

require "ripper"

class Rufo::Formatter
  include Rufo::Settings

  B = Rufo::DocBuilder
  INDENT_SIZE = 2

  attr_reader :squiggly_flag

  def self.format(code, **options)
    formatter = new(code, **options)
    formatter.format
    formatter.result
  end

  def initialize(code, **options)
    @squiggly_flag = false
    @code = code
    @tokens = Ripper.lex(code).reverse!
    @sexp = Ripper.sexp(code)

    unless @sexp
      raise ::Rufo::SyntaxError.new
    end

    @indent = 0
    @line = 0
    @column = 0
    @last_was_newline = true
    @output = "".dup

    # The column of a `obj.method` call, so we can align
    # calls to that dot
    @dot_column = nil

    # Same as above, but the column of the original dot, not
    # the one we finally wrote
    @original_dot_column = nil

    # The column of a `obj.method` call, but only the name part,
    # so we can also align arguments accordingly
    @name_dot_column = nil

    # Heredocs list, associated with calls ([heredoc, tilde])
    @heredocs = []

    # The current heredoc being printed
    @current_heredoc = nil

    # Map lines to commands that start at the begining of a line with the following info:
    # - line indent
    # - first param indent
    # - first line ends with '(', '[' or '{'?
    # - line of matching pair of the previous item
    # - last line of that call
    #
    # This is needed to dedent some calls that look like this:
    #
    # foo bar(
    #   2,
    # )
    #
    # Without the dedent it would normally look like this:
    #
    # foo bar(
    #       2,
    #     )
    #
    # Because the formatter aligns this to the first parameter in the call.
    # However, for these cases it's better to not align it like that.
    @line_to_call_info = {}

    # Lists [first_line, last_line, indent] of lines that need an indent because
    # of alignment of literals. For example this:#
    #
    #     foo [
    #           1,
    #         ]
    #
    # is normally formatted to:
    #
    #     foo [
    #       1,
    #     ]
    #
    # However, if it's already formatted like the above we preserve it.
    @literal_indents = []

    # First non-space token in this line
    @first_token_in_line = nil

    # Do we want to compute the above?
    @want_first_token_in_line = false

    # Each line that belongs to a string literal besides the first
    # go here, so we don't break them when indenting/dedenting stuff
    @unmodifiable_string_lines = {}

    # Position of comments that occur at the end of a line
    @comments_positions = []

    # Token for the last comment found
    @last_comment = nil

    # Actual column of the last comment written
    @last_comment_column = nil

    # Associate lines to alignments
    # Associate a line to an index inside @comments_position
    # becuase when aligning something to the left of a comment
    # we need to adjust the relative comment
    @line_to_alignments_positions = Hash.new { |h, k| h[k] = [] }

    # Range of assignment (line => end_line)
    #
    # We need this because when we have to format:
    #
    # ```
    # abc = 1
    # a = foo bar: 2
    #         baz: #
    # ```
    #
    # Because we'll insert two spaces after `a`, this will
    # result in a mis-alignment for baz (and possibly other lines
    # below it). So, we remember the line ranges of an assignment,
    # and once we align the first one we fix the other ones.
    @assignments_ranges = {}

    # Case when positions
    @case_when_positions = []

    # Declarations that are written in a single line, like:
    #
    #    def foo; 1; end
    #
    # We want to track these because we allow consecutive inline defs
    # to be together (without an empty line between them)
    #
    # This is [[line, original_line], ...]
    @inline_declarations = []

    # This is used to track how far deep we are in the AST.
    # This is useful as it allows you to check if you are inside an array
    # when dealing with heredocs.
    @node_level = 0

    # This represents the node level of the most recent literal elements list.
    # It is used to track if we are in a list of elements so that commas
    # can be added appropriately for heredocs for example.
    @literal_elements_level = nil

    # A stack to keeping track of if a inner group has needs to break.
    # Example:
    # [
    #   [
    #     <<-HEREDOC
    #     HEREDOC
    #   ]
    # ]
    # The inner array needs to break so the outer array must also break.
    @inner_group_breaks = []

    init_settings(options)
  end

  def format
    result = visit @sexp
    result = B.concat([result, consume_end])
    the_output = Rufo::DocPrinter.print_doc_to_string(
      result, {print_width: print_width - @indent}
    )[:formatted]
    @output << the_output

    write_line if !@last_was_newline || @output == ""
    @output.chomp! if @output.end_with?("\n\n")

    dedent_calls
    indent_literals
    do_align_case_when if align_case_when
    remove_lines_before_inline_declarations
  end

  def visit(node)
    puts node.inspect
    @node_level += 1
    unless node.is_a?(Array)
      bug "unexpected node: #{node} at #{current_token}"
    end
    result = visit_doc(node)
    return result
  ensure
    @node_level -= 1
  end

  # [:retry]
  # [:redo]
  # [:zsuper]
  KEYWORDS = {
    retry: "retry",
    redo: "redo",
    zsuper: "super",
    return0: "return",
    yield0: "yield",
  }

  # [:return, exp]
  # [:break, exp]
  # [:next, exp]
  # [:yield, exp]
  CONTROL_KEYWORDS = [
    :return,
    :break,
    :next,
    :yield,
  ]

  # [:@gvar, "$abc", [1, 0]]
  # [:@backref, "$1", [1, 0]]
  # [:@op, "*", [1, 1]]
  # [:@label, "foo:", [1, 3]]
  SIMPLE_NODE = [
    :@gvar,
    :@backref,
    :@op,
    :@label,
  ]

  def visit_doc(node)
    type = node.first
    if KEYWORDS.has_key?(type)
      return skip_keyword(KEYWORDS[type])
    end

    if SIMPLE_NODE.include?(type)
      next_token
      return node[1]
    end

    if CONTROL_KEYWORDS.include?(type)
      return visit_control_keyword node, type.to_s
    end

    case type
    when :program
      # Topmost node
      #
      # [:program, exps]
      return visit_exps_doc node[1]
    when :array
      doc = visit_array(node)
      return if doc.nil?

      return B.align(@indent, doc)
    when :args_add_star
      return visit_args_add_star_doc(node)
    when :hash
      return visit_hash(node)
    when :assoc_new
      return visit_hash_key_value(node)
    when :alias, :var_alias
      return visit_alias(node)
    when :sclass
      return visit_sclass(node)
    when :const_path_ref, :const_path_field
      return visit_path(node)
    when :top_const_ref, :top_const_field
      # [:top_const_ref, [:@const, "Foo", [1, 2]]]
      next_token # "::"
      return B.concat(["::", visit(node[1])])
    when :symbol_literal
      return visit_symbol_literal(node)
    when :symbol
      return visit_symbol(node)
    when :ifop
      return visit_ternary_if(node)
    when :bodystmt
      return visit_bodystmt_doc(node)
    when :class
      return visit_class(node)
    when :begin
      return visit_begin(node)
    when :mrhs_new_from_args
      return visit_mrhs_new_from_args(node)
    when :brace_block
      return visit_brace_block(node)
    when :BEGIN
      return visit_BEGIN(node)
    when :END
      return visit_END(node)
    when :for
      return visit_for(node)
    when :mlhs_add_star
      return visit_mlhs_add_star(node)
    # when :rest_param
    #   visit_rest_param(node)
    # when :kwrest_param
    #   return visit_kwrest_param(node)
    when :undef
      return visit_undef(node)
    when :defined
      return visit_defined(node)
    when :super
      return visit_super(node)
    when :lambda
      return visit_lambda(node)
    when :field
      return visit_setter(node)
    when :aref_field
      return visit_array_setter(node)
    when :aref
      return visit_array_access(node)
    when :args_add_block
      return visit_call_args(node)
    when :method_add_arg
      return visit_call_without_receiver(node)
    when :regexp_literal
      return visit_regexp_literal(node)
    when :dot2
      return visit_range(node, true)
    when :dot3
      return visit_range(node, false)
    when :assoc_splat
      return visit_splat_inside_hash(node)
    when :params
      return visit_params(node)
    when :paren
      return visit_paren(node)
    when :def
      return visit_def(node)
    when :defs
      return visit_def_with_receiver(node)
    when :mrhs_add_star
      return visit_mrhs_add_star(node)
    when :mlhs
      return visit_mlhs(node)
    when :mlhs_paren
      return visit_mlhs_paren(node)
    when :block_var
      return visit_block_arguments(node)
    when :module
      return visit_module(node)
    when :binary
      return visit_binary(node)
    when :unary
      return visit_unary(node)
    when :case
      return visit_case(node)
    when :when
      return visit_when(node)
    when :until
      return visit_until(node)
    when :while # Can we combine with the above?
      return visit_while(node)
    when :unless
      return visit_unless(node)
    when :if
      return visit_if(node)
    when :do_block
      return visit_do_block(node)
    when :call
      return visit_call_with_receiver(node)
    when :method_add_block
      return visit_call_with_block(node)
    when :bare_assoc_hash
      # [:bare_assoc_hash, exps]
      return visit_comma_separated_list_doc(node[1])
    when :command_call
      return visit_command_call(node)
    when :command
      return visit_command(node)
    when :if_mod
      return visit_suffix(node, "if")
    when :unless_mod
      return visit_suffix(node, "unless")
    when :while_mod
      return visit_suffix(node, "while")
    when :until_mod
      return visit_suffix(node, "until")
    when :rescue_mod
      return visit_suffix(node, "rescue")
    when :assign
      return visit_assign(node)
    when :opassign
      return visit_op_assign(node)
    when :massign
      return visit_multiple_assign(node)
    when :const_ref
      # [:const_ref, [:@const, "Foo", [1, 8]]]
      return visit node[1]
    when :vcall
      # [:vcall, exp]
      return visit node[1]
    when :fcall
      # [:fcall, [:@ident, "foo", [1, 0]]]
      return visit node[1]
    when :@kw
      # [:@kw, "nil", [1, 0]]
      return skip_token :on_kw
    when :@ivar
      # [:@ivar, "@foo", [1, 0]]
      return skip_token :on_ivar
    when :@cvar
      # [:@cvar, "@@foo", [1, 0]]
      return skip_token :on_cvar
    when :@const
      # [:@const, "FOO", [1, 0]]
      return skip_token :on_const
    when :@ident
      return skip_token :on_ident
    when :var_ref, :var_field
      # [:var_ref, exp]
      return visit node[1]
    when :dyna_symbol
      return visit_quoted_symbol_literal(node)
    when :@int
      # Integer literal
      #
      # [:@int, "123", [1, 0]]
      return skip_token :on_int
    when :@float
      # Float literal
      #
      # [:@int, "123.45", [1, 0]]
      return skip_token :on_float
    when :@rational
      # Rational literal
      #
      # [:@rational, "123r", [1, 0]]
      return skip_token :on_rational
    when :@imaginary
      # Imaginary literal
      #
      # [:@imaginary, "123i", [1, 0]]
      return skip_token :on_imaginary
    when :@CHAR
      # [:@CHAR, "?a", [1, 0]]
      return skip_token :on_CHAR
    when :@backtick
      # [:@backtick, "`", [1, 4]]
      return skip_token :on_backtick
    when :string_dvar
      return visit_string_dvar(node)
    when :string_embexpr
      # String interpolation piece ( #{exp} )
      return visit_string_interpolation node
    when :string_content
      # [:string_content, exp]
      return visit_exps_doc node[1..-1], with_lines: false
    when :string_concat
      return visit_string_concat node
    when :@tstring_content
      return visit_string_content(node)
    when :string_literal, :xstring_literal
      return visit_string_literal node
    else
      bug "Unhandled node: #{node}"
    end
  end

  def visit_string_content(node)
    # [:@tstring_content, "hello ", [1, 1]]
    doc = []
    heredoc, tilde = @current_heredoc
    if heredoc && tilde && broken_ripper_version?
      @squiggly_flag = true
    end
    # For heredocs with tilde we sometimes need to align the contents
    if heredoc && tilde && @last_was_newline
      unless (current_token_value == "\n" ||
              current_token_kind == :on_heredoc_end)
      end
      skip_ignored_space
      if current_token_kind == :on_tstring_content
        doc << skip_token(:on_tstring_content)
      end
    else
      while (current_token_kind == :on_ignored_sp) ||
            (current_token_kind == :on_tstring_content) ||
            (current_token_kind == :on_embexpr_beg)
        check current_token_kind
        break if current_token_kind == :on_embexpr_beg
        doc << skip_token(current_token_kind)
      end
    end
    B.concat(doc)
  end

  def visit_exps(exps, with_indent: false, with_lines: true, want_trailing_multiline: false)
    consume_end_of_line(at_prefix: true)

    line_before_endline = nil

    exps.each_with_index do |exp, i|
      exp_kind = exp[0]

      # Skip voids to avoid extra indentation
      if exp_kind == :void_stmt
        next
      end

      if with_indent
        # Don't indent if this exp is in the same line as the previous
        # one (this happens when there's a semicolon between the exps)
        unless line_before_endline && line_before_endline == @line
          write_indent
        end
      end

      line_before_exp = @line
      original_line = current_token_line

      visit exp

      if declaration?(exp) && @line == line_before_exp
        @inline_declarations << [@line, original_line]
      end

      is_last = last?(i, exps)

      line_before_endline = @line

      if with_lines
        exp_needs_two_lines = needs_two_lines?(exp)

        consume_end_of_line(want_semicolon: !is_last, want_multiline: !is_last || want_trailing_multiline, needs_two_lines_on_comment: exp_needs_two_lines)

        # Make sure to put two lines before defs, class and others
        if !is_last && (exp_needs_two_lines || needs_two_lines?(exps[i + 1])) && @line <= line_before_endline + 1
          write_line
        end
      elsif !is_last
        skip_space

        has_semicolon = semicolon?
        skip_semicolons
        if newline?
          write_line
          write_indent(next_indent)
        elsif has_semicolon
          write "; "
        end
        skip_space_or_newline
      end
    end
  end

  def handle_space_or_newline_doc(doc, with_lines: true, newline_limit: Float::INFINITY)
    comments, newline_before_comment, _, num_newlines = skip_space_or_newline_doc(newline_limit)
    comments_added = add_comments_on_line(doc, comments, newline_before_comment: newline_before_comment)
    return comments_added unless with_lines
    doc << B::LINE_SUFFIX_BOUNDARY if num_newlines == 0
    if num_newlines == 1
      doc << B::LINE
    elsif num_newlines > 1
      doc << B::DOUBLE_SOFT_LINE
    end
    comments_added
  end

  # def visit_exps_doc(exps, with_indent: false, with_lines: true, want_trailing_multiline: false)
  def visit_exps_doc(exps, with_lines: true)
    doc = []
    handle_space_or_newline_doc(doc, with_lines: with_lines)

    exps.each_with_index do |exp, i|
      exp_kind = exp[0]

      # Skip voids to avoid extra indentation
      if exp_kind == :void_stmt
        next
      end

      # if with_indent
      #   # Don't indent if this exp is in the same line as the previous
      #   # one (this happens when there's a semicolon between the exps)
      #   unless line_before_endline && line_before_endline == @line
      #     write_indent
      #   end
      # end

      # line_before_exp = @line
      # original_line = current_token_line

      handle_space_or_newline_doc(doc, with_lines: with_lines)

      doc << visit(exp)
      handle_space_or_newline_doc(doc, with_lines: with_lines)

      next unless with_lines

      if needs_two_lines?(exp)
        doc << B::DOUBLE_SOFT_LINE
      else
        doc << B::LINE
      end


      # if declaration?(exp) && @line == line_before_exp
      #   @inline_declarations << [@line, original_line]
      # end

      # is_last =

      # line_before_endline = @line

      # if with_lines
      #   exp_needs_two_lines = needs_two_lines?(exp)

      #   consume_end_of_line(want_semicolon: !is_last, want_multiline: !is_last || want_trailing_multiline, needs_two_lines_on_comment: exp_needs_two_lines)

      #   # Make sure to put two lines before defs, class and others
      #   if !is_last && (exp_needs_two_lines || needs_two_lines?(exps[i + 1])) && @line <= line_before_endline + 1
      #     write_line
      #   end
      # elsif !is_last
      #   skip_space

      #   has_semicolon = semicolon?
      #   skip_semicolons
      #   if newline?
      #     write_line
      #     write_indent(next_indent)
      #   elsif has_semicolon
      #     write "; "
      #   end
      #   skip_space_or_newline
      # end
    end
    handle_space_or_newline_doc(doc, with_lines: with_lines)
    B.concat(doc)
  end

  def needs_two_lines?(exp)
    kind = exp[0]
    case kind
    when :def, :class, :module
      return true
    when :vcall
      # Check if it's private/protected/public
      nested = exp[1]
      if nested[0] == :@ident
        case nested[1]
        when "private", "protected", "public"
          return true
        end
      end
    end

    false
  end

  def declaration?(exp)
    case exp[0]
    when :def, :class, :module
      true
    else
      false
    end
  end

  def visit_string_literal(node, bail_on_heredoc: false)
    # [:string_literal, [:string_content, exps]]
    heredoc = current_token_kind == :on_heredoc_beg
    tilde = current_token_value.include?("~")

    doc = []

    if heredoc
      doc << current_token_value.rstrip
      # Accumulate heredoc: we'll write it once
      # we find a newline.
      @heredocs << [node, tilde]
      # Get the next_token while capturing any output.
      # This is needed so that we can add a comma if one is not already present.
      if bail_on_heredoc
        next_token_no_heredoc_check
        return
      end
      captured_output = capture_output { next_token }

      inside_literal_elements_list = !@literal_elements_level.nil? &&
                                     [2, 3].include?(@node_level - @literal_elements_level)
      needs_comma = !comma? && trailing_commas

      if inside_literal_elements_list && needs_comma
        doc << ','
        @last_was_heredoc = true
      end

      doc << captured_output
      return B.concat(doc)
    elsif current_token_kind == :on_backtick
      doc << skip_token(:on_backtick)
    else
      doc << skip_token(:on_tstring_beg)
    end

    doc << visit_string_literal_end(node)
    B.concat(doc)
  end

  def visit_string_literal_end(node)
    line = @line
    doc = []
    inner = node[1]
    inner = inner[1..-1] unless node[0] == :xstring_literal
    doc << visit_exps_doc(inner, with_lines: false)

    # Every line between the first line and end line of this
    # string (excluding the first line) must remain like it is
    # now (we don't want to mess with that when indenting/dedenting)
    #
    # This can happen with heredocs, but also with string literals
    # spanning multiple lines.
    (line + 1..@line).each do |i|
      @unmodifiable_string_lines[i] = true
    end

    case current_token_kind
    when :on_heredoc_end
      heredoc, tilde = @current_heredoc
      if heredoc && tilde
        # write_indent
        doc << current_token_value.strip
      else
        doc << current_token_value.rstrip
      end
      next_token
      skip_space

      # Simulate a newline after the heredoc
      @tokens << [[0, 0], :on_ignored_nl, "\n"]
    when :on_backtick
      doc << skip_token(:on_backtick)
    else
      doc << skip_token(:on_tstring_end)
    end
    B.concat(doc)
  end

  def visit_string_concat(node)
    # string1 string2
    # [:string_concat, string1, string2]
    _, string1, string2 = node

    doc = [visit(string1)]


    has_backslash, first_space = skip_space_backslash
    if has_backslash
      doc << " \\"
      doc << B::SOFT_LINE
    else
      skip_space
      doc << " "
    end

    doc << visit(string2)
    B.group(B.concat([B.indent(B.concat(doc))]), should_break: true)
  end

  def visit_string_interpolation(node)
    # [:string_embexpr, exps]
    doc = [skip_token(:on_embexpr_beg)]
    handle_space_or_newline_doc(doc)
    if current_token_kind == :on_tstring_content
      next_token
    end
    doc << visit_exps_doc(node[1], with_lines: false)
    handle_space_or_newline_doc(doc)
    doc << skip_token(:on_embexpr_end)
    B.concat(doc)
  end

  def visit_string_dvar(node)
    # [:string_dvar, [:var_ref, [:@ivar, "@foo", [1, 2]]]]
    doc = [skip_token(:on_embvar), visit(node[1])]
    B.concat(doc)
  end

  def visit_symbol_literal(node)
    # :foo
    #
    # [:symbol_literal, [:symbol, [:@ident, "foo", [1, 1]]]]
    #
    # A symbol literal not necessarily begins with `:`.
    # For example, an `alias foo bar` will treat `foo`
    # a as symbol_literal but without a `:symbol` child.
    visit node[1]
  end

  def visit_symbol(node)
    # :foo
    #
    # [:symbol, [:@ident, "foo", [1, 1]]]

    B.concat([skip_token(:on_symbeg), visit_exps_doc(node[1..-1], with_lines: false)])
  end

  def visit_quoted_symbol_literal(node)
    # :"foo"
    #
    # [:dyna_symbol, exps]
    _, exps = node

    # This is `"...":` as a hash key
    if current_token_kind == :on_tstring_beg

      doc = [skip_token(:on_tstring_beg), visit(exps), skip_token(:on_label_end)]
    else
      doc = [skip_token(:on_symbeg), visit_exps_doc( exps, with_lines: false), skip_token(:on_tstring_end)]
    end
    B.concat(doc)
  end

  def visit_path(node)
    # Foo::Bar
    #
    # [:const_path_ref,
    #   [:var_ref, [:@const, "Foo", [1, 0]]],
    #   [:@const, "Bar", [1, 5]]]
    pieces = node[1..-1]
    doc = []
    pieces.each_with_index do |piece, i|
      doc << visit(piece)
      unless last?(i, pieces)
        next_token # "::"
        skip_space_or_newline
      end
    end
    B.join('::', doc)
  end

  def visit_assign(node)
    # target = value
    #
    # [:assign, target, value]
    _, target, value = node

    doc = [visit(target), " ="]
    skip_space

    skip_op("=")
    should_break = handle_space_or_newline_doc(doc, with_lines: false)
    doc << visit_assign_value(value)

    B.group(B.concat(doc), should_break: should_break)
  end

  def visit_op_assign(node)
    # target += value
    #
    # [:opassign, target, op, value]
    _, target, op, value = node

    before = op[1][0...-1]
    after = op[1][-1]

    doc = [visit(target), " ", before, after]

    skip_space

    # [:@op, "+=", [1, 2]],
    check :on_op

    next_token
    should_break = handle_space_or_newline_doc(doc, with_lines: false)
    doc << visit_assign_value(value)

    B.group(B.concat(doc), should_break: should_break)
  end

  def visit_multiple_assign(node)
    # [:massign, lefts, right]
    _, lefts, right = node

    doc = [visit_comma_separated_list_doc(lefts), " ="]
    skip_space

    # A trailing comma can come after the left hand side
    if comma?
      skip_token :on_comma
      skip_space
    end

    skip_op "="
    should_break = handle_space_or_newline_doc(doc, with_lines: false)
    doc << visit_assign_value(right)
    B.group(B.concat(doc), should_break: should_break)
  end

  def visit_assign_value(value)
    skip_space_backslash
    B.indent(B.concat([B::LINE, visit(value)]))
  end

  def indentable_value?(value)
    return unless current_token_kind == :on_kw

    case current_token_value
    when "if", "unless", "case"
      true
    when "begin"
      # Only indent if it's begin/rescue
      return false unless value[0] == :begin

      body = value[1]
      return false unless body[0] == :bodystmt

      _, body, rescue_body, else_body, ensure_body = body
      rescue_body || else_body || ensure_body
    else
      false
    end
  end

  def current_comment_aligned_to_previous_one?
    @last_comment &&
      @last_comment[0][0] + 1 == current_token_line &&
      @last_comment[0][1] == current_token_column
  end

  def track_comment(id: nil, match_previous_id: false)
    if match_previous_id && !@comments_positions.empty?
      id = @comments_positions.last[3]
    end

    @line_to_alignments_positions[@line] << [:comment, @column, @comments_positions, @comments_positions.size]
    @comments_positions << [@line, @column, 0, id, 0]
  end

  def track_case_when
    track_alignment :case_whem, @case_when_positions
  end

  def track_alignment(key, target, offset = 0, id = nil)
    last = target.last
    if last && last[0] == @line
      # Track only the first alignment in a line
      return
    end

    @line_to_alignments_positions[@line] << [key, @column, target, target.size]
    info = [@line, @column, @indent, id, offset]
    target << info
    info
  end

  def visit_ternary_if(node)
    # cond ? then : else
    #
    # [:ifop, cond, then_body, else_body]
    _, cond, then_body, else_body = node
    doc = [
      visit(cond),
      " ",
      "?",
    ]

    skip_space
    skip_op "?"
    skip_space_or_newline
    doc_if_true = [
      B::LINE,
      visit(then_body),
      " ",
      ":",
    ]
    skip_space
    skip_op ":"
    skip_space_or_newline
    doc_if_true << B.concat([B::LINE, visit(else_body)])
    doc << B.indent(B.concat(doc_if_true))
    B.group(B.concat(doc))
  end

  def visit_suffix(node, suffix)
    # then if cond
    # then unless cond
    # exp rescue handler
    #
    # [:if_mod, cond, body]
    _, body, cond = node

    if suffix != "rescue"
      body, cond = cond, body
    end

    doc = [visit(body), ' ', suffix, " "]
    skip_space
    skip_keyword(suffix)
    handle_space_or_newline_doc(doc)
    doc << visit(cond)
    B.concat(doc)
  end

  def visit_call_with_receiver(node)
    # [:call, obj, :".", name]
    _, obj, text, name = node

    doc = [visit(obj)]

    skip_space
    should_break = handle_space_or_newline_doc(doc, with_lines: false)
    call_doc = [B::SOFT_LINE, skip_call_dot]

    should_break ||= handle_space_or_newline_doc(call_doc, with_lines: false)

    if name == :call
      # :call means it's .()
    else
      call_doc << visit(name)
    end
    doc << B.indent(B.concat(call_doc))
    doc << B::SOFT_LINE

    B.group(B.concat(doc), should_break: should_break)
  end

  def consume_call_dot
    if current_token_kind == :on_op
      consume_token :on_op
    else
      consume_token :on_period
    end
  end

  def skip_call_dot
    if current_token_kind == :on_op
      skip_token :on_op
    else
      skip_token :on_period
    end
  end

  def visit_call_without_receiver(node)
    # foo(arg1, ..., argN)
    #
    # [:method_add_arg,
    #   [:fcall, [:@ident, "foo", [1, 0]]],
    #   [:arg_paren, [:args_add_block, [[:@int, "1", [1, 6]]], false]]]
    _, name, args = node

    @name_dot_column = nil
    doc = [visit(name)]

    # Some times a call comes without parens (should probably come as command, but well...)
    return B.concat(doc) if args.empty?

    # Remember dot column so it's not affected by args
    # dot_column = @dot_column
    # original_dot_column = @original_dot_column

    # want_indent = @name_dot_column && @name_dot_column > @indent

    # maybe_indent(want_indent, @name_dot_column) do
      doc << visit_call_at_paren(node, args)
    # end
    B.concat(doc)

    # Restore dot column so it's not affected by args
    # @dot_column = dot_column
    # @original_dot_column = original_dot_column
  end

  def visit_call_at_paren(node, args)
    skip_token :on_lparen
    doc = ["("]

    # If there's a trailing comma then comes [:arg_paren, args],
    # which is a bit unexpected, so we fix it
    if args[1].is_a?(Array) && args[1][0].is_a?(Array)
      args_node = [:args_add_block, args[1], false]
    else
      args_node = args[1]
    end

    # if args_node
      skip_space

      # needs_trailing_newline = newline? || comment?
      # if needs_trailing_newline && (call_info = @line_to_call_info[@line])
      #   call_info << true
      # end

      # want_trailing_comma = true

      # Check if there's a block arg and if the call ends with hash key/values
      # if args_node[0] == :args_add_block
      #   _, args, block_arg = args_node
      #   want_trailing_comma = !block_arg
      #   if args.is_a?(Array) && (last_arg = args.last) && last_arg.is_a?(Array) &&
      #      last_arg[0].is_a?(Symbol) && last_arg[0] != :bare_assoc_hash
      #     want_trailing_comma = false
      #   end
      # end
      if args_node
        doc << visit_doc(args_node)
        skip_space
      end

      # found_comma = comma?

      # if found_comma
      #   if needs_trailing_newline
      #     write "," if trailing_commas && !block_arg

      #     next_token
      #     indent(next_indent) do
      #       consume_end_of_line
      #     end
      #     write_indent
      #   else
      #     next_token
      #     skip_space
      #   end
      # end

    #   if newline? || comment?
    #     if needs_trailing_newline
    #       write "," if trailing_commas && want_trailing_comma

    #       indent(next_indent) do
    #         consume_end_of_line
    #       end
    #       write_indent
    #     else
    #       skip_space_or_newline
    #     end
    #   else
    #     if needs_trailing_newline && !found_comma
    #       write "," if trailing_commas && want_trailing_comma
    #       consume_end_of_line
    #       write_indent
    #     end
    #   end
    # else
    #   skip_space_or_newline
    # end

    # If the closing parentheses matches the indent of the first parameter,
    # keep it like that. Otherwise dedent.
    # if call_info && call_info[1] != current_token_column
    #   call_info << @line
    # end

    # if @last_was_heredoc
    #   write_line
    # end
    skip_comma_and_spaces if comma?
    handle_space_or_newline_doc(doc)
    skip_token :on_rparen
    doc << ")"
    puts doc.inspect
    B.concat(doc)
  end

  def visit_command(node)
    # foo arg1, ..., argN
    #
    # [:command, name, args]
    _, name, args = node

    doc = [visit(name), " "]

    doc << visit_command_args_doc(args)
    B.concat(doc)
  end

  def flush_heredocs
    if comment?
      write_space unless @output[-1] == " "
      write current_token_value.rstrip
      next_token
      write_line
      if @heredocs.last[1]
        write_indent(next_indent)
      end
    end

    printed = false

    until @heredocs.empty?
      heredoc, tilde = @heredocs.first

      @heredocs.shift
      @current_heredoc = [heredoc, tilde]
      visit_string_literal_end(heredoc)
      @current_heredoc = nil
      printed = true
    end

    @last_was_heredoc = true if printed
  end

  def flush_heredocs_doc
    doc = []
    comment = nil
    if comment?
      comment = current_token_value.rstrip
      next_token
    end

    until @heredocs.empty?
      heredoc, tilde = @heredocs.first

      @heredocs.shift
      @current_heredoc = [heredoc, tilde]
      doc << visit_string_literal_end(heredoc)
      @current_heredoc = nil
      printed = true
    end

    @last_was_heredoc = true if printed
    [doc, comment]
  end

  def visit_command_call(node)
    # [:command_call,
    #   receiver
    #   :".",
    #   name
    #   [:args_add_block, [[:@int, "1", [1, 8]]], block]]
    _, receiver, dot, name, args = node

    doc = [visit(receiver)]
    handle_space_or_newline_doc(doc)

    call_doc = [skip_call_dot]

    skip_space

    handle_space_or_newline_doc(call_doc)

    call_doc << visit(name)
    call_doc << " "

    call_doc << visit_command_args_doc(args)
    doc << B.concat(call_doc)

    B.concat(doc)
  end

  def consume_space_after_command_name
    has_backslash, first_space = skip_space_backslash
    if has_backslash
      write " \\"
      write_line
      write_indent(next_indent)
    else
      write_space_using_setting(first_space, :one)
    end
  end

  def visit_command_args_doc(args)
    visit_exps_doc to_ary(args), with_lines: false
  end

  def visit_command_args(args, base_column)
    needed_indent = @column
    args_is_def_class_or_module = false
    param_column = current_token_column

    # Check if there's a single argument and it's
    # a def, class or module. In that case we don't
    # want to align the content to the position of
    # that keyword.
    if args[0] == :args_add_block
      nested_args = args[1]
      if nested_args.is_a?(Array) && nested_args.size == 1
        first = nested_args[0]
        if first.is_a?(Array)
          case first[0]
          when :def, :class, :module
            needed_indent = @indent
            args_is_def_class_or_module = true
          end
        end
      end
    end

    base_line = @line
    call_info = @line_to_call_info[@line]
    if call_info
      call_info = nil
    else
      call_info = [@indent, @column]
      @line_to_call_info[@line] = call_info
    end

    old_want_first_token_in_line = @want_first_token_in_line
    @want_first_token_in_line = true

    # We align call parameters to the first paramter
    indent(needed_indent) do
      visit_exps to_ary(args), with_lines: false
    end

    if call_info && call_info.size > 2
      # A call like:
      #
      #     foo, 1, [
      #       2,
      #     ]
      #
      # would normally be aligned like this (with the first parameter):
      #
      #     foo, 1, [
      #            2,
      #          ]
      #
      # However, the first style is valid too and we preserve it if it's
      # already formatted like that.
      call_info << @line
    elsif !args_is_def_class_or_module && @first_token_in_line && param_column == @first_token_in_line[0][1]
      # If the last line of the call is aligned with the first parameter, leave it like that:
      #
      #     foo 1,
      #         2
    elsif !args_is_def_class_or_module && @first_token_in_line && base_column + INDENT_SIZE == @first_token_in_line[0][1]
      # Otherwise, align it just by two spaces (so we need to dedent, we fake a dedent here)
      #
      #     foo 1,
      #       2
      @line_to_call_info[base_line] = [0, needed_indent - next_indent, true, @line, @line]
    end

    @want_first_token_in_line = old_want_first_token_in_line
  end

  def visit_call_with_block(node)
    # [:method_add_block, call, block]
    _, call, block = node
    doc = [visit(call), " "]

    skip_space

    doc << visit(block)

    B.concat(doc)
  end

  def visit_brace_block(node)
    # [:brace_block, args, body]
    _, args, body = node
    doc = []
    # This is for the empty `{ }` block
    if void_exps?(body)
      doc << "{"
      skip_token :on_lbrace
      doc << " "
      if args && !args.empty?
        doc << consume_block_args_doc(args)
        doc << " "
      end
      skip_space
      skip_token :on_rbrace
      doc << "}"
      return B.concat(doc)
    end

    # closing_brace_token, index = find_closing_brace_token

    # # If the whole block fits into a single line, use braces
    # if current_token_line == closing_brace_token[0][0]
    #   consume_token :on_lbrace
    #   consume_block_args args
    #   consume_space
    #   visit_exps body, with_lines: false

    #   while semicolon?
    #     next_token
    #   end

    #   consume_space

    #   consume_token :on_rbrace
    #   return
    # end

    # Otherwise it's multiline
    skip_token :on_lbrace
    doc << B.if_break("do", "{")
    doc << consume_block_args_doc(args)

    if call_info = @line_to_call_info[@line]
      call_info << true
    end

    doc << B.indent(B.concat([B::LINE, indent_body_doc(body, force_multiline: true), B::LINE]))
    # write_indent

    # If the closing bracket matches the indent of the first parameter,
    # keep it like that. Otherwise dedent.
    # if call_info && call_info[1] != current_token_column
    #   call_info << @line
    # end

    skip_token :on_rbrace
    # doc << B::LINE
    doc << B.if_break("end", "}")
    B.group(B.concat(doc), should_break: body.length > 1 )
  end

  def visit_do_block(node)
    # [:brace_block, args, body]
    _, args, body = node
    doc = ["do"]
    # line = @line

    skip_keyword "do"

    doc << consume_block_args_doc(args)
    handle_space_or_newline_doc(doc)

    if body.first == :bodystmt
      doc << visit_bodystmt(body)
    else
      doc << B.indent(B.concat([B::LINE, indent_body_doc(body)]))
      doc << B::LINE
      doc << "end"
      skip_keyword "end"
    end
    B.concat(doc)
  end

  def consume_block_args(args)
    if args
      consume_space_or_newline
      # + 1 because of |...|
      #                ^
      indent(@column + 1) do
        visit args
      end
    end
  end

  def consume_block_args_doc(args)
    if args
      skip_space_or_newline
      # + 1 because of |...|
      #                ^
      return visit(args)
    end
    return B.concat([])
  end

  def visit_block_arguments(node)
    # [:block_var, params, local_params]
    _, params, local_params = node

    empty_params = empty_params?(params)

    check :on_op

    # check for ||
    if empty_params && !local_params
      # Don't write || as it's meaningless
      if current_token_value == "|"
        next_token
        skip_space_or_newline
        check :on_op
        next_token
      else
        next_token
      end
      return B.concat([])
    end

    doc = ["|"]
    skip_token :on_op
    skip_space_or_newline_doc

    # if found_semicolon
    #   # skip_token :on_semicolon
    #   # skip_space
    #   doc << "; "
    #   # Nothing
    # elsif empty_params && local_params
    #   # skip_token :on_semicolon
    #   # found_semicolon = true
    # end

    # skip_space_or_newline

    unless empty_params
      doc << visit(params)
      skip_space
    end

    if local_params
      if semicolon?
        skip_token :on_semicolon
        skip_space
      end
      doc << "; "

      doc << visit_comma_separated_list_doc(local_params)
    else
      skip_space_or_newline
    end

    skip_op "|"
    doc << "|"
    B.concat(doc)
  end

  def visit_call_args(node)
    # [:args_add_block, args, block]
    _, args, block_arg = node
    pre_comments_doc = []
    args_doc = []
    should_break = handle_space_or_newline_doc(pre_comments_doc, with_lines: false)

    if !args.empty?
      if args[0] == :args_add_star
        # arg1, ..., *star
        doc = visit(args)
        args_doc << doc
      else
        should_break, doc = visit_comma_separated_list_doc_no_group(args)
        args_doc = args_doc.concat(doc)
      end
    end

    if block_arg
      skip_space_or_newline
      if comma?
        skip_comma_and_spaces
      end
      skip_space_or_newline
      skip_op "&"
      skip_space_or_newline
      args_doc << B.concat(['&', visit(block_arg)])
    end
    B.group(
      B.concat([
        B.indent(
          B.concat([
            B::SOFT_LINE,
            B.join(B.concat([",", B::LINE]), args_doc)
          ])
        ),
        B::SOFT_LINE
      ]),
      should_break: should_break
    )
  end

  def skip_comma_and_spaces
    skip_space
    check :on_comma
    next_token
    skip_space
  end

  def visit_args_add_star_doc(node)
    # [:args_add_star, args, star, post_args]
    _, args, star, *post_args = node
    doc = []
    if !args.empty? && args[0] == :args_add_star
      # arg1, ..., *star
      doc << visit(args)
    else
      pre_doc = visit_literal_elements_simple_doc(args)
      doc.concat(pre_doc)
    end

    skip_space
    skip_comma_and_spaces if comma?

    skip_op "*"
    doc << "*#{visit star}"

    if post_args && !post_args.empty?
      skip_comma_and_spaces
      post_doc = visit_literal_elements_simple_doc(post_args)
      doc.concat(post_doc)
    end
    B.join(', ', doc)
  end

  def visit_begin(node)
    # begin
    #   body
    # end
    #
    # [:begin, [:bodystmt, body, rescue_body, else_body, ensure_body]]
    skip_keyword "begin"
    B.concat([
      "begin",
      visit(node[1])
    ])
  end

  def visit_bodystmt(node)
    # [:bodystmt, body, rescue_body, else_body, ensure_body]
    _, body, rescue_body, else_body, ensure_body = node

    line = @line

    indent_body body

    while rescue_body
      # [:rescue, type, name, body, more_rescue]
      _, type, name, body, more_rescue = rescue_body
      write_indent
      consume_keyword "rescue"
      if type
        skip_space
        write_space
        indent(@column) do
          visit_rescue_types(type)
        end
      end

      if name
        skip_space
        write_space
        consume_op "=>"
        skip_space
        write_space
        visit name
      end

      indent_body body
      rescue_body = more_rescue
    end

    if else_body
      # [:else, body]
      write_indent
      consume_keyword "else"
      indent_body else_body[1]
    end

    if ensure_body
      # [:ensure, body]
      write_indent
      consume_keyword "ensure"
      indent_body ensure_body[1]
    end

    write_indent if @line != line
    consume_keyword "end"
  end

  def visit_bodystmt_doc(node)
    # [:bodystmt, body, rescue_body, else_body, ensure_body]
    _, body, rescue_body, else_body, ensure_body = node

    result = visit_exps_doc(body)
    if result[:parts].empty?
      doc = []
    else
      doc = [
        B.indent(B.concat([
          B::LINE,
          result
        ])),
        B::LINE
      ]
    end

    while rescue_body
      # [:rescue, type, name, body, more_rescue]
      _, type, name, body, more_rescue = rescue_body
      rescue_statement_doc = [B::LINE, "rescue"]
      # write_indent
      skip_keyword "rescue"
      if type
        skip_space
        rescue_statement_doc << " "
        rescue_statement_doc << visit_rescue_types_doc(type)
      end

      if name
        skip_space
        rescue_statement_doc << " "
        skip_op "=>"
        rescue_statement_doc << "=>"
        skip_space
        rescue_statement_doc << " "
        rescue_statement_doc << visit(name)
      end
      rescue_statement_doc << B::LINE
      # puts rescue_statement_doc.inspect
      rescue_body = more_rescue
      doc << B.concat([
        B.concat(rescue_statement_doc),
        B.indent(B.concat([B::LINE, visit_exps_doc(body)]))
      ])
    end

    if else_body
      # [:else, body]
      skip_keyword "else"
      doc << "else"
      doc << B.indent(visit_exps_doc(else_body[1]))
    end

    if ensure_body
      # [:ensure, body]
      skip_keyword "ensure"
      doc << B.concat([
        B.concat(["ensure", B::LINE]),
        B.indent(B.concat([B::LINE, visit_exps_doc(ensure_body[1])]))
      ])
    end

    skip_space_or_newline_doc
    doc << B::SOFT_LINE

    skip_keyword "end"
    # skip_space_or_newline
    doc << "end"
    comments, newline_before_comment = skip_space_or_newline_doc
    add_comments_on_line(doc, comments, newline_before_comment: newline_before_comment)
    doc << B::LINE_SUFFIX_BOUNDARY
    B.concat(doc)
  end

  def visit_rescue_types(node)
    visit_exps to_ary(node), with_lines: false
  end

  def visit_rescue_types_doc(node)
    puts node.inspect
    if node.first.is_a?(Array)
      visit_comma_separated_list_doc(node)
    else
      visit node
    end
  end

  def visit_mrhs_new_from_args(node)
    # Multiple exception types
    # [:mrhs_new_from_args, exps, final_exp]
    _, exps, final_exp = node
    if final_exp
      puts final_exp
      # skip_space
      # check :on_comma
      # next_token

      # visit final_exp
      exp_list = [*exps, final_exp]
    else
      exp_list = to_ary(exps)
    end
    visit_comma_separated_list_doc(exp_list)
  end

  def visit_mlhs_paren(node)
    # [:mlhs_paren,
    #   [[:mlhs_paren, [:@ident, "x", [1, 12]]]]
    # ]
    _, args = node

    visit_mlhs_or_mlhs_paren(args)
  end

  def visit_mlhs(node)
    # [:mlsh, *args]
    _, *args = node

    visit_mlhs_or_mlhs_paren(args)
  end

  def visit_mlhs_or_mlhs_paren(args)
    # Sometimes a paren comes, some times not, so act accordingly.
    has_paren = current_token_kind == :on_lparen
    doc = []
    if has_paren
      skip_token :on_lparen
      skip_space_or_newline
      doc << "("
    end

    # For some reason there's nested :mlhs_paren for
    # a single parentheses. It seems when there's
    # a nested array we need parens, otherwise we
    # just output whatever's inside `args`.
    if args.is_a?(Array) && args[0].is_a?(Array)
      doc << B.indent(visit_comma_separated_list_doc args)
      skip_space_or_newline
    else
      doc << visit(args)
    end

    if has_paren
      # Ripper has a bug where parsing `|(w, *x, y), z|`,
      # the "y" isn't returned. In this case we just consume
      # all tokens until we find a `)`.
      while current_token_kind != :on_rparen
        doc << skip_token(current_token_kind)
      end

      skip_token :on_rparen
      doc << ")"
    end
    B.concat(doc)
  end

  def visit_mrhs_add_star(node)
    # [:mrhs_add_star, [], [:vcall, [:@ident, "x", [3, 8]]]]
    _, x, y = node
    doc = []
    if x.empty?
      skip_op "*"
      doc << "*#{visit(y)}"
    else
      doc << visit(x)
      # visit x
      doc << ","
      doc << B::LINE
      skip_params_comma if comma?
      skip_space
      skip_op "*"
      # visit y
      doc << "*#{visit(y)}"
    end
    B.group(B.concat(doc))
  end

  def visit_for(node)
    #[:for, var, collection, body]
    _, var, collection, body = node

    doc = ["for "]
    skip_keyword "for"
    skip_space

    doc << visit_comma_separated_list_doc(to_ary(var))
    skip_space
    if comma?
      check :on_comma
      next_token
      skip_space_or_newline
    end

    skip_space
    skip_keyword "in"
    doc << " in "
    skip_space
    doc << visit(collection)
    skip_space_or_newline
    skip_keyword "do" if current_token_value == "do"

    body_doc = visit_exps_doc(body, with_lines: true)

    doc << B.group(
      B.concat([B.if_break("", " do"), B.indent(B.concat([B::LINE, body_doc])), B::SOFT_LINE, "end"]),
      should_break: body.length > 1
    )
    skip_space
    skip_keyword "end"
    B.concat(doc)
  end

  def visit_BEGIN(node)
    visit_BEGIN_or_END node, "BEGIN"
  end

  def visit_END(node)
    visit_BEGIN_or_END node, "END"
  end

  def visit_BEGIN_or_END(node, keyword)
    # [:BEGIN, body]
    _, body = node

    skip_keyword(keyword)
    skip_space

    skip_token :on_lbrace
    skip_space
    doc = visit_exps_doc(body)
    skip_space
    skip_token :on_rbrace

    return B.group(
      B.concat([keyword, " {", B.indent(B.concat([B::LINE, doc])), B::LINE, "}"]),
      should_break: body.length > 1
    )
  end

  def visit_comma_separated_list(nodes)
    needs_indent = false

    if newline? || comment?
      indent { consume_end_of_line }
      needs_indent = true
      base_column = next_indent
      write_indent(base_column)
    else
      base_column = @column
    end

    nodes = to_ary(nodes)
    nodes.each_with_index do |exp, i|
      maybe_indent(needs_indent, base_column) do
        if block_given?
          yield exp
        else
          visit exp
        end
      end

      next if last?(i, nodes)

      skip_space
      check :on_comma
      write ","
      next_token
      skip_space_or_newline_using_setting(:one, base_column || @indent)
    end
  end

  def visit_comma_separated_list_doc_no_group(nodes)
    should_break = comment?
    doc = []

    nodes = to_ary(nodes)
    nodes.each_with_index do |exp, i|
      should_break ||= handle_space_or_newline_doc(doc, with_lines: false)
      if block_given?
        r = yield exp
      else
        r = visit(exp)
      end
      puts r.inspect
      doc << r
      should_break ||= handle_space_or_newline_doc(doc, with_lines: false)

      unless last?(i, nodes)
        check :on_comma
        next_token
      end
    end
    [should_break, doc]
  end

  def visit_comma_separated_list_doc(nodes)
    should_break, doc = visit_comma_separated_list_doc_no_group(nodes)
    B.group(B.join(B.concat([',', B::LINE]), doc), should_break: should_break)
  end

  def visit_mlhs_add_star(node)
    # [:mlhs_add_star, before, star, after]
    _, before, star, after = node

    doc = []
    if before && !before.empty?
      # Maybe a Ripper bug, but if there's something before a star
      # then a star shouldn't be here... but if it is... handle it
      # somehow...
      if current_token_kind == :on_op && current_token_value == "*"
        after = star
        before, star = nil, before
      else
        doc << visit_comma_separated_list_doc(to_ary(before))
        skip_comma_and_spaces
      end
    end

    skip_op "*"
    star_doc = "*"

    if star
      skip_space_or_newline
      star_doc = "*" + visit(star)
    end
    doc << star_doc

    if after && !after.empty?
      skip_comma_and_spaces
      doc << visit_comma_separated_list_doc(after)
    end
    B.join(", ", doc)
  end

  def visit_rest_param(node)
    # [:rest_param, name]

    _, name = node

    consume_op "*"

    if name
      skip_space_or_newline
      visit name
    end
  end

  def visit_kwrest_param(node)
    # [:kwrest_param, name]

    _, name = node

    if name
      skip_space_or_newline
      visit name
    end
  end

  def visit_unary(node)
    # [:unary, :-@, [:vcall, [:@ident, "x", [1, 2]]]]
    _, op, exp = node
    doc = [skip_op_or_keyword(op)]

    first_space = space?
    skip_space_or_newline
    if op == :not
      has_paren = current_token_kind == :on_lparen

      if has_paren && !first_space
        doc << "("
        next_token
        skip_space_or_newline
      end

      doc << visit(exp)

      if has_paren && !first_space
        skip_space_or_newline
        check :on_rparen
        doc << ")"
        next_token
      end
    else
      doc <<  visit(exp)
    end
    B.concat(doc)
  end

  def visit_binary(node)
    # [:binary, left, op, right]
    _, left, op, right = node

    # If this binary is not at the beginning of a line, if there's
    # a newline following the op we want to align it with the left
    # value. So for example:
    #
    # var = left_exp ||
    #       right_exp
    #
    # But:
    #
    # def foo
    #   left_exp ||
    #     right_exp
    # end
    # needed_indent = @column == @indent ? next_indent : @column
    # base_column = @column
    # token_column = current_token_column

    doc = [visit(left)]

    needs_space = space?

    has_backslash, first_space = skip_space_backslash
    # if has_backslash
    #   needs_space = true
    #   doc << "\\"
    #   doc << B::LINE
    #   # write_line
    #   # write_indent(next_indent)
    # else
      skip_space
    # end

    doc << B::LINE
    doc << skip_op_or_keyword(op)
    # doc << B::LINE

    first_space = skip_space

    # if newline? || comment?
    #   indent_after_space right,
    #                      want_space: needs_space,
    #                      needed_indent: needed_indent,
    #                      token_column: token_column,
    #                      base_column: base_column
    # else
    #   write_space
    handle_space_or_newline_doc(doc)
    if doc.last != B::LINE
      doc << B::LINE
    end
    doc << visit(right)
    B.group(B.indent(B.concat(doc)))
  end

  def consume_op_or_keyword(op)
    case current_token_kind
    when :on_op, :on_kw
      write current_token_value
      next_token
    else
      bug "Expected op or kw, not #{current_token_kind}"
    end
  end

  def skip_op_or_keyword(op)
    case current_token_kind
    when :on_op, :on_kw
      result = current_token_value
      next_token
    else
      bug "Expected op or kw, not #{current_token_kind}"
    end
    result
  end

  def visit_class(node)
    # [:class,
    #   name
    #   superclass
    #   [:bodystmt, body, nil, nil, nil]]
    _, name, superclass, body = node
    doc = ["class", " "]
    skip_keyword "class"
    comments, newline_before_comment = skip_space_or_newline_doc
    add_comments_on_line(doc, comments, newline_before_comment: newline_before_comment)
    skip_space
    doc << visit(name)

    if superclass
      skip_space_or_newline_doc
      # write_space
      doc << " "
      skip_op "<"
      doc << "<"
      skip_space_or_newline_doc
      doc << " "
      # write_space
      doc << visit(superclass)
    end

    doc << visit_doc(body)
    # doc << B::LINE
    B.concat(doc)
  end

  def visit_module(node)
    # [:module,
    #   name
    #   [:bodystmt, body, nil, nil, nil]]
    _, name, body = node
    doc = ["module "]
    skip_keyword "module"
    handle_space_or_newline_doc(doc)
    write_space
    doc << visit(name)

    doc << visit(body)
  end

  def visit_def(node)
    # [:def,
    #   [:@ident, "foo", [1, 6]],
    #   [:params, nil, nil, nil, nil, nil, nil, nil],
    #   [:bodystmt, [[:void_stmt]], nil, nil, nil]]
    _, name, params, body = node
    doc = ["def "]
    skip_keyword "def"
    skip_space

    doc << visit_def_from_name(name, params, body)
    B.concat(doc)
  end

  def visit_def_with_receiver(node)
    # [:defs,
    # [:vcall, [:@ident, "foo", [1, 5]]],
    # [:@period, ".", [1, 8]],
    # [:@ident, "bar", [1, 9]],
    # [:params, nil, nil, nil, nil, nil, nil, nil],
    # [:bodystmt, [[:void_stmt]], nil, nil, nil]]
    _, receiver, period, name, params, body = node
    doc = ["def "]
    skip_keyword "def"
    skip_space
    doc << visit(receiver)
    skip_space_or_newline

    check :on_period
    doc << "."
    next_token
    skip_space_or_newline

    doc << visit_def_from_name(name, params, body)
    B.concat(doc)
  end

  def visit_def_from_name(name, params, body)
    doc = [visit(name)]
    puts doc.inspect

    params = params[1] if params[0] == :paren

    first_space = skip_space

    if current_token_kind == :on_lparen
      next_token
      skip_space
      skip_semicolons

      if empty_params?(params)
        skip_space_or_newline
        check :on_rparen
        next_token
        doc << "()"
      else
        doc << "("
        puts doc.inspect
        doc << visit_doc(params)
        # if newline? || comment?
        #   column = @column
        #   indent(column) do
        #     consume_end_of_line
        #     write_indent
        #     visit params
        #   end
        # else
        #   indent(@column) do
        #     visit params
        #   end
        # end

        skip_space_or_newline
        check :on_rparen
        doc << ")"
        next_token
      end
    elsif !empty_params?(params)
      if parens_in_def == :yes
        doc << "("
      else
        doc << " "
      end

      doc << B.group(visit_doc(params))
      doc << ")" if parens_in_def == :yes
      skip_space
    end

    doc << visit_doc(body)
    puts doc.inspect
    B.concat(doc)
  end

  def empty_params?(node)
    _, a, b, c, d, e, f, g = node
    !a && !b && !c && !d && !e && !f && !g
  end

  def visit_paren(node)
    # ( exps )
    #
    # [:paren, exps]
    _, exps = node

    skip_token :on_lparen
    skip_space_or_newline

    doc = ["("]
    if exps
      doc << visit_exps_doc(to_ary(exps), with_lines: false)
    end

    skip_space_or_newline
    doc << ")"
    skip_token :on_rparen
    B.concat(doc)
  end

  def visit_params(node)
    # (def params)
    #
    # [:params, pre_rest_params, args_with_default, rest_param, post_rest_params, label_params, double_star_param, blockarg]
    _, pre_rest_params, args_with_default, rest_param, post_rest_params, label_params, double_star_param, blockarg = node

    needs_comma = false
    doc = []
    should_break = false
    if pre_rest_params
      should_break, pre_doc = visit_comma_separated_list_doc_no_group(pre_rest_params)
      doc = pre_doc
      # needs_comma = true
    end

    if args_with_default
      write_params_comma if needs_comma
      default_should_break, default_doc = visit_comma_separated_list_doc_no_group(args_with_default) do |arg, default|
        arg_doc = [visit(arg)]
        skip_space
        skip_op "="
        skip_space
        arg_doc << " = "
        arg_doc << visit(default)
        B.concat(arg_doc)
      end
      should_break ||= default_should_break
      doc = doc.concat(default_doc)
      # needs_comma = true
    end

    if rest_param
      # check for trailing , |x, |
      if rest_param == 0
        # write_params_comma
        skip_params_comma
      else
        # [:rest_param, [:@ident, "x", [1, 15]]]
        _, rest = rest_param
        # doc << B.concat([",", B::LINE]) if needs_comma
        skip_params_comma if comma?
        skip_op "*"
        skip_space_or_newline
        doc << "*#{visit(rest)}" if rest
        doc << "*" unless rest
        # needs_comma = true
      end
    end

    if post_rest_params
      skip_params_comma if comma?
      post_should_break, post_doc = visit_comma_separated_list_doc_no_group(post_rest_params)
      should_break ||= post_should_break
      doc = doc.concat(post_doc)
      # write_params_comma if needs_comma
      # visit_comma_separated_list post_rest_params
      # needs_comma = true
    end

    if label_params
      # [[label, value], ...]
      skip_params_comma if comma?
      label_should_break, label_doc = visit_comma_separated_list_doc_no_group(label_params) do |label, value|
        # [:@label, "b:", [1, 20]]
        label_doc = [label[1]]
        # write label[1]
        next_token
        skip_space_or_newline
        if value
          skip_space
          label_doc << " "
          label_doc << visit(value)
        end
        B.concat(label_doc)
      end
      should_break ||= label_should_break
      doc = doc.concat(label_doc)
      # needs_comma = true
    end

    if double_star_param
      skip_params_comma if comma?
      skip_op "**"
      skip_space_or_newline

      # A nameless double star comes as an... Integer? :-S
      doc << "**#{visit(double_star_param)}" if double_star_param.is_a?(Array)
      doc << "**" unless double_star_param.is_a?(Array)
      skip_space_or_newline
      # needs_comma = true
    end

    if blockarg
      # [:blockarg, [:@ident, "block", [1, 16]]]
      skip_params_comma if comma?
      skip_space_or_newline
      skip_op "&"
      skip_space_or_newline
      doc << "&#{visit(blockarg[1])}"
    end
    B.group(B.join(B.concat([',', B::LINE]), doc), should_break: should_break)
  end

  def write_params_comma
    skip_space
    check :on_comma
    write ","
    next_token
    skip_space_or_newline_using_setting(:one)
  end

  def skip_params_comma
    skip_space
    check :on_comma
    # write ","
    next_token
    skip_space_or_newline_doc
    # skip_space_or_newline_using_setting(:one)
  end

  def visit_array(node)
    # [:array, elements]

    # Check if it's `%w(...)` or `%i(...)`
    case current_token_kind
    when :on_qwords_beg, :on_qsymbols_beg, :on_words_beg, :on_symbols_beg
      return visit_q_or_i_array(node)
    end

    _, elements = node

    doc = []
    check :on_lbracket
    next_token

    if elements
      pre_comments, doc, should_break = visit_literal_elements_doc(to_ary(elements))

      doc = doc_group(
        B.concat([
          "[",
          B.indent(B.concat([B.concat(pre_comments), B::SOFT_LINE, *doc])),
          B::SOFT_LINE,
          "]",
        ]),
        should_break,
      )
    else
      skip_space_or_newline
      doc = "[]"
    end

    check :on_rbracket
    next_token
    doc
  end

  def visit_q_or_i_array(node)
    _, elements = node
    doc = []
    # For %W it seems elements appear inside other arrays
    # for some reason, so we flatten them
    if elements[0].is_a?(Array) && elements[0][0].is_a?(Array)
      elements = elements.flat_map { |x| x }
    end

    has_space = current_token_value.end_with?(" ")
    doc << current_token_value.strip

    # (pre 2.5.0) If there's a newline after `%w(`, write line and indent
    if current_token_value.include?("\n") && elements # "%w[\n"
      doc << B::LINE
      # write_line
      # write_indent next_indent
    end

    next_token

    # fix for 2.5.0 ripper change
    if current_token_kind == :on_words_sep && elements && !elements.empty?
      value = current_token_value
      has_space = value.start_with?(' ')
      if value.include?("\n") && elements # "\n "
        # doc << B::SOFT_LINE
        # write_line
        # write_indent next_indent
      end
      next_token
      has_space = true if current_token_value.start_with?(' ')
    end

    if elements && !elements.empty?
      write_space if has_space
      column = @column

      elements.each_with_index do |elem, i|
        if elem[0] == :@tstring_content
          # elem is [:@tstring_content, string, [1, 5]
          doc << elem[1].strip
          next_token
        else
          doc << visit(elem)
        end

        if !last?(i, elements) && current_token_kind == :on_words_sep
          # On a newline, write line and indent
          next_token
          doc << B::LINE
          # if current_token_value.include?("\n")
          #   # write_line
          #   # write_indent(column)
          # else
          #   next_token
          #   write_space
          # end
        end
      end
    end

    has_newline = false
    last_token = nil

    while current_token_kind == :on_words_sep
      has_newline ||= current_token_value.include?("\n")

      unless current_token[2].strip.empty?
        last_token = current_token
      end

      next_token
    end

    if has_newline
      # write_line
      # write_indent
    elsif has_space && elements && !elements.empty?
      # write_space
    end

    if last_token
      doc << last_token[2].strip
    else
      doc << current_token_value.strip
      next_token
    end
    # B.concat(doc)
    B.concat([B.group(B.indent(B.concat([B::SOFT_LINE, B.concat(doc)]))), B::SOFT_LINE])
  end

  def visit_hash(node)
    # [:hash, elements]
    _, elements = node

    token_column = current_token_column

    check :on_lbrace
    next_token

    if elements
      # [:assoclist_from_args, elements]
      pre_comments, doc, should_break = visit_literal_elements_doc(to_ary(elements[1]))
      doc = doc_group(
        B.concat([
          "{",
          B.indent(B.concat([B.concat(pre_comments), B::SOFT_LINE, *doc])),
          B::SOFT_LINE,
          "}",
        ]),
        should_break
      )
    else
      skip_space_or_newline
      doc = "{}"
    end

    check :on_rbrace
    next_token
    doc
  end

  # Helper manipulate the inner_group_breaks stack and set the break for the
  # group correctly.
  def doc_group(contents, should_break)
    inner_group_broke = !!@inner_group_breaks.pop
    should_break ||= inner_group_broke
    result = B.group(contents, should_break: should_break)
    @inner_group_breaks.push(should_break)
    result
  end

  def visit_hash_key_value(node)
    # key => value
    #
    # [:assoc_new, key, value]
    _, key, value = node
    doc = []

    # If a symbol comes it means it's something like
    # `:foo => 1` or `:"foo" => 1` and a `=>`
    # always follows
    symbol = current_token_kind == :on_symbeg
    arrow = symbol || !(key[0] == :@label || key[0] == :dyna_symbol)

    doc << visit(key)
    skip_space_or_newline

    # Don't output `=>` for keys that are `label: value`
    # or `"label": value`
    if arrow
      next_token
      doc << " => "
      skip_space_or_newline
    else
      doc << ' '
    end
    doc << visit(value)
    B.concat(doc)
  end

  def visit_splat_inside_hash(node)
    # **exp
    #
    # [:assoc_splat, exp]
    skip_op "**"
    skip_space_or_newline
    B.concat(["**", visit(node[1])])
  end

  def visit_range(node, inclusive)
    # [:dot2, left, right]
    _, left, right = node
    doc = []
    doc << visit(left)
    skip_space_or_newline
    op = inclusive ? ".." : "..."
    skip_op(op)
    doc << op
    skip_space_or_newline
    doc << visit(right)
    B.concat(doc)
  end

  def visit_regexp_literal(node)
    # [:regexp_literal, pieces, [:@regexp_end, "/", [1, 1]]]
    _, pieces = node

    check :on_regexp_beg
    doc = [current_token_value]
    # write current_token_value
    next_token

    doc << visit_exps_doc(pieces, with_lines: false)

    check :on_regexp_end
    doc << current_token_value
    # write current_token_value
    next_token
    B.concat(doc)
  end

  def visit_array_access(node)
    # exp[arg1, ..., argN]
    #
    # [:aref, name, args]
    _, name, args = node

    visit_array_getter_or_setter name, args
  end

  def visit_array_setter(node)
    # exp[arg1, ..., argN]
    # (followed by `=`, though not included in this node)
    #
    # [:aref_field, name, args]
    _, name, args = node

    visit_array_getter_or_setter name, args
  end

  def visit_array_getter_or_setter(name, args)
    doc = [visit(name)]

    token_column = current_token_column

    skip_space
    check :on_lbracket
    doc << "["
    next_token

    column = @column

    first_space = skip_space

    # Sometimes args comes with an array...
    if args && args[0].is_a?(Array)
      pre_comments, args_doc, should_break = visit_literal_elements_doc(args)
      doc << B.group(B.concat(args_doc), should_break: should_break)
    else
      # if newline? || comment?
      #   needed_indent = next_indent
      #   if args
      #     consume_end_of_line
      #     write_indent(needed_indent)
      #   else
      #     skip_space_or_newline
      #   end
      # else
      #   write_space_using_setting(first_space, :never)
      #   needed_indent = column
      # end
      skip_space_or_newline

      if args
        # indent(needed_indent) do
        #   visit args
        # end
        doc << visit(args)
      end
    end

    skip_space_or_newline_using_setting(:never)

    check :on_rbracket
    doc << "]"
    next_token
    B.concat(doc)
  end

  def visit_sclass(node)
    # class << self
    #
    # [:sclass, target, body]
    _, target, body = node
    doc = [
      skip_keyword("class"),
      " ",
      "<<",
      " ",
    ]

    skip_space
    next_token # "<<"
    skip_space
    doc << visit(target)
    doc << visit_doc(body)
    B.concat(doc)
  end

  def visit_setter(node)
    # foo.bar
    # (followed by `=`, though not included in this node)
    #
    # [:field, receiver, :".", name]
    _, receiver, dot, name = node

    doc = []
    doc << visit(receiver)

    skip_space_or_newline

    doc << skip_call_dot

    skip_space_or_newline_using_setting(:no, next_indent)

    doc << visit(name)

    B.concat(doc)
  end

  def visit_control_keyword(node, keyword)
    _, exp = node

    doc = [skip_keyword(keyword), " "]

    if exp && !exp.empty?
      skip_space

      doc << visit_exps_doc(to_ary(node[1]), with_lines: false)
    end
    B.concat(doc)
  end

  def visit_lambda(node)
    # [:lambda, [:params, nil, nil, nil, nil, nil, nil, nil], [[:void_stmt]]]
    _, params, body = node

    check :on_tlambda
    doc = ["-> "]
    next_token

    first_space = skip_space

    unless empty_params?(params)
      doc << visit(params)
      skip_space
      doc << " "
    end

    brace = current_token_value == "{"

    if brace
      skip_token :on_tlambeg
    else
      skip_keyword "do"
    end
    body_doc = [B.if_break("do", "{")]

    body_doc << B.indent(B.concat([B::LINE, visit_exps_doc(body)]))

    if brace
      skip_token :on_rbrace
    else
      skip_keyword "end"
    end

    body_doc << B.concat([B::SOFT_LINE, B.if_break("end", "}")])
    doc << B.group(B.concat(body_doc), should_break: body.length > 1)
    B.concat(doc)
  end

  def visit_super(node)
    # [:super, args]
    _, args = node

    base_column = current_token_column

    skip_keyword "super"
    doc = ["super"]

    if space?
      doc << " "
      skip_space
      doc << visit_command_args(args, base_column)
    else
      doc << visit_call_at_paren(node, args)
    end
    B.concat(doc)
  end

  def visit_defined(node)
    # [:defined, exp]
    _, exp = node

    skip_keyword "defined?"
    has_space = space?
    doc = ["defined?"]

    if has_space
      skip_space
    else
      skip_space_or_newline
    end

    has_paren = current_token_kind == :on_lparen

    if has_paren && !has_space
      doc << "("
      next_token
      skip_space_or_newline
    end
    doc << " " unless has_paren
    doc << visit(exp)

    if has_paren && !has_space
      skip_space_or_newline
      check :on_rparen
      doc << ")"
      next_token
    end
    B.concat(doc)
  end

  def visit_alias(node)
    # [:alias, from, to]
    _, from, to = node
    doc = [
      skip_keyword("alias"),
      " "
    ]

    skip_space
    doc << visit(from)
    skip_space
    doc << " "
    doc << visit(to)
    B.concat(doc)
  end

  def visit_undef(node)
    # [:undef, exps]
    _, exps = node

    skip_keyword "undef"
    skip_space
    B.concat(["undef ", visit_comma_separated_list_doc(exps)])
  end

  def visit_literal_elements(elements, inside_hash: false, inside_array: false, token_column:)
    base_column = @column
    base_line = @line
    needs_final_space = (inside_hash || inside_array) && space?
    first_space = skip_space

    if inside_hash
      needs_final_space = false
    end

    if inside_array
      needs_final_space = false
    end

    if newline? || comment?
      needs_final_space = false
    end

    # If there's a newline right at the beginning,
    # write it, and we'll indent element and always
    # add a trailing comma to the last element
    needs_trailing_comma = newline? || comment?
    if needs_trailing_comma
      if (call_info = @line_to_call_info[@line])
        call_info << true
      end

      needed_indent = next_indent
      indent { consume_end_of_line }
      write_indent(needed_indent)
    else
      needed_indent = base_column
    end

    wrote_comma = false
    first_space = nil

    elements.each_with_index do |elem, i|
      @literal_elements_level = @node_level

      is_last = last?(i, elements)
      wrote_comma = false

      if needs_trailing_comma
        indent(needed_indent) { visit elem }
      else
        visit elem
      end

      # We have to be careful not to aumatically write a heredoc on next_token,
      # because we miss the chance to write a comma to separate elements
      first_space = skip_space_no_heredoc_check
      wrote_comma = check_heredocs_in_literal_elements(is_last, needs_trailing_comma, wrote_comma)

      next unless comma?

      unless is_last
        write ","
        wrote_comma = true
      end

      # We have to be careful not to aumatically write a heredoc on next_token,
      # because we miss the chance to write a comma to separate elements
      next_token_no_heredoc_check

      first_space = skip_space_no_heredoc_check
      wrote_comma = check_heredocs_in_literal_elements(is_last, needs_trailing_comma, wrote_comma)

      if newline? || comment?
        if is_last
          # Nothing
        else
          indent(needed_indent) do
            consume_end_of_line(first_space: first_space)
            write_indent
          end
        end
      else
        write_space unless is_last
      end
    end
    @literal_elements_level = nil

    if needs_trailing_comma
      write "," unless wrote_comma || !trailing_commas || @last_was_heredoc

      consume_end_of_line(first_space: first_space)
      write_indent
    elsif comment?
      consume_end_of_line(first_space: first_space)
    else
      if needs_final_space
        consume_space
      else
        skip_space_or_newline
      end
    end

    if current_token_column == token_column && needed_indent < token_column
      # If the closing token is aligned with the opening token, we want to
      # keep it like that, for example in:
      #
      # foo([
      #       2,
      #     ])
      @literal_indents << [base_line, @line, token_column + INDENT_SIZE - needed_indent]
    elsif call_info && call_info[0] == current_token_column
      # If the closing literal position matches the column where
      # the call started, we want to preserve it like that
      # (otherwise we align it to the first parameter)
      call_info << @line
    end
  end

  def add_comments_to_doc(comments, doc)
    return false if comments.empty?

    comments.each do |c|
      doc << B.line_suffix(" " + c.rstrip)
    end
    return true
  end

  def add_comments_on_line(element_doc, comments, newline_before_comment:)
    return false if comments.empty?

    unless element_doc.empty?
      first_comment = comments.shift
      if newline_before_comment
        element_doc << B.concat([
          element_doc.pop,
          B.line_suffix(B.concat([B::LINE, first_comment.rstrip])),
        ])
      else
        element_doc << B.concat([element_doc.pop, B.line_suffix(" " + first_comment.rstrip)])
      end
    end
    comments.each do |comment|
      element_doc << B.line_suffix(B.concat([B::LINE, comment.rstrip]))
    end
    true
  end

  # Handles literal elements where there are no comments or heredocs to worry
  # about.
  def visit_literal_elements_simple_doc(elements)
    doc = []

    skip_space_or_newline
    elements.each do |elem|
      doc_el = visit(elem)
      if doc_el.is_a?(Array)
        doc.concat(doc_el)
      else
        doc << doc_el
      end

      skip_space_or_newline
      next unless comma?
      next_token
      skip_space_or_newline
    end

    doc
  end

  def add_heredoc_to_doc(doc, current_doc, element_doc, comments, is_last: false)
    value, comment = check_heredocs_in_literal_elements_doc
    if value
      value = value.last.rstrip
    end
    add_heredoc_to_doc_with_value(doc, current_doc, element_doc, comments, value, comment, is_last: is_last)
  end

  def add_heredoc_to_doc_with_value(doc, current_doc, element_doc, comments, value, comment, is_last: false)
    return [current_doc, false, element_doc] if value.nil?

    last = current_doc.pop
    unless last.nil?
      doc << B.join(
        B.concat([",", B::LINE_SUFFIX_BOUNDARY, B::LINE]),
        [*current_doc, B.concat([last, B.if_break(',', '')])]
      )
    end

    unless comments.empty?
      comment = element_doc.pop
    end

    comment_array = [B.line_suffix(" " + comment)] if comment
    comment_array ||= []

    doc_with_heredoc = []
    unless element_doc.empty?
      doc_with_heredoc.concat(element_doc)
      if trailing_commas || !is_last
        doc_with_heredoc << ","
      end
    end
    doc_with_heredoc.concat(
      [*comment_array, B::LINE_SUFFIX_BOUNDARY, value, B::SOFT_LINE]
    )
    doc << B.concat(doc_with_heredoc)
    return [[], true, []]
  end

  def visit_literal_elements_doc(elements)
    doc = []
    current_doc = []
    element_doc = []
    pre_comments = []
    has_heredocs = false

    comments, newline_before_comment = skip_space_or_newline_doc
    has_comment = add_comments_to_doc(comments, pre_comments)

    elements.each_with_index do |elem, i|
      @literal_elements_level = @node_level
      is_last = elements.length == i + 1

      current_doc.concat(element_doc)
      element_doc = []
      doc_el = visit(elem)
      if doc_el.is_a?(Array)
        element_doc.concat(doc_el)
      else
        element_doc << doc_el
      end
      if @last_was_heredoc
        current_doc, heredoc_present, element_doc = add_heredoc_to_doc_with_value(
          doc, current_doc, element_doc, [], element_doc.pop, nil, is_last: is_last,
        )
      else
        current_doc, heredoc_present, element_doc = add_heredoc_to_doc(
          doc, current_doc, element_doc, [], is_last: is_last,
        )
      end
      has_heredocs ||= heredoc_present

      comments, newline_before_comment = skip_space_or_newline_doc
      has_comment = true if add_comments_on_line(element_doc, comments, newline_before_comment: false)

      next unless comma?
      next_token_no_heredoc_check
      current_doc, heredoc_present, element_doc = add_heredoc_to_doc(
        doc, current_doc, element_doc, comments, is_last: is_last,
      )
      has_heredocs ||= heredoc_present
      comments, newline_before_comment = skip_space_or_newline_doc

      has_comment = true if add_comments_on_line(element_doc, comments, newline_before_comment: newline_before_comment)
    end
    @literal_elements_level = nil
    current_doc.concat(element_doc)

    if trailing_commas && !current_doc.empty?
      last = current_doc.pop
      current_doc << B.concat([last, B.if_break(',', '')])
    end
    doc << B.join(
      B.concat([",", B::LINE_SUFFIX_BOUNDARY, B::LINE]),
      current_doc
    )
    [pre_comments, doc, has_comment || has_heredocs]
  end

  def check_heredocs_in_literal_elements(is_last, needs_trailing_comma, wrote_comma)
    if (newline? || comment?) && !@heredocs.empty?
      if is_last && trailing_commas
        write "," unless wrote_comma
        wrote_comma = true
      end

      flush_heredocs
    end
    wrote_comma
  end

  def check_heredocs_in_literal_elements_doc
    skip_space
    if (newline? || comment?) && !@heredocs.empty?
      return flush_heredocs_doc
    end
    []
  end

  def visit_if(node)
    visit_if_or_unless node, "if"
  end

  def visit_unless(node)
    visit_if_or_unless node, "unless"
  end

  def visit_if_or_unless(node, keyword, check_end: true)
    # if cond
    #   then_body
    # else
    #   else_body
    # end
    #
    # [:if, cond, then, else]

    doc = [keyword, " "]
    skip_keyword(keyword)
    skip_space
    doc << visit(node[1])
    handle_space_or_newline_doc(doc, newline_limit: 1)

    doc << B.indent(B.concat([B::LINE, indent_body_doc(node[2])]))
    if else_body = node[3]
      doc << B::LINE

      case else_body[0]
      when :else
        skip_keyword "else"
        doc << "else"
        handle_space_or_newline_doc(doc)
        doc << B.indent(B.concat([B::LINE, indent_body_doc(else_body[1])]))
      when :elsif
        doc << visit_if_or_unless(else_body, "elsif", check_end: false)
      else
        bug "expected else or elsif, not #{else_body[0]}"
      end
    end

    if check_end
      doc << B::LINE
      doc << "end"
      skip_keyword "end"
    end
    B.concat(doc)
  end

  def visit_while(node)
    # [:while, cond, body]
    visit_while_or_until node, "while"
  end

  def visit_until(node)
    # [:until, cond, body]
    visit_while_or_until node, "until"
  end

  def visit_while_or_until(node, keyword)
    _, cond, body = node

    doc = [keyword, " "]
    skip_keyword keyword
    skip_space

    doc << visit(cond)
    handle_space_or_newline_doc(doc)

    doc << B.indent(B.concat([B::LINE, indent_body_doc(body, force_multiline: true)]))

    skip_keyword "end"
    doc << B::LINE
    doc << "end"
    B.concat(doc)
  end

  def visit_case(node)
    # [:case, cond, case_when]
    _, cond, case_when = node
    doc = ["case"]
    skip_keyword "case"
    handle_space_or_newline_doc(doc)

    if cond
      doc << " "
      skip_space
      doc << visit(cond)
    end
    doc << B::LINE

    skip_space_or_newline

    # write_indent
    doc << visit(case_when)

    # write_indent
    doc << "end"
    skip_keyword "end"
    B.concat(doc)
  end

  def visit_when(node)
    # [:when, conds, body, next_exp]
    _, conds, body, next_exp = node
    doc = ["when", " "]
    skip_keyword "when"
    skip_space
    # Align conditions on subsequent lines with the first condition.
    # This is done so that the subsequent conditions are distinctly conditions
    # rather than part of the body of the when statement.
    doc << B.align(5, visit_comma_separated_list_doc(conds))
    skip_space

    then_keyword = keyword?("then")
    if then_keyword
      next_token
      skip_space
    end
    handle_space_or_newline_doc(doc)
    doc << B::LINE
    doc << B.indent(B.concat([B::LINE, visit_exps_doc(body)]))
    doc << B::LINE

    if next_exp
      if next_exp[0] == :else
        # [:else, body]
        next_doc = ["else"]
        skip_keyword "else"

        handle_space_or_newline_doc(next_doc)
        next_doc << B::LINE
        next_doc << visit_exps_doc(next_exp[1])
        doc << B.indent(B.concat(next_doc))
        doc << B::LINE
      else
        doc << visit(next_exp)
      end
    end
    B.concat(doc)
  end

  def consume_space(want_preserve_whitespace: false)
    first_space = skip_space
    if want_preserve_whitespace && !newline? && !comment? && first_space
      write_space first_space[2] unless @output[-1] == " "
      skip_space_or_newline
    else
      skip_space_or_newline
      write_space unless @output[-1] == " "
    end
  end

  def consume_space_or_newline
    first_space = skip_space
    if newline? || comment?
      consume_end_of_line
      write_indent(next_indent)
    else
      consume_space
    end
  end

  def skip_space
    first_space = space? ? current_token : nil
    next_token while space?
    first_space
  end

  def skip_ignored_space
    next_token while current_token_kind == :on_ignored_sp
  end

  def skip_space_no_heredoc_check
    first_space = space? ? current_token : nil
    while space?
      next_token_no_heredoc_check
    end
    first_space
  end

  def skip_space_backslash
    return [false, false] unless space?

    first_space = current_token
    has_slash_newline = false
    while space?
      has_slash_newline ||= current_token_value == "\\\n"
      next_token
    end
    [has_slash_newline, first_space]
  end

  def skip_space_or_newline(_want_semicolon: false, write_first_semicolon: false)
    found_newline = false
    found_comment = false
    found_semicolon = false
    last = nil

    loop do
      case current_token_kind
      when :on_sp
        next_token
      when :on_nl, :on_ignored_nl
        next_token
        last = :newline
        found_newline = true
      when :on_semicolon
        if (!found_newline && !found_comment) || (!found_semicolon && write_first_semicolon)
          write "; "
        end
        next_token
        last = :semicolon
        found_semicolon = true
      when :on_comment
        write_line if last == :newline

        write_indent if found_comment
        if current_token_value.end_with?("\n")
          write_space
          write current_token_value.rstrip
          write "\n"
          write_indent(next_indent)
          @column = next_indent
        else
          write current_token_value
        end
        next_token
        found_comment = true
        last = :comment
      else
        break
      end
    end

    found_semicolon
  end

  def skip_space_or_newline_doc(newline_limit = Float::INFINITY)
    num_newlines = 0
    found_comment = false
    found_semicolon = false
    newline_before_comment = false
    last = nil
    comments = []
    loop do
      break if num_newlines >= newline_limit
      case current_token_kind
      when :on_sp
        next_token
      when :on_nl, :on_ignored_nl
        next_token
        last = :newline
        num_newlines += 1
        if comments.empty?
          newline_before_comment = true
        end
      when :on_semicolon
        next_token
        last = :semicolon
        found_semicolon = true
      when :on_comment
        if current_token_value.end_with?("\n")
          num_newlines += 1
          @column = next_indent
        end
        comments << current_token_value
        next_token
        found_comment = true
        last = :comment
      else
        break
      end
    end

    [comments, newline_before_comment, found_semicolon, num_newlines]
  end

  def skip_semicolons
    while semicolon? || space?
      next_token
    end
  end

  def empty_body?(body)
    body[0] == :bodystmt &&
      body[1].size == 1 &&
      body[1][0][0] == :void_stmt
  end

  def consume_token(kind)
    check kind
    val = current_token_value
    consume_token_value(val)
    next_token
    val
  end

  def skip_token(kind)
    val = current_token_value
    check kind
    next_token
    val
  end

  def consume_token_value(value)
    write value unless in_doc_mode?

    # If the value has newlines, we need to adjust line and column
    number_of_lines = value.count("\n")
    if number_of_lines > 0
      @line += number_of_lines
      last_line_index = value.rindex("\n")
      @column = value.size - (last_line_index + 1)
      @last_was_newline = @column == 0
    end
  end

  def consume_keyword(value)
    check :on_kw
    if current_token_value != value
      bug "Expected keyword #{value}, not #{current_token_value}"
    end
    write value
    next_token
  end

  def skip_keyword(value)
    check :on_kw
    if current_token_value != value
      bug "Expected keyword #{value}, not #{current_token_value}"
    end
    next_token
    value
  end

  def consume_op(value)
    check :on_op
    if current_token_value != value
      bug "Expected op #{value}, not #{current_token_value}"
    end
    write value unless in_doc_mode?
    next_token
  end

  def skip_op(value)
    check :on_op
    if current_token_value != value
      bug "Expected op #{value}, not #{current_token_value}"
    end
    next_token
  end

  # Consume and print an end of line, handling semicolons and comments
  #
  # - at_prefix: are we at a point before an expression? (if so, we don't need a space before the first comment)
  # - want_semicolon: do we want do print a semicolon to separate expressions?
  # - want_multiline: do we want multiple lines to appear, or at most one?
  def consume_end_of_line(at_prefix: false, want_semicolon: false, want_multiline: true, needs_two_lines_on_comment: false, first_space: nil)
    found_newline = false               # Did we find any newline during this method?
    found_comment_after_newline = false # Did we find a comment after some newline?
    last = nil                          # Last token kind found
    multilple_lines = false             # Did we pass through more than one newline?
    last_comment_has_newline = false    # Does the last comment has a newline?
    newline_count = 0                   # Number of newlines we passed
    last_space = first_space            # Last found space

    loop do
      case current_token_kind
      when :on_sp
        # Ignore spaces
        last_space = current_token
        next_token
      when :on_nl, :on_ignored_nl
        # I don't know why but sometimes a on_ignored_nl
        # can appear with nil as the "text", and that's wrong
        if current_token[2].nil?
          next_token
          next
        end

        if last == :newline
          # If we pass through consecutive newlines, don't print them
          # yet, but remember this fact
          multilple_lines = true unless last_comment_has_newline
        else
          # If we just printed a comment that had a newline,
          # we must print two newlines because we remove newlines from comments (rstrip call)
          write_line
          if last == :comment && last_comment_has_newline
            multilple_lines = true
          else
            multilple_lines = false
          end
        end
        found_newline = true
        next_token
        last = :newline
        newline_count += 1
      when :on_semicolon
        next_token
        # If we want to print semicolons and we didn't find a newline yet,
        # print it, but only if it's not followed by a newline
        if !found_newline && want_semicolon && last != :semicolon
          skip_space
          kind = current_token_kind
          case kind
          when :on_ignored_nl, :on_eof
          else
            return if (kind == :on_kw) &&
                      (%w[class module def].include?(current_token_value))
            write "; "
            last = :semicolon
          end
        end
        multilple_lines = false
      when :on_comment
        if last == :comment
          # Since we remove newlines from comments, we must add the last
          # one if it was a comment
          write_line

          # If the last comment is in the previous line and it was already
          # aligned to this comment, keep it aligned. This is useful for
          # this:
          #
          # ```
          # a = 1 # some comment
          #       # that continues here
          # ```
          #
          # We want to preserve it like that and not change it to:
          #
          # ```
          # a = 1 # some comment
          # # that continues here
          # ```
          if current_comment_aligned_to_previous_one?
            write_indent(@last_comment_column)
            track_comment(match_previous_id: true)
          else
            write_indent
          end
        else
          if found_newline
            if newline_count == 1 && needs_two_lines_on_comment
              if multilple_lines
                write_line
                multilple_lines = false
              else
                multilple_lines = true
              end
              needs_two_lines_on_comment = false
            end

            # Write line or second line if needed
            write_line if last != :newline || multilple_lines
            write_indent
            track_comment(id: @last_was_newline ? true : nil)
          else
            # If we didn't find any newline yet, this is the first comment,
            # so append a space if needed (for example after an expression)
            unless at_prefix
              # Preserve whitespace before comment unless we need to align them
              if last_space
                write last_space[2]
              else
                write_space
              end
            end

            # First we check if the comment was aligned to the previous comment
            # in the previous line, in order to keep them like that.
            if current_comment_aligned_to_previous_one?
              track_comment(match_previous_id: true)
            else
              # We want to distinguish comments that appear at the beginning
              # of a line (which means the line has only a comment) and comments
              # that appear after some expression. We don't want to align these
              # and consider them separate entities. So, we use `@last_was_newline`
              # as an id to distinguish that.
              #
              # For example, this:
              #
              #     # comment 1
              #       # comment 2
              #     call # comment 3
              #
              # Should format to:
              #
              #     # comment 1
              #     # comment 2
              #     call # comment 3
              #
              # Instead of:
              #
              #          # comment 1
              #          # comment 2
              #     call # comment 3
              #
              # We still want to track the first two comments to align to the
              # beginning of the line according to indentation in case they
              # are not already there.
              track_comment(id: @last_was_newline ? true : nil)
            end
          end
        end
        @last_comment = current_token
        @last_comment_column = @column
        last_comment_has_newline = current_token_value.end_with?("\n")
        last = :comment
        found_comment_after_newline = found_newline
        multilple_lines = false

        write current_token_value.rstrip
        next_token
      when :on_embdoc_beg
        if multilple_lines || last == :comment
          write_line
        end

        consume_embedded_comment
        last = :comment
        last_comment_has_newline = true
      else
        break
      end
    end

    # Output a newline if we didn't do so yet:
    # either we didn't find a newline and we are at the end of a line (and we didn't just pass a semicolon),
    # or the last thing was a comment (from which we removed the newline)
    # or we just passed multiple lines (but printed only one)
    if (!found_newline && !at_prefix && !(want_semicolon && last == :semicolon)) ||
       last == :comment ||
       (multilple_lines && (want_multiline || found_comment_after_newline))
      write_line
    end
  end

  def consume_embedded_comment
    consume_token_value current_token_value
    next_token

    while current_token_kind != :on_embdoc_end
      consume_token_value current_token_value
      next_token
    end

    consume_token_value current_token_value.rstrip
    next_token
  end

  def consume_end
    return "" unless current_token_kind == :on___end__

    line = current_token_line
    result = "\n"
    result += skip_token :on___end__

    lines = @code.lines[line..-1]
    lines.each do |line|
      result += line.chomp
      result += "\n"
    end
    result
  end

  def indent(value = nil)
    if value
      old_indent = @indent
      @indent = value
      yield
      @indent = old_indent
    else
      @indent += INDENT_SIZE
      yield
      @indent -= INDENT_SIZE
    end
  end

  def indent_body(exps, force_multiline: false)
    first_space = skip_space

    has_semicolon = semicolon?

    if has_semicolon
      next_token
      skip_semicolons
      first_space = nil
    end

    # If an end follows there's nothing to do
    if keyword?("end")
      if has_semicolon
        write "; "
      else
        write_space_using_setting(first_space, :one)
      end
      return
    end

    # A then keyword can appear after a newline after an `if`, `unless`, etc.
    # Since that's a super weird formatting for if, probably way too obsolete
    # by now, we just remove it.
    has_then = keyword?("then")
    if has_then
      next_token
      second_space = skip_space
    end

    has_do = keyword?("do")
    if has_do
      next_token
      second_space = skip_space
    end

    # If no newline or comment follows, we format it inline.
    if !force_multiline && !(newline? || comment?)
      if has_then
        write " then "
      elsif has_do
        write_space_using_setting(first_space, :one, at_least_one: true)
        write "do"
        write_space_using_setting(second_space, :one, at_least_one: true)
      elsif has_semicolon
        write "; "
      else
        write_space_using_setting(first_space, :one, at_least_one: true)
      end
      visit_exps exps, with_indent: false, with_lines: false

      consume_space

      return
    end

    indent do
      consume_end_of_line(want_multiline: false)
    end

    if keyword?("then")
      next_token
      skip_space_or_newline
    end

    # If the body is [[:void_stmt]] it's an empty body
    # so there's nothing to write
    if exps.size == 1 && exps[0][0] == :void_stmt
      skip_space_or_newline
    else
      indent do
        visit_exps exps, with_indent: true
      end
      write_line unless @last_was_newline
    end
  end

  def indent_body_doc(exps, force_multiline: false)
    doc = []
    first_space = skip_space

    has_semicolon = semicolon?

    if has_semicolon
      next_token
      skip_semicolons
      first_space = nil
    end

    # If an end follows there's nothing to do
    if keyword?("end")
      return B.concat(doc)
    end

    # A then keyword can appear after a newline after an `if`, `unless`, etc.
    # Since that's a super weird formatting for if, probably way too obsolete
    # by now, we just remove it.
    has_then = keyword?("then")
    if has_then
      next_token
      second_space = skip_space
    end

    has_do = keyword?("do")
    if has_do
      next_token
      second_space = skip_space
    end

    # If no newline or comment follows, we format it inline.
    # if !force_multiline && !(newline? || comment?)
    #   if has_then
    #     write " then "
    #   elsif has_do
    #     write_space_using_setting(first_space, :one, at_least_one: true)
    #     write "do"
    #     write_space_using_setting(second_space, :one, at_least_one: true)
    #   elsif has_semicolon
    #     write "; "
    #   else
    #     write_space_using_setting(first_space, :one, at_least_one: true)
    #   end
    #   visit_exps exps, with_indent: false, with_lines: false

    #   consume_space

    #   return
    # end

    # indent do
      handle_space_or_newline_doc(doc)
      # consume_end_of_line(want_multiline: false)
    # end

    if keyword?("then")
      next_token
      skip_space_or_newline
    end

    # If the body is [[:void_stmt]] it's an empty body
    # so there's nothing to write
    if exps.size == 1 && exps[0][0] == :void_stmt
      handle_space_or_newline_doc(doc)
      return B.concat(doc)
    else
      r = visit_exps_doc(exps, with_lines: force_multiline)
      puts 'hi', r.inspect, 'bye'
      return r
      # write_line unless @last_was_newline
    end
  end

  def maybe_indent(toggle, indent_size)
    if toggle
      indent(indent_size) do
        yield
      end
    else
      yield
    end
  end

  def write(value)
    @output << value unless in_doc_mode?
    @last_was_newline = false
    @last_was_heredoc = false
    @column += value.size
  end

  def write_space(value = " ")
    @output << value
    @column += value.size
  end

  def write_space_using_setting(first_space, setting, at_least_one: false)
    if first_space && setting == :dynamic
      write_space first_space[2]
    elsif setting == :one || at_least_one
      write_space
    end
  end

  def skip_space_or_newline_using_setting(setting, indent_size = @indent)
    indent(indent_size) do
      first_space = skip_space
      if newline? || comment?
        consume_end_of_line(want_multiline: false, first_space: first_space)
        write_indent
      else
        write_space_using_setting(first_space, setting)
      end
    end
  end

  def write_line
    @output << "\n"
    @last_was_newline = true
    @column = 0
    @line += 1
  end

  def write_indent(indent = @indent)
    @output << " " * indent
    @column += indent
  end

  def indent_after_space(node, sticky: false, want_space: true, first_space: nil, needed_indent: next_indent, token_column: nil, base_column: nil)
    first_space = current_token if space?
    skip_space

    case current_token_kind
    when :on_ignored_nl, :on_comment
      indent(needed_indent) do
        consume_end_of_line
      end

      if token_column && base_column && token_column == current_token_column
        # If the expression is aligned with the one above, keep it like that
        indent(base_column) do
          write_indent
          visit node
        end
      else
        indent(needed_indent) do
          write_indent
          visit node
        end
      end
    else
      if want_space
        write_space
      end
      if sticky
        indent(@column) do
          visit node
        end
      else
        visit node
      end
    end
  end

  def next_indent
    @indent + INDENT_SIZE
  end

  def check(kind)
    if current_token_kind != kind
      bug "Expected token #{kind}, not #{current_token_kind}"
    end
  end

  def bug(msg)
    raise Rufo::Bug.new("#{msg} at #{current_token}")
  end

  # [[1, 0], :on_int, "1"]
  def current_token
    @tokens.last
  end

  def current_token_kind
    tok = current_token
    tok ? tok[1] : :on_eof
  end

  def current_token_value
    tok = current_token
    tok ? tok[2] : ""
  end

  def current_token_line
    current_token[0][0]
  end

  def current_token_column
    current_token[0][1]
  end

  def keyword?(kw)
    current_token_kind == :on_kw && current_token_value == kw
  end

  def newline?
    current_token_kind == :on_nl || current_token_kind == :on_ignored_nl
  end

  def comment?
    current_token_kind == :on_comment
  end

  def semicolon?
    current_token_kind == :on_semicolon
  end

  def comma?
    current_token_kind == :on_comma
  end

  def space?
    current_token_kind == :on_sp
  end

  def void_exps?(node)
    node.size == 1 && node[0].size == 1 && node[0][0] == :void_stmt
  end

  def find_closing_brace_token
    count = 0
    i = @tokens.size - 1
    while i >= 0
      token = @tokens[i]
      (line, column), kind = token
      case kind
      when :on_lbrace, :on_tlambeg
        count += 1
      when :on_rbrace
        count -= 1
        return [token, i] if count == 0
      end
      i -= 1
    end
    nil
  end

  def newline_follows_token(index)
    index -= 1
    while index >= 0
      token = @tokens[index]
      case current_token_kind
      when :on_sp
        # OK
      when :on_nl, :on_ignored_nl
        return true
      else
        return false
      end
      index -= 1
    end
    true
  end

  def next_token
    prev_token = self.current_token

    @tokens.pop

    if (newline? || comment?) && !@heredocs.empty?
      if in_doc_mode?
        return
      end
      flush_heredocs
    end

    # First first token in newline if requested
    if @want_first_token_in_line && prev_token && (prev_token[1] == :on_nl || prev_token[1] == :on_ignored_nl)
      @tokens.reverse_each do |token|
        case token[1]
        when :on_sp
          next
        else
          @first_token_in_line = token
          break
        end
      end
    end
  end

  def next_token_no_heredoc_check
    @tokens.pop
  end

  def last?(i, array)
    i == array.size - 1
  end

  def to_ary(node)
    node[0].is_a?(Symbol) ? [node] : node
  end

  def dedent_calls
    return if @line_to_call_info.empty?

    lines = @output.lines

    while line_to_call_info = @line_to_call_info.shift
      first_line, call_info = line_to_call_info
      next unless call_info.size == 5

      indent, first_param_indent, needs_dedent, first_paren_end_line, last_line = call_info
      next unless needs_dedent
      next unless first_paren_end_line == last_line

      diff = first_param_indent - indent
      (first_line + 1..last_line).each do |line|
        @line_to_call_info.delete(line)

        next if @unmodifiable_string_lines[line]

        current_line = lines[line]
        current_line = current_line[diff..-1] if diff >= 0

        # It can happen that this line didn't need an indent because
        # it simply had a newline
        if current_line
          lines[line] = current_line
          adjust_other_alignments nil, line, 0, -diff
        end
      end
    end

    @output = lines.join
  end

  def indent_literals
    return if @literal_indents.empty?

    lines = @output.lines

    @literal_indents.each do |first_line, last_line, indent|
      (first_line + 1..last_line).each do |line|
        next if @unmodifiable_string_lines[line]

        current_line = lines[line]
        current_line = "#{" " * indent}#{current_line}"
        lines[line] = current_line
        adjust_other_alignments nil, line, 0, indent
      end
    end

    @output = lines.join
  end

  def do_align_case_when
    do_align @case_when_positions, :case
  end

  def do_align(elements, scope)
    lines = @output.lines

    # Chunk elements that are in consecutive lines
    chunks = chunk_while(elements) do |(l1, c1, i1, id1), (l2, c2, i2, id2)|
      l1 + 1 == l2 && i1 == i2 && id1 == id2
    end

    chunks.each do |elements|
      next if elements.size == 1

      max_column = elements.map { |l, c| c }.max

      elements.each do |(line, column, _, _, offset)|
        next if column == max_column

        split_index = column
        split_index -= offset if offset

        target_line = lines[line]

        before = target_line[0...split_index]
        after = target_line[split_index..-1]

        filler_size = max_column - column
        filler = " " * filler_size

        # Move all lines affected by the assignment shift
        if scope == :assign && (range = @assignments_ranges[line])
          (line + 1..range).each do |line_number|
            lines[line_number] = "#{filler}#{lines[line_number]}"

            # And move other elements too if applicable
            adjust_other_alignments scope, line_number, column, filler_size
          end
        end

        # Move comments to the right if a change happened
        if scope != :comment
          adjust_other_alignments scope, line, column, filler_size
        end

        lines[line] = "#{before}#{filler}#{after}"
      end
    end

    @output = lines.join
  end

  def adjust_other_alignments(scope, line, column, offset)
    adjustments = @line_to_alignments_positions[line]
    return unless adjustments

    adjustments.each do |key, adjustment_column, target, index|
      next if adjustment_column <= column
      next if scope == key

      target[index][1] += offset
    end
  end

  def chunk_while(array, &block)
    if array.respond_to?(:chunk_while)
      array.chunk_while(&block)
    else
      Rufo::Backport.chunk_while(array, &block)
    end
  end

  def broken_ripper_version?
    version, teeny = RUBY_VERSION[0..2], RUBY_VERSION[4..4].to_i
    (version == "2.3" && teeny < 5) ||
      (version == "2.4" && teeny < 2)
  end

  def remove_lines_before_inline_declarations
    return if @inline_declarations.empty?

    lines = @output.lines

    @inline_declarations.reverse.each_cons(2) do |(after, after_original), (before, before_original)|
      if before + 2 == after && before_original + 1 == after_original && lines[before + 1].strip.empty?
        lines.delete_at(before + 1)
      end
    end

    @output = lines.join
  end

  def result
    @output
  end
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# apply_promoted_ivar.rb
#
# Mechanical resolution of jsx_rosetta TODOs of the form:
#   # TODO: render condition references binding(s) promoted to @ivar — thread as controller-passed prop(s): NAME1, NAME2, ...
#
# These TODOs are reminders, not defects: the Ruby on the line(s) below
# them is already valid. They flag "the controller must pass these names
# as props." If every named prop already appears as a kwarg in the file's
# `def initialize`, the reminder is satisfied and the TODO can be deleted.
# Otherwise the script sharpens it to list only the names that are
# actually missing (or that are PascalCase imports needing different
# treatment).
#
# Always re-parses the post-edit file with `ruby -c`; on failure the file
# is reverted and reported as `parse_failed`.
#
# Usage:
#   apply_promoted_ivar.rb [--dry-run] [--quiet] <file_or_dir>...

require 'json'
require 'set'
require 'tempfile'
require 'optparse'

TODO_RE = /\A(\s*)# TODO: render condition references binding\(s\) promoted to @ivar — thread as controller-passed prop\(s\): (.+?)\s*\z/.freeze

# --- helpers ----------------------------------------------------------------

def camel_to_snake(s)
  s.gsub(/([a-z0-9])([A-Z])/) { "#{$1}_#{$2}" }.downcase
end

def pascal_case?(name) = /\A[A-Z]/.match?(name)

# Extract the kwarg names from the first `def initialize(...)` in src.
# Returns a Set of snake_case names. Returns an empty set if there's no
# initializer or if its arg list can't be parsed.
def initialize_kwargs(src)
  m = src.match(/def initialize\s*\(/m)
  return Set.new unless m

  start = m.end(0)
  depth = 1
  i = start
  while i < src.length && depth > 0
    case src[i]
    when '(' then depth += 1
    when ')' then depth -= 1
    end
    i += 1
  end
  return Set.new unless depth == 0

  args_str = src[start...(i - 1)]
  parse_kwarg_names(args_str).to_set
end

# Given an arg string like "status: nil, options: { a: 1 }, on_change: nil",
# return the kwarg names (top-level only — ignores nested-hash keys).
def parse_kwarg_names(s)
  names = []
  depth = 0
  buf = +''
  s.each_char do |c|
    case c
    when '(', '[', '{' then depth += 1; buf << c
    when ')', ']', '}' then depth -= 1; buf << c
    when ','
      if depth.zero?
        names << kwarg_head(buf)
        buf = +''
      else
        buf << c
      end
    else
      buf << c
    end
  end
  names << kwarg_head(buf) unless buf.strip.empty?
  names.compact
end

def kwarg_head(s)
  m = s.match(/\A\s*([a-z_][a-z0-9_]*)\s*:/)
  m && m[1]
end

# --- file processing --------------------------------------------------------

def process_file(path)
  src = File.read(path)
  init_set = initialize_kwargs(src)

  out = []
  resolved = 0
  sharpened = 0

  src.lines.each do |line|
    if (m = TODO_RE.match(line))
      indent = m[1]
      raw_names = m[2].split(',').map(&:strip).reject(&:empty?)

      missing_props = []
      missing_imports = []
      raw_names.each do |name|
        if pascal_case?(name)
          missing_imports << name
        else
          snake = camel_to_snake(name)
          missing_props << name unless init_set.include?(snake)
        end
      end

      if missing_props.empty? && missing_imports.empty?
        resolved += 1
        next
      end

      parts = []
      parts << "controller must pass #{missing_props.join(', ')} (not in def initialize)" if missing_props.any?
      parts << "external constant(s) #{missing_imports.join(', ')} need import or removal" if missing_imports.any?
      out << "#{indent}# TODO[promoted_ivar]: #{parts.join('; ')}.\n"
      sharpened += 1
    else
      out << line
    end
  end

  return { file: path, resolved: 0, sharpened: 0 } if resolved.zero? && sharpened.zero?

  new_content = out.join
  ok = Tempfile.create(['validate', '.rb']) do |tf|
    tf.write(new_content); tf.flush
    system('ruby', '-c', tf.path, out: File::NULL, err: File::NULL)
  end

  unless ok
    return { file: path, resolved: 0, sharpened: 0, parse_failed: true }
  end

  { file: path, resolved: resolved, sharpened: sharpened, new_content: new_content }
end

# --- CLI --------------------------------------------------------------------

opts = { dry_run: false, quiet: false }
OptionParser.new do |o|
  o.banner = "usage: apply_promoted_ivar.rb [--dry-run] [--quiet] <file_or_dir>..."
  o.on('--dry-run') { opts[:dry_run] = true }
  o.on('--quiet')   { opts[:quiet] = true }
end.parse!(ARGV)

abort "no input files" if ARGV.empty?

paths = ARGV.flat_map do |arg|
  if File.directory?(arg)
    Dir.glob(File.join(arg, '**', '*.rb'))
  elsif File.file?(arg)
    [arg]
  else
    warn "skip: #{arg}"; []
  end
end

totals = { files: paths.length, modified: 0, resolved: 0, sharpened: 0, parse_failed: 0 }
paths.each do |p|
  r = process_file(p)
  totals[:resolved]  += r[:resolved]
  totals[:sharpened] += r[:sharpened]

  if r[:parse_failed]
    totals[:parse_failed] += 1
    puts JSON.generate(file: p, parse_failed: true) unless opts[:quiet]
  elsif r[:new_content]
    totals[:modified] += 1
    File.write(p, r[:new_content]) unless opts[:dry_run]
    puts JSON.generate(file: p, resolved: r[:resolved], sharpened: r[:sharpened]) unless opts[:quiet]
  end
end

puts ''
puts "files scanned:    #{totals[:files]}"
puts "files modified:   #{totals[:modified]}#{opts[:dry_run] ? ' (dry-run)' : ''}"
puts "TODOs resolved:   #{totals[:resolved]}"
puts "TODOs sharpened:  #{totals[:sharpened]}"
puts "parse failures:   #{totals[:parse_failed]}"

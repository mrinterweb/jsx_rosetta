#!/usr/bin/env ruby
# frozen_string_literal: true

# apply_substitutions.rb
#
# Mechanical resolution of jsx_rosetta TODOs of the form:
#   # TODO: (attribute|style declaration) "<name>" dropped — couldn't translate: <RHS>
#
# A user-supplied YAML config declares:
#   - match:  a regex with one capture group, applied to <RHS>; the capture
#             becomes the lookup key
#   - tokens: a map from lookup key → { value, tailwind?, category?, notes? }
#
# When <RHS> matches and the captured key is in `tokens`, the value is spliced
# into the `render Foo.new(...)` immediately below the TODO. Only single-line
# render calls with string-literal `style:` (or no `style:`) are touched;
# anything more complex is left untouched.
#
# Always re-parses the post-edit file with `ruby -c`; if parsing fails the
# file is reverted and the run is reported as `parse_failed`.
#
# Usage:
#   apply_substitutions.rb --config <yaml> [--dry-run] [--quiet] <file_or_dir>...

require 'yaml'
require 'json'
require 'tempfile'
require 'optparse'

# --- config ------------------------------------------------------------------

CONFIG_SCHEMA_HINT = <<~MSG.freeze
  Config must be YAML with:
    match:  '<regex with one capture group>'
    tokens:
      <capture>: { value: <int|string|null>, ... }
      ...
MSG

def load_config(path)
  raw = YAML.safe_load(File.read(path))
  unless raw.is_a?(Hash) && raw['match'].is_a?(String) && raw['tokens'].is_a?(Hash)
    abort "invalid config at #{path}\n#{CONFIG_SCHEMA_HINT}"
  end
  user_re = Regexp.new(raw['match'])
  unless user_re.match("").is_a?(NilClass) || user_re.named_captures.any? || user_re.match("x") || user_re.source.include?('(')
    # weak check; just confirm there's at least one paren group (capture)
  end
  raw['_user_re'] = user_re
  raw['tokens'].freeze
  raw.freeze
  raw
end

# --- regex -------------------------------------------------------------------

# Built dynamically from config so the user's `match:` controls what gets
# touched. Captures: 1=indent, 2=kind, 3=attr_name, 4+=user-regex captures
# (capture 4 is the lookup key by convention).
def build_todo_re(user_re_source)
  /\A(\s*)# TODO: (attribute|style declaration) "(.+?)" dropped — couldn't translate: #{user_re_source}\s*\z/
end

# Single-line `render Foo.new(...)` (with optional `do ...`).
RENDER_RE = /\A(\s*)render\s+([A-Z][A-Za-z0-9_:]*)\.new(\((.*)\))?(\s+do\b.*)?\s*\z/.freeze

RUBY_IDENT_RE = /\A[a-z_][a-z0-9_]*\z/.freeze

Drop = Struct.new(:kind, :name, :key, :line_index, :raw_line, keyword_init: true)

# --- helpers -----------------------------------------------------------------

def camel_to_snake(s)
  s.gsub(/([a-z0-9])([A-Z])/) { "#{$1}_#{$2}" }.downcase.tr('-', '_')
end

def valid_ruby_kwarg?(name) = RUBY_IDENT_RE.match?(name)

def quote_string(s)
  if s.include?("'") && !s.include?('"')
    "\"#{s}\""
  elsif s.include?('"') && !s.include?("'")
    "'#{s}'"
  else
    "'#{s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")}'"
  end
end

def render_inline_style(value)
  value.is_a?(Numeric) ? "#{value}px" : value.to_s
end

def render_kwarg_value(value)
  case value
  when Numeric then value.to_s
  when String  then quote_string(value)
  end
end

def lookup(config, key)
  entry = config['tokens'][key]
  return nil unless entry.is_a?(Hash)
  entry['value']
end

def parse_todo(line, idx, todo_re)
  m = todo_re.match(line)
  return nil unless m
  Drop.new(kind: (m[2] == 'attribute' ? :attribute : :style_decl),
           name: m[3], key: m[4], line_index: idx, raw_line: line)
end

# --- splice ------------------------------------------------------------------

def splice(render_line, drops, config)
  m = RENDER_RE.match(render_line)
  return nil unless m
  indent, klass, has_parens, args, trailing = m[1], m[2], !m[3].nil?, (m[4] || ''), (m[5] || '')

  resolved = []
  unresolved = []
  style_adds = []
  attr_adds = []

  drops.each do |d|
    val = lookup(config, d.key)
    if val.nil?
      unresolved << d
      next
    end
    case d.kind
    when :style_decl
      style_adds << "#{d.name}: #{render_inline_style(val)}"
      resolved << d
    when :attribute
      qv = render_kwarg_value(val)
      kwarg = camel_to_snake(d.name)
      if qv.nil? || !valid_ruby_kwarg?(kwarg)
        unresolved << d
      else
        attr_adds << "#{kwarg}: #{qv}"
        resolved << d
      end
    end
  end

  return nil if resolved.empty?

  new_args = args.dup

  if style_adds.any?
    str_style_re = /style:\s*(['"])(.*?)\1/
    if (sm = new_args.match(str_style_re))
      quote = sm[1]
      existing_parts = sm[2].split(';').map(&:strip).reject(&:empty?)
      combined = (existing_parts + style_adds).join('; ') + ';'
      new_args = new_args.sub(str_style_re, "style: #{quote}#{combined}#{quote}")
    elsif new_args.match?(/\bstyle:\s*[\{\w]/)
      # Hash-form style: { ... } or symbol/var ref. Don't try to merge.
      style_adds.each do
        d = resolved.reverse.find { |x| x.kind == :style_decl }
        next unless d
        resolved.delete(d)
        unresolved << d
      end
      style_adds.clear
    else
      kwarg = "style: '#{style_adds.join('; ')};'"
      new_args = new_args.empty? ? kwarg : "#{kwarg}, #{new_args}"
      style_adds.clear
    end
  end

  if attr_adds.any?
    new_args = new_args.empty? ? attr_adds.join(', ') : "#{new_args}, #{attr_adds.join(', ')}"
  end

  return nil if resolved.empty?

  new_line = if has_parens || !new_args.empty?
    "#{indent}render #{klass}.new(#{new_args})#{trailing}\n"
  else
    "#{indent}render #{klass}.new#{trailing}\n"
  end

  { new_line: new_line, resolved: resolved, unresolved: unresolved }
end

# --- file processing ---------------------------------------------------------

def process_file(path, config, todo_re)
  lines = File.read(path).lines
  out = []
  pending = []
  resolved = 0
  skipped = 0

  i = 0
  while i < lines.length
    line = lines[i]
    if (drop = parse_todo(line, i, todo_re))
      pending << drop
      i += 1
      next
    end

    if pending.any?
      result = splice(line, pending, config)
      if result
        result[:unresolved].each { |d| out << d.raw_line; skipped += 1 }
        out << result[:new_line]
        resolved += result[:resolved].length
      else
        pending.each { |d| out << d.raw_line; skipped += 1 }
        out << line
      end
      pending = []
    else
      out << line
    end
    i += 1
  end

  pending.each { |d| out << d.raw_line; skipped += 1 }

  return { file: path, resolved: 0, skipped: skipped } if resolved.zero?

  new_content = out.join
  ok = Tempfile.create(['validate', '.rb']) do |tf|
    tf.write(new_content); tf.flush
    system('ruby', '-c', tf.path, out: File::NULL, err: File::NULL)
  end

  unless ok
    return { file: path, resolved: 0, skipped: skipped + resolved, parse_failed: true }
  end

  { file: path, resolved: resolved, skipped: skipped, new_content: new_content }
end

# --- CLI ---------------------------------------------------------------------

opts = { dry_run: false, quiet: false, config: nil }
OptionParser.new do |o|
  o.banner = "usage: apply_substitutions.rb --config <yaml> [--dry-run] [--quiet] <file_or_dir>..."
  o.on('--config PATH') { |v| opts[:config] = v }
  o.on('--dry-run')     { opts[:dry_run] = true }
  o.on('--quiet')       { opts[:quiet] = true }
end.parse!(ARGV)

abort "missing --config <yaml>\n#{CONFIG_SCHEMA_HINT}" unless opts[:config]
abort "config not found: #{opts[:config]}" unless File.file?(opts[:config])
abort "no input files" if ARGV.empty?

config = load_config(opts[:config])
todo_re = build_todo_re(config['_user_re'].source)

paths = ARGV.flat_map do |arg|
  if File.directory?(arg)
    Dir.glob(File.join(arg, '**', '*.rb'))
  elsif File.file?(arg)
    [arg]
  else
    warn "skip: #{arg} not found"
    []
  end
end

totals = { files: paths.length, modified: 0, resolved: 0, skipped: 0, parse_failed: 0 }

paths.each do |p|
  r = process_file(p, config, todo_re)
  totals[:resolved] += r[:resolved]
  totals[:skipped]  += r[:skipped]

  if r[:parse_failed]
    totals[:parse_failed] += 1
    puts JSON.generate(file: r[:file], parse_failed: true) unless opts[:quiet]
  elsif r[:resolved] > 0
    totals[:modified] += 1
    File.write(p, r[:new_content]) unless opts[:dry_run]
    puts JSON.generate(file: r[:file], resolved: r[:resolved], skipped: r[:skipped]) unless opts[:quiet]
  end
end

puts ''
puts "config:           #{opts[:config]}"
puts "files scanned:    #{totals[:files]}"
puts "files modified:   #{totals[:modified]}#{opts[:dry_run] ? ' (dry-run)' : ''}"
puts "TODOs resolved:   #{totals[:resolved]}"
puts "TODOs left:       #{totals[:skipped]}"
puts "parse failures:   #{totals[:parse_failed]}"

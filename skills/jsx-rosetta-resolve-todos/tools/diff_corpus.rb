#!/usr/bin/env ruby
# frozen_string_literal: true

# diff_corpus.rb
#
# Tally `# TODO:` comments by category in two directories (typically a
# "before" and "after" snapshot of generated output) and report the
# per-category delta. Lets the user see the impact of a resolve-todos
# pipeline pass and confirm the skill's claims aren't pure marketing.
#
# Usage:
#   diff_corpus.rb [--json] <before_dir> <after_dir>
#
# Categories match the SKILL.md routing table. Sharpened TODOs (those
# tagged `# TODO[category]:`) are counted separately so the delta shows
# both removal of original TODOs and creation of sharpened replacements.

require 'json'
require 'optparse'

# Original-form TODOs the gem emits. Order matters: more specific patterns
# first, generic last.
CATEGORIES = [
  # "chain_ref" = drops whose RHS starts with `<ident>.<ident>...` (token systems,
  # GraphQL field accesses, prop chains). `apply_substitutions.rb` resolves the
  # subset of these that match its configured token regex.
  [:chain_ref_drop,        /^\s*# TODO: (?:attribute|style declaration) ".+?" dropped — couldn't translate: \w+\.\w/],
  [:other_drop,            /^\s*# TODO: (?:attribute|style declaration) ".+?" dropped/],
  [:promoted_ivar,         /^\s*# TODO: render condition references binding\(s\) promoted to @ivar/],
  [:react_hooks,           /^\s*# TODO: React hooks detected/],
  [:apollo_hooks,          /^\s*# TODO: Apollo data-fetching hooks detected/],
  [:nextjs_navigation,     /^\s*# TODO: Next\.js navigation hooks detected/],
  [:event_handler,         /^\s*# TODO: translate the original JSX `\w+` handler/],
  [:module_constants,      /^\s*# TODO: module-level constants/],
  [:generic_js_bailout,    /^\s*# TODO: translate JS to Ruby — original/],
  [:generic_translate,     /^\s*# TODO: translate "/],
  [:generic_condition,     /^\s*# TODO: translate condition:/],
  [:other_todo,            /^\s*# TODO:/]
].freeze

# Sharpened TODOs emitted by recipes. Captured separately to show
# "compression" — original removed, sharpened added.
SHARPENED_RE = /^\s*# TODO\[([a-z_:-]+)\]:/.freeze

def tally(dir)
  counts = Hash.new(0)
  sharp_counts = Hash.new(0)
  todo_files = 0
  Dir.glob(File.join(dir, '**', '*.rb')).each do |path|
    file_had_todo = false
    File.foreach(path) do |line|
      if (m = SHARPENED_RE.match(line))
        sharp_counts[m[1].to_sym] += 1
        counts[:_sharpened_total] += 1
        file_had_todo = true
        next
      end
      CATEGORIES.each do |sym, re|
        if re.match?(line)
          counts[sym] += 1
          file_had_todo = true
          break
        end
      end
    end
    todo_files += 1 if file_had_todo
  end
  { categories: counts, sharpened: sharp_counts, files_with_todos: todo_files }
end

def fmt_delta(n)
  n.zero? ? '   .' : (n.positive? ? "+#{n}" : n.to_s).rjust(6)
end

def emit_text(before, after, before_dir, after_dir)
  cats = (before[:categories].keys + after[:categories].keys).uniq
  puts "before:  #{before_dir}"
  puts "after:   #{after_dir}"
  puts ""
  puts "                          before  after  delta"
  puts "  ─────────────────────────────────────────────"

  total_before = 0
  total_after = 0
  CATEGORIES.map(&:first).each do |sym|
    next unless cats.include?(sym)
    b = before[:categories][sym]
    a = after[:categories][sym]
    total_before += b
    total_after  += a
    next if b.zero? && a.zero?
    puts "  %-22s  %6d %6d  %s" % [sym, b, a, fmt_delta(a - b)]
  end

  # _sharpened_total is the synthetic total
  sb = before[:categories][:_sharpened_total]
  sa = after[:categories][:_sharpened_total]
  total_before += sb
  total_after  += sa
  if sb.positive? || sa.positive?
    puts "  %-22s  %6d %6d  %s" % ['sharpened (compressed)', sb, sa, fmt_delta(sa - sb)]
  end

  puts "  ─────────────────────────────────────────────"
  puts "  %-22s  %6d %6d  %s" % ['total', total_before, total_after, fmt_delta(total_after - total_before)]
  puts ""
  puts "  files with any TODO:    #{before[:files_with_todos]} → #{after[:files_with_todos]}"

  if (before[:sharpened].any? || after[:sharpened].any?)
    puts ""
    puts "  Sharpened-TODO breakdown by tag:"
    tags = (before[:sharpened].keys + after[:sharpened].keys).uniq.sort
    tags.each do |tag|
      b = before[:sharpened][tag]
      a = after[:sharpened][tag]
      puts "    %-22s  %6d %6d  %s" % [tag, b, a, fmt_delta(a - b)]
    end
  end
end

def emit_json(before, after, before_dir, after_dir)
  cats = (before[:categories].keys + after[:categories].keys).uniq.sort
  out = {
    before_dir: before_dir,
    after_dir: after_dir,
    files_with_todos: { before: before[:files_with_todos], after: after[:files_with_todos] },
    categories: cats.to_h { |sym|
      b = before[:categories][sym]
      a = after[:categories][sym]
      [sym, { before: b, after: a, delta: a - b }]
    },
    sharpened_by_tag: (before[:sharpened].keys + after[:sharpened].keys).uniq.sort.to_h { |tag|
      b = before[:sharpened][tag]
      a = after[:sharpened][tag]
      [tag, { before: b, after: a, delta: a - b }]
    }
  }
  puts JSON.pretty_generate(out)
end

# --- CLI ---

opts = { json: false }
OptionParser.new do |o|
  o.banner = "usage: diff_corpus.rb [--json] <before_dir> <after_dir>"
  o.on('--json') { opts[:json] = true }
end.parse!(ARGV)

abort "expected two directory arguments" unless ARGV.size == 2
before_dir, after_dir = ARGV
abort "not a directory: #{before_dir}" unless File.directory?(before_dir)
abort "not a directory: #{after_dir}" unless File.directory?(after_dir)

before = tally(before_dir)
after  = tally(after_dir)

if opts[:json]
  emit_json(before, after, before_dir, after_dir)
else
  emit_text(before, after, before_dir, after_dir)
end

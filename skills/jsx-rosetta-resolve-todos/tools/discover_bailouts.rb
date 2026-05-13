#!/usr/bin/env ruby
# frozen_string_literal: true

# discover_bailouts.rb
#
# Scan a corpus of jsx_rosetta-generated .rb files and surface the dropped-
# expression RHS values that show up most often. Used to:
#   - decide which substitutions are worth automating (apply_substitutions.rb)
#   - spot clusters that look like design-system tokens (e.g. many `theme.X`,
#     `vars.X`, `tokens.X.Y` references) and suggest a `match:` regex
#
# This tool makes no judgements about *what* a reference means — only what
# patterns repeat. Decisions about how to map them belong to the human (or to
# the LLM-driven recipes in the skill).
#
# Usage:
#   discover_bailouts.rb [--top N] [--json] [--all-todos] <file_or_dir>...
#
#   --top N        Show top N entries per section (default 25).
#   --json         Emit machine-readable JSON instead of text.
#   --all-todos    Also tally non-attribute/style TODO categories (hooks,
#                  module constants, generic JS bailouts) so you can see
#                  the full distribution. Off by default.

require 'json'
require 'optparse'

# Match a "dropped" TODO. Captures: kind, attr_name, RHS.
DROP_RE  = /\A\s*# TODO: (attribute|style declaration) "(.+?)" dropped — couldn't translate: (.+?)\s*\z/.freeze

# Other generic TODO categories — counted only when --all-todos is set.
OTHER_RE = /\A\s*# TODO: (.+?)\s*\z/.freeze

# Detect a "<root>.<member>" or "<root>.<member>.<member>..." chain at the
# start of an RHS. Captures: root, full chain.
CHAIN_RE = /\A(\$?\b[a-z_][A-Za-z0-9_]*)((?:\.[A-Za-z_][A-Za-z0-9_]*)+)/.freeze

# Detect a tagged template literal like `theme.colors.primary` inside backticks.
TPL_RE = /`[^`]*\$\{([^}]+)\}/.freeze

# --- collection --------------------------------------------------------------

def gather(paths)
  drops = []   # [{ kind:, attr:, rhs:, file:, line: }]
  others = Hash.new(0)

  paths.each do |p|
    File.foreach(p).with_index(1) do |line, lineno|
      if (m = DROP_RE.match(line))
        drops << { kind: m[1], attr: m[2], rhs: m[3], file: p, line: lineno }
      elsif (m = OTHER_RE.match(line))
        # Normalize generic TODOs by their leading phrase up to "—" or ":"
        head = m[1].split(/[—:]/).first.strip
        others[head] += 1
      end
    end
  end

  [drops, others]
end

# --- analysis ----------------------------------------------------------------

def chain_root(rhs)
  if (m = CHAIN_RE.match(rhs))
    m[1]
  end
end

def chain_full(rhs)
  if (m = CHAIN_RE.match(rhs))
    m[1] + m[2]
  end
end

def template_chains(rhs)
  rhs.scan(TPL_RE).flat_map { |(inner)| [chain_full(inner.strip)].compact }
end

# Group RHS strings by likely "system" — the root identifier of a member chain.
# Returns: { "token" => { count: N, distinct_keys: [...], sample_rhs: [...] }, ... }
def cluster_by_root(drops)
  clusters = Hash.new { |h, k| h[k] = { count: 0, keys: Hash.new(0), samples: [] } }

  drops.each do |d|
    rhs = d[:rhs]

    # Plain chain at start of RHS
    if (root = chain_root(rhs))
      key = chain_full(rhs)
      clusters[root][:count] += 1
      clusters[root][:keys][key] += 1
      clusters[root][:samples] << rhs if clusters[root][:samples].size < 5
    end

    # Chains inside template literals (e.g. `1px solid ${token.colorBorder}`)
    template_chains(rhs).each do |chain|
      root = chain.split('.').first
      clusters[root][:count] += 1
      clusters[root][:keys][chain] += 1
      clusters[root][:samples] << rhs if clusters[root][:samples].size < 5
    end
  end

  clusters
end

def suggest_regex(root, chains)
  # Look at the chain depths to pick `<root>\.(\w+)` vs `<root>\.\w+\.(\w+)` etc.
  depths = chains.keys.map { |c| c.split('.').size }
  depth = depths.tally.max_by { |_, n| n }.first
  esc_root = Regexp.escape(root)
  case depth
  when 2 then "#{esc_root}\\.(\\w+)"
  when 3 then "#{esc_root}\\.\\w+\\.(\\w+)"
  when 4 then "#{esc_root}\\.\\w+\\.\\w+\\.(\\w+)"
  else        "#{esc_root}((?:\\.\\w+)+)"
  end
end

# --- output ------------------------------------------------------------------

def emit_text(drops, others, clusters, top:, all_todos:)
  puts "=== Dropped expressions ==="
  puts "  total: #{drops.size}"
  by_kind = drops.group_by { |d| d[:kind] }.transform_values(&:count)
  by_kind.each { |k, n| puts "    #{k}: #{n}" }
  puts

  puts "=== Top #{top} dropped RHS values (verbatim) ==="
  drops.map { |d| d[:rhs] }.tally.sort_by { |_, n| -n }.first(top).each do |rhs, n|
    puts "  #{n.to_s.rjust(5)}  #{rhs.length > 90 ? rhs[0, 87] + '...' : rhs}"
  end
  puts

  puts "=== Repeating member chains (likely design-system / lookup tables) ==="
  if clusters.empty?
    puts "  (none)"
  else
    sorted = clusters.sort_by { |_, c| -c[:count] }
    sorted.first(top).each do |root, c|
      puts ""
      puts "  root: #{root}   total refs: #{c[:count]}   distinct keys: #{c[:keys].size}"
      puts "  suggested match regex:  '#{suggest_regex(root, c[:keys])}'"
      puts "  top keys:"
      c[:keys].sort_by { |_, n| -n }.first(8).each do |key, n|
        puts "    #{n.to_s.rjust(4)}  #{key}"
      end
    end
  end
  puts

  if all_todos
    puts "=== Other TODO categories (count by leading phrase) ==="
    others.sort_by { |_, n| -n }.first(top).each do |head, n|
      puts "  #{n.to_s.rjust(5)}  #{head}"
    end
  end
end

def emit_json(drops, others, clusters, all_todos:)
  out = {
    drops: {
      total: drops.size,
      by_kind: drops.group_by { |d| d[:kind] }.transform_values(&:count),
      top_rhs: drops.map { |d| d[:rhs] }.tally.sort_by { |_, n| -n }.first(50).to_h
    },
    chains: clusters.sort_by { |_, c| -c[:count] }.map { |root, c|
      [root, {
        count: c[:count],
        distinct_keys: c[:keys].size,
        suggested_match: suggest_regex(root, c[:keys]),
        top_keys: c[:keys].sort_by { |_, n| -n }.first(20).to_h
      }]
    }.to_h
  }
  out[:other_todos] = others.sort_by { |_, n| -n }.first(50).to_h if all_todos
  puts JSON.pretty_generate(out)
end

# --- CLI ---------------------------------------------------------------------

opts = { top: 25, json: false, all_todos: false }
OptionParser.new do |o|
  o.banner = "usage: discover_bailouts.rb [--top N] [--json] [--all-todos] <file_or_dir>..."
  o.on('--top N', Integer) { |v| opts[:top] = v }
  o.on('--json')           { opts[:json] = true }
  o.on('--all-todos')      { opts[:all_todos] = true }
end.parse!(ARGV)

abort "no input files" if ARGV.empty?

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

drops, others = gather(paths)
clusters = cluster_by_root(drops)

if opts[:json]
  emit_json(drops, others, clusters, all_todos: opts[:all_todos])
else
  emit_text(drops, others, clusters, top: opts[:top], all_todos: opts[:all_todos])
end

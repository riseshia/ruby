# Runs one benchmark script with several ruby builds and prints their numbers side by side.
# Usage: ruby compare_builds.rb SCRIPT [RUBY_OPTION...] -- LABEL=PATH...
script, *rest = ARGV
split = rest.index("--") or abort "usage: compare_builds.rb SCRIPT [RUBY_OPTION...] -- LABEL=PATH..."
options = rest[0...split]
builds = rest[(split + 1)..].map { _1.split("=", 2) }
NUMBERS = /((?:\s+(?:-?\d+\.\d+|-))+)\z/

columns = builds.map { |_label, path|
  IO.popen([path, "--disable-gems", *options, script], &:readlines).map(&:chomp).reject { _1.start_with?("op ") }
}
labels = columns.first.map { _1.sub(NUMBERS, "") }
width = labels.map(&:size).max
puts format("%-#{width}s  %s", "", builds.map { |label, _| label.rjust(24) }.join(" |"))
labels.each_index do |row|
  cells = columns.map { |lines| lines[row][NUMBERS, 1].to_s.strip.rjust(24) }
  puts format("%-#{width}s  %s", labels[row], cells.join(" |"))
end

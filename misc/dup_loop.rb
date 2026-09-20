# Tight dup loop for perf. Usage: ruby dup_loop.rb ary|hash|obj
class Point
  def initialize(x, y) = (@x = x; @y = y)
end
TARGETS = {"ary" => [1, 2, 3], "hash" => {a: 1}, "obj" => Point.new(1, 2)}.freeze

def run(target, n) = (i = 0; while i < n; target.dup; i += 1; end)

target = TARGETS.fetch(ARGV[0])
200.times { run(target, 1_000) }
run(target, 30_000_000)

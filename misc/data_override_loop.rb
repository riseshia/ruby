# Tight loop for perf: Data with an initialize written in Ruby. Usage: ruby [--yjit] override_loop.rb kw|pos
OD = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
eval "def run(n) = (i = 0; while i < n; #{ARGV[0] == 'pos' ? 'OD.new(1, 2)' : 'OD.new(x: 1, y: 2)'}; i += 1; end)"
w = 0; while w < 200; run(10); w += 1; end
run(15_000_000)

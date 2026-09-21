# Tight loop for perf: a Struct with an initialize written in Ruby. Usage: ruby [--yjit] struct_override_loop.rb kw|pos
OS = Struct.new(:x, :y) { def initialize(x, y = 0) = super(x, y) }
OSK = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y: 0) = super(x:, y:) }
eval "def run(n) = (i = 0; while i < n; #{ARGV[0] == 'pos' ? 'OS.new(1, 2)' : 'OSK.new(x: 1, y: 2)'}; i += 1; end)"
w = 0; while w < 200; run(10); w += 1; end
run(20_000_000)

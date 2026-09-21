# ns/op for `new` with the built-in initialize. Usage: ruby [--zjit] data_new_cells.rb CELL
class PlainPos
  attr_reader :x, :y
  def initialize(x, y) = (@x = x; @y = y)
end
D = Data.define(:x, :y)
S2 = Struct.new(:x, :y)
CELLS = { "class" => "PlainPos.new(i, 2)", "data_pos" => "D.new(i, 2)", "data_kw" => "D.new(x: i, y: 2)", "struct" => "S2.new(i, 2)", "data_with" => "D0.with(x: i)" }
D0 = D.new(0, 2)
expr = CELLS.fetch(ARGV.fetch(0))
eval "def run(n) = (i = 0; sum = 0; while i < n; o = #{expr}; sum += o.x + o.y; i += 1; end; sum)"
w = 0; while w < 300; run(20); w += 1; end
n = 10_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sum = run(n)
el = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
raise "bad sum" unless sum == n * (n - 1) / 2 + 2 * n
raise "not frozen" if ARGV[0].start_with?("data") && !eval(expr.sub(/\bi\b/, "1")).frozen?
printf "%-12s %6.1f ns\n", ARGV[0], el / n * 1e9

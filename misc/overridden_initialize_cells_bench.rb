# ns/op for `new` with an initialize written in Ruby. Usage: ruby [--yjit|--zjit] override_cells.rb CELL
# One cell per process; the result is used so that nothing can be optimized away.
class PlainKw
  attr_reader :x, :y
  def initialize(x:, y: 0) = (@x = x; @y = y)
end
class PlainPos
  attr_reader :x, :y
  def initialize(x, y = 0) = (@x = x; @y = y)
end
DataKw = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
DataZsuper = Data.define(:x, :y) { def initialize(x:, y: 0) = super }
StructPos = Struct.new(:x, :y) { def initialize(x, y = 0) = super(x, y) }
StructKw = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y: 0) = super(x:, y:) }

CELLS = {
  "class_kw" => "PlainKw.new(x: i, y: 2)",
  "class_pos" => "PlainPos.new(i, 2)",
  "data_kw" => "DataKw.new(x: i, y: 2)",
  "data_pos" => "DataKw.new(i, 2)",
  "data_zsuper" => "DataZsuper.new(x: i, y: 2)",
  "struct_pos" => "StructPos.new(i, 2)",
  "struct_kw" => "StructKw.new(x: i, y: 2)",
}
expr = CELLS.fetch(ARGV.fetch(0))
eval <<~RUBY
  def run(n)
    i = 0; sum = 0
    while i < n
      o = #{expr}
      sum += o.x + o.y
      i += 1
    end
    sum
  end
RUBY
w = 0; while w < 300; run(20); w += 1; end
n = 10_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sum = run(n)
el = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
raise "bad sum" unless sum == n * (n - 1) / 2 + 2 * n
printf "%-12s %6.1f ns\n", ARGV[0], el / n * 1e9

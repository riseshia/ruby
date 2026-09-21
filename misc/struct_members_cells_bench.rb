# ns/op for o.members. Usage: ruby [--yjit|--zjit] members_cells.rb class|struct|data
class Plain
  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def members = %i[x y z]
end
KLASS = { "class" => Plain, "struct" => Struct.new(:x, :y, :z), "data" => Data.define(:x, :y, :z) }.fetch(ARGV.fetch(0))
def run(o, n) = (i = 0; sum = 0; while i < n; sum += o.members.size; i += 1; end; sum)
o = KLASS.new(1, 2, 3)
w = 0; while w < 300; run(o, 20); w += 1; end
n = 10_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
raise "bad" unless run(o, n) == 3 * n
printf "%-7s %6.1f ns\n", ARGV[0], (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9

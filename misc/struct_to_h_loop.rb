# ns per to_h whose result is used. Usage: ruby [--zjit] to_h_loop.rb class|struct|data
class P; def initialize(x, y, z) = (@x = x; @y = y; @z = z); def to_h = {x: @x, y: @y, z: @z}; end
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y, :z)
O = {"class" => P, "struct" => S, "data" => D}.fetch(ARGV[0]).new(1, 2, 3)
def run(o, n) = (i = 0; t = 0; while i < n; t += o.to_h.size; i += 1; end; t)
w = 0; while w < 200; run(O, 10); w += 1; end
best = nil; r = 0
while r < 5
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond); run(O, 2_000_000); e = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t
  best = e if best.nil? || e < best; r += 1
end
puts format("%-7s %6.1f", ARGV[0], best.fdiv(2_000_000))

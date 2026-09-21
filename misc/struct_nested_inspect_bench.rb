# ns/op for inspect of a record holding two records. Usage: ruby [--yjit] nested_inspect.rb class|struct|data
class PInner; def initialize(a, b) = (@a = a; @b = b); def inspect = "#<struct PInner a=#{@a.inspect}, b=#{@b.inspect}>"; end
class POuter; def initialize(x, y, z) = (@x = x; @y = y; @z = z); def inspect = "#<struct POuter x=#{@x.inspect}, y=#{@y.inspect}, z=#{@z.inspect}>"; end
SInner = Struct.new(:a, :b); SOuter = Struct.new(:x, :y, :z); DInner = Data.define(:a, :b); DOuter = Data.define(:x, :y, :z)
inner, outer = { "class" => [PInner, POuter], "struct" => [SInner, SOuter], "data" => [DInner, DOuter] }.fetch(ARGV.fetch(0))
O = outer.new(inner.new(1, "two"), inner.new(:three, nil), 5)
def run(n) = (i = 0; r = 0; while i < n; r = O.inspect.size; i += 1; end; r)
w = 0; while w < 300; run(20); w += 1; end
n = 1_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC); run(n)
printf "%-7s %6.1f   %s\n", ARGV[0], (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9, O.inspect

# ns per inspect, one process per cell (see struct_new_matrix_bench.rb for why).
class P3
  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def inspect = "#<struct P3 x=#{@x.inspect}, y=#{@y.inspect}, z=#{@z.inspect}>"
end
S3 = Struct.new(:x, :y, :z); D3 = Data.define(:x, :y, :z)
S8 = Struct.new(*%i[a b c d e f g h])
CASES = {
  "class 3 ints" => "P3.new(12, 345, 67890)", "Struct 3 ints" => "S3.new(12, 345, 67890)", "Data 3 ints" => "D3.new(12, 345, 67890)",
  "class 3 strings" => 'P3.new("a", "bb", "ccc")', "Struct 3 strings" => 'S3.new("a", "bb", "ccc")',
  "Data int, string, symbol" => 'D3.new(1, "two", :three)',
  "Struct 8 mixed" => 'S8.new(1, "b", :c, nil, true, 2.5, [1], {k: 1})',
  "Struct nested" => "S3.new(S3.new(12, 345, 67890), nil, nil)",
  "Array 3 ints" => "[12, 345, 67890]",
}
if ARGV[0] == "--cell"
  OBJ = eval(CASES.values[ARGV[1].to_i])
  eval <<~CELL
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    def run(o, n) = (i = 0; while i < n; o.inspect; i += 1; end)
    w = 0; while w < 200; run(OBJ, 10); w += 1; end
    best = nil; r = 0
    while r < 5
      t = now; run(OBJ, 300_000); e = now - t; best = e if best.nil? || e < best
      r += 1
    end
    puts best.fdiv(300_000)
  CELL
  exit
end
jit = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? then ["--yjit"] elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit"] else [] end
ruby = ENV.fetch("BENCH_RUBY")
CASES.each_key.with_index do |label, idx|
  ns = IO.popen([ruby, "--disable-gems", *jit, __FILE__, "--cell", idx.to_s], err: File::NULL, &:read).to_f
  puts format("%-28s %8.1f", label, ns)
end

# ns per operation, one process per cell: element access and small conversions.
class C
  attr_accessor :x, :y, :z
  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def [](key) = key == :x ? @x : key == :y ? @y : @z
  def []=(key, value)
    if key == :x then @x = value elsif key == :y then @y = value else @z = value end
  end
  def size = 3
  def to_a = [@x, @y, @z]
  def members = %i[x y z]
  def to_h = {x: @x, y: @y, z: @z}
end
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y, :z)
KLASSES = [C, S, D]
CASES = { "o[:y]" => "o[:y]", "o[:y] = 2" => "o[:y] = 2", "o[1]" => "o[1]", "o.size" => "o.size", "o.to_a.size" => "o.to_a.size", "o.members.size" => "o.members.size", "o.to_h.size" => "o.to_h.size" }
DATA_OK = ["o.members.size", "o.to_h.size"]
if ARGV[0] == "--cell"
  code = CASES.values[ARGV[1].to_i]; col = ARGV[2].to_i
  exit if col == 2 && !DATA_OK.include?(code)
  exit if col == 0 && code == "o[1]"
  O = KLASSES[col].new(1, 2, 3)
  eval <<~CELL
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    def run(o, n) = (i = 0; while i < n; #{code}; i += 1; end)
    def empty(o, n) = (i = 0; while i < n; i += 1; end)
    w = 0; while w < 200; run(O, 10); empty(O, 10); w += 1; end
    best = nil; base = nil; r = 0
    while r < 5
      t = now; empty(O, 3_000_000); e = now - t; base = e if base.nil? || e < base
      t = now; run(O, 3_000_000); e = now - t; best = e if best.nil? || e < best
      r += 1
    end
    puts (best - base).fdiv(3_000_000)
  CELL
  exit
end
jit = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? then ["--yjit"] elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit"] else [] end
ruby = ENV.fetch("BENCH_RUBY")
puts format("%-18s %7s %7s %7s", "", "class", "Struct", "Data")
CASES.each_key.with_index do |label, row|
  cells = (0..2).map { |col| out = IO.popen([ruby, "--disable-gems", *jit, __FILE__, "--cell", row.to_s, col.to_s], err: File::NULL, &:read); out.empty? ? nil : out.to_f }
  puts format("%-18s %s", label, cells.map { _1 ? format("%7.1f", _1) : format("%7s", "-") }.join(" "))
end

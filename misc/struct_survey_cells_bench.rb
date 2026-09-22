# ns/op survey of the remaining Struct / Data operations against a hand-written class.
# Usage: ruby [--yjit|--zjit] survey_cells.rb OP class|struct|data   (one process per cell)
class Plain
  attr_reader :x, :y, :z
  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def each = (yield @x; yield @y; yield @z; self)
  def each_pair = (yield :x, @x; yield :y, @y; yield :z, @z; self)
  def values_at(*idx) = idx.map { [@x, @y, @z][_1] }
  def dig(k, *rest) = (v = public_send(k); rest.empty? ? v : v.dig(*rest))
  def to_a = [@x, @y, @z]
  def hash = [@x, @y, @z].hash
  def inspect = "#<struct Plain x=#{@x.inspect}, y=#{@y.inspect}, z=#{@z.inspect}>"
  def with(**kw) = self.class.new(kw.fetch(:x, @x), kw.fetch(:y, @y), kw.fetch(:z, @z))
end
class SubS < Struct.new(:x, :y, :z); end
class SubD < Data.define(:x, :y, :z); end
class SubSub < SubS; end
KLASS = { "class" => Plain, "struct" => Struct.new(:x, :y, :z), "data" => Data.define(:x, :y, :z), "substruct" => SubS, "subdata" => SubD, "subsub" => SubSub, "kwstruct" => Struct.new(:x, :y, :z, keyword_init: true), "kwsub" => Class.new(Struct.new(:x, :y, :z, keyword_init: true)) }.fetch(ARGV.fetch(1))
OPS = {
  "dup" => "o.dup.x", "clone" => "o.clone.x", "inspect" => "o.inspect.size", "to_s" => "o.to_s.size",
  "each" => "t = 0; o.each { |v| t += v }; t", "each_pair" => "t = 0; o.each_pair { |k, v| t += v }; t",
  "values_at" => "o.values_at(0, 2).size", "dig" => "o.dig(:x)", "sum_to_a" => "o.to_a.sum", "hash" => "o.hash",
  "frozen?" => "o.frozen? ? 1 : 2", "respond_to" => "o.respond_to?(:x) ? 1 : 2", "reader" => "o.x + o.y + o.z",
  "eq_self" => "o == o ? 1 : 2", "new_with_hash" => "KLASS.new(**H).x", "members_size" => "o.members.size", "new_splat" => "KLASS.new(*A).x", "with_hash" => "o.with(**W).y", "with_lit" => "o.with(y: 5).y", "new_lit_kw" => "KLASS.new(x: 1, y: 2, z: 3).x", "new_pos" => "KLASS.new(1, 2, 3).x", "marshal_rt" => "Marshal.load(Marshal.dump(o)).x", "setter" => "o.x = i", "eq_other" => "o == O2 ? 1 : 2", "hkey" => "HK[o]", "eql_other" => "o.eql?(O2) ? 1 : 2", "pm_arr" => "case o; in [a, b, c] then a; end", "pm_hash" => "case o; in {x:, y:} then x; end", "aref_sym" => "o[:x]", "aref_int" => "o[1]", "aset_sym" => "o[:x] = i", "values" => "o.values.size", "to_h" => "o.to_h.size", "to_h_blk" => "o.to_h { |k, v| [k, v] }.size", "size" => "o.size", "marshal_dump" => "Marshal.dump(o).size", "marshal_load" => "Marshal.load(MD).class", "aref_str" => "o[\"x\"]", "map" => "o.map { |v| v }.size", "sum" => "o.sum", "include" => "o.include?(3) ? 1 : 2", "min" => "o.min", "each_wi" => "t = 0; o.each_with_index { |v, i| t += v }; t", "select" => "o.select { |v| v > 1 }.size", "hash_to_h_blk" => "H.to_h { |k, v| [k, v] }.size", "to_h_blk2" => "o.to_h { |k, v| [v, k] }.size", "each_sum" => "o.each.sum", "to_a_each" => "t = 0; o.to_a.each { |v| t += v }; t", "eq_diff" => "o == O3 ? 1 : 2",
}
H = { x: 1, y: 2, z: 3 }
A = [1, 2, 3]
W = { y: 5 }
class Plain; attr_writer :x; def ==(o) = o.class == self.class && o.x == @x && o.y == @y && o.z == @z; alias eql? ==; def deconstruct = [@x, @y, @z]; def deconstruct_keys(k) = { x: @x, y: @y, z: @z }; def [](k) = k.is_a?(Integer) ? [@x, @y, @z][k] : public_send(k); def []=(k, v); public_send(:"#{k}=", v); end; def values = [@x, @y, @z]; def to_h(&b) = b ? { x: @x, y: @y, z: @z }.to_h(&b) : { x: @x, y: @y, z: @z }; def size = 3; end
KW = KLASS.respond_to?(:keyword_init?) && KLASS.keyword_init? ? true : false
O2 = KW ? KLASS.new(x: 1, y: 2, z: 3) : KLASS.new(1, 2, 3)
O3 = KW ? KLASS.new(x: 1, y: 2, z: 4) : KLASS.new(1, 2, 4)
MD = Marshal.dump(KLASS.name ? O2 : 1)
HK = { O2 => 1 }
op = OPS.fetch(ARGV.fetch(0))
eval "def run(o, n) = (i = 0; r = 0; while i < n; r = (#{op}); i += 1; end; r)"
o = KW ? KLASS.new(x: 1, y: 2, z: 3) : KLASS.new(1, 2, 3)
begin; run(o, 1); rescue NoMethodError, ArgumentError, TypeError; puts format("%-14s %-7s      -", ARGV[0], ARGV[1]); exit; end
w = 0; while w < 300; run(o, 20); w += 1; end
n = 3_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC); run(o, n)
printf "%-14s %-7s %6.1f\n", ARGV[0], ARGV[1], (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9

# Every Struct / Data instance operation next to a hand-written class doing the same job.
# Usage: ruby [--yjit] struct_scope_sweep.rb   (sorted by how much slower Struct is than the class)
class Plain
  attr_accessor :x, :y, :z

  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def to_a = [@x, @y, @z]
  def to_h = {x: @x, y: @y, z: @z}
  def members = %i[x y z]
  def each = (yield @x; yield @y; yield @z; self)
  def each_pair = (yield :x, @x; yield :y, @y; yield :z, @z; self)
  def values_at(*indexes) = to_a.values_at(*indexes)
  def [](key) = key == :x ? @x : key == :y ? @y : @z
  def []=(key, value)
    if key == :x then @x = value elsif key == :y then @y = value else @z = value end
  end
  def ==(other) = other.class == self.class && @x == other.x && @y == other.y && @z == other.z
  def eql?(other) = other.class == self.class && @x.eql?(other.x) && @y.eql?(other.y) && @z.eql?(other.z)
  def hash = [self.class, @x, @y, @z].hash
  def inspect = "#<struct Plain x=#{@x.inspect}, y=#{@y.inspect}, z=#{@z.inspect}>"
  def deconstruct = to_a
  def deconstruct_keys(_keys) = to_h
  def with(x: @x, y: @y, z: @z) = self.class.new(x, y, z)
  def size = 3
  def select = to_a.select { |v| yield v }
  def dig(key, *rest) = rest.empty? ? self[key] : self[key].dig(*rest)
end

S3 = Struct.new(:x, :y, :z)
D3 = Data.define(:x, :y, :z)

CASES = {
  "new(1, 2, 3)" => "K.new(1, 2, 3)",
  "reader" => "o.y",
  "writer" => "o.y = 2",
  "o[:y]" => "o[:y]",
  "o[:y] = 2" => "o[:y] = 2",
  "o[1]" => "o[1]",
  "to_a" => "o.to_a",
  "to_h" => "o.to_h",
  "members" => "o.members",
  "size" => "o.size",
  "each { }" => "o.each { |v| v }",
  "each_pair { }" => "o.each_pair { |k, v| v }",
  "values_at(0, 2)" => "o.values_at(0, 2)",
  "select { }" => "o.select { |v| v == 2 }",
  "dig(:y)" => "o.dig(:y)",
  "== (equal)" => "o == same",
  "== (different)" => "o == other",
  "eql?" => "o.eql?(same)",
  "hash" => "o.hash",
  "as Hash key" => "table[o]",
  "inspect" => "o.inspect",
  "dup" => "o.dup",
  "clone" => "o.clone",
  "freeze (fresh)" => "K.new(1, 2, 3).freeze",
  "frozen?" => "o.frozen?",
  "in [x, y, z]" => "case o; in [x, y, z] then x; end",
  "in {x:, y:}" => "case o; in {x:, y:} then x; end",
  "with(y: 5)" => "o.with(y: 5)",
  "Marshal round trip" => "Marshal.load(Marshal.dump(o))",
  "to_a.sum via Enumerable#sum" => "o.to_a.sum",
}.freeze
SKIP = {"Data" => ["writer", "o[:y] = 2", "o[:y]", "o[1]", "to_a", "size", "each { }", "each_pair { }", "values_at(0, 2)", "select { }", "dig(:y)", "in [x, y, z]", "to_a.sum via Enumerable#sum"],
        "Struct" => ["with(y: 5)"]}.freeze
KLASSES = {"class" => Plain, "Struct" => S3, "Data" => D3}.freeze
ITERATIONS = 1_000_000
ROUNDS = 3

def define_case(name, expr, klass_name)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(o, same, other, table, n)
      k = 0
      while k < n
        #{expr.gsub(/\bK\b/, klass_name)}
        k += 1
      end
    end

    def measure_#{name}(*args)
      200.times { run_#{name}(*args, 500) }
      ROUNDS.times.map {
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(*args, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

Object.const_set(:PlainK, Plain)
rows = CASES.each_with_index.map { |(label, expr), idx|
  cells = KLASSES.map { |kind, klass|
    next nil if SKIP.fetch(kind, []).include?(label) || (kind == "Data" && !klass.method_defined?(expr[/o\.(\w+[?!]?)/, 1] || :x) && expr.include?("o."))
    args = [klass.new(1, 2, 3), klass.new(1, 2, 3), klass.new(1, 2, 4)]
    args << {args[1] => 1}
    define_case(:"c#{idx}_#{kind}", expr, klass.name)
    send(:"measure_c#{idx}_#{kind}", *args)
  }
  [label, *cells]
}
puts format("%-30s %8s %8s %8s %10s", "operation", "class", "Struct", "Data", "Struct-cls")
rows.sort_by { |_, plain, struct, _| -((struct || 0) - plain) }.each { |label, plain, struct, data|
  puts format("%-30s %8.1f %8s %8s %10s", label, plain, struct ? format("%.1f", struct) : "-", data ? format("%.1f", data) : "-", struct ? format("%+.1f", struct - plain) : "-")
}

# Prints everything a Ruby program can observe about constructing Struct / Data instances.
# Run it with a baseline build and a patched build: the two outputs must be identical.
#
#   ./ruby misc/struct_new_observable_probe.rb > probe.txt

require "objspace"

Point = Struct.new(:x, :y)
KeywordPoint = Struct.new(:x, :y, keyword_init: true)
PositionalPoint = Struct.new(:x, :y, keyword_init: false)
Wide = Struct.new(*(1..200).map { :"m#{_1}" })
Coord = Data.define(:x, :y)

class TracedPoint < Struct.new(:x, :y)
  def initialize(*args)
    puts "    caller labels: #{caller_locations(0, 4).map(&:label).inspect}"
    super
  end
end

class TracedCoord < Data.define(:x, :y)
  def initialize(**kwargs)
    puts "    caller labels: #{caller_locations(0, 4).map(&:label).inspect}"
    super
  end
end

def section(title)
  puts "\n== #{title}"
end

def report(label)
  value = yield
  puts "  #{label}: #{value.inspect} frozen=#{value.frozen?}"
rescue => error
  puts "  #{label}: #{error.class}: #{error.message}"
  puts "    backtrace labels: #{error.backtrace_locations.first(4).map(&:label).inspect}"
end

def trace_events(label)
  events = []
  tracer = TracePoint.new(:c_call, :c_return, :call, :return, :raise) { |tp|
    events << "#{tp.event} #{tp.defined_class.inspect}##{tp.method_id}"
  }
  begin
    tracer.enable { yield }
  rescue => error
    events << "rescued #{error.class}"
  end
  puts "  #{label}:"
  events.each { puts "    #{_1}" }
end

def allocation_info(label)
  object = nil
  ObjectSpace.trace_object_allocations { object = yield }
  puts "  #{label}: method=#{ObjectSpace.allocation_method_id(object).inspect} " \
       "class_path=#{ObjectSpace.allocation_class_path(object).inspect} " \
       "file=#{File.basename(ObjectSpace.allocation_sourcefile(object).to_s)}"
end

section "results"
report("Point.new(1, 2)") { Point.new(1, 2) }
report("Point.new(1)") { Point.new(1) }
report("Point.new") { Point.new }
report("Point[1, 2]") { Point[1, 2] }
report("Point.new({x: 1})") { Point.new({x: 1}) }
report("Point.new(x: 1)") { Point.new(x: 1) }
report("Point.new({x: 1}, 2)") { Point.new({x: 1}, 2) }
report("KeywordPoint.new(x: 1, y: 2)") { KeywordPoint.new(x: 1, y: 2) }
report("PositionalPoint.new(x: 1)") { PositionalPoint.new(x: 1) }
report("Wide.new(1, 2)") { Wide.new(1, 2).to_a.first(3) }
report("Coord.new(1, 2)") { Coord.new(1, 2) }
report("Coord.new(x: 1, y: 2)") { Coord.new(x: 1, y: 2) }
report("Coord[1, 2]") { Coord[1, 2] }

section "errors"
report("Point.new(1, 2, 3)") { Point.new(1, 2, 3) }
report("KeywordPoint.new(1, 2)") { KeywordPoint.new(1, 2) }
report("KeywordPoint.new(1)") { KeywordPoint.new(1) }
report("KeywordPoint.new(z: 1)") { KeywordPoint.new(z: 1) }
report("Point.new(z: 1)") { Point.new(z: 1) }
report("Wide.new(*1..201)") { Wide.new(*1..201) }
report("Coord.new(1)") { Coord.new(1) }
report("Coord.new(1, 2, 3)") { Coord.new(1, 2, 3) }
report("Coord.new(x: 1, z: 2)") { Coord.new(x: 1, z: 2) }
report("Coord.new(1, y: 2)") { Coord.new(1, y: 2) }

section "keyword_init through subclasses, copies and the C API"
report("Class.new(KeywordPoint).new(1, 2)") { Class.new(KeywordPoint).new(1, 2) }
report("Class.new(KeywordPoint).new(x: 1)") { Class.new(KeywordPoint).new(x: 1).to_a }
report("Class.new(Point).new(1, 2)") { Class.new(Point).new(1, 2).to_a }
report("KeywordPoint.dup.new(1, 2)") { KeywordPoint.dup.new(1, 2) }
report("KeywordPoint.dup.new(x: 1)") { KeywordPoint.dup.new(x: 1).to_a }
report("KeywordPoint.clone.new(1)") { KeywordPoint.clone.new(1) }
report("keyword_init: 1, positional") { Struct.new(:a, keyword_init: 1).new(1) }
report("keyword_init: 1, keyword") { Struct.new(:a, keyword_init: 1).new(a: 1).to_a }
report("keyword_init: nil, positional") { Struct.new(:a, keyword_init: nil).new(1).to_a }
report("PositionalPoint.new({x: 1})") { PositionalPoint.new({x: 1}).to_a }
report("Process::Tms.new(1, 2, 3, 4)") { Process::Tms.new(1, 2, 3, 4).to_a }
report("Process::Tms.new(utime: 1)") { Process::Tms.new(utime: 1).to_a }
report("KeywordPoint.allocate") { KeywordPoint.allocate.to_a }
report("keyword_init? values") { [Point, KeywordPoint, PositionalPoint, Class.new(KeywordPoint), KeywordPoint.dup].map(&:keyword_init?) }
report("initialize owner") { [Point, KeywordPoint].map { _1.instance_method(:initialize).owner } }

section "Data keyword edge cases"
BigCoord = Data.define(*(1..12).map { :"m#{_1}" })
Empty = Data.define
StringLike = Struct.new(:to_str)
report("string keys") { Coord.new("x" => 1, "y" => 2) }
report("symbol and string for one member") { Coord.new(:x => 1, "x" => 2, :y => 3) }
report("same member twice, other missing") { Coord.new(:x => 1, "x" => 2) }
report("integer key") { Coord.new(0 => 1, 1 => 2) }
report("to_str key") { Coord.new(StringLike.new("x") => 1, y: 2) }
report("nil key") { Coord.new(nil => 1) }
report("missing first") { Coord.new(y: 2) }
report("missing both") { Coord.new(**{}) }
report("unknown and missing") { Coord.new(z: 1) }
report("two unknown") { Coord.new(x: 1, y: 2, z: 3, w: 4) }
report("explicit nil member") { Coord.new(x: nil, y: nil) }
report("BigCoord positional") { BigCoord.new(*1..12).to_h.values.sum }
report("BigCoord missing order") { BigCoord.new(m12: 1, m3: 1, m7: 1) }
report("BigCoord unknown") { BigCoord.new(**(1..12).to_h { [:"m#{_1}", _1] }, nope: 1) }
report("Empty.new") { Empty.new }
report("Empty.new(x: 1)") { Empty.new(x: 1) }
report("Struct keyword_init string and integer keys") { KeywordPoint.new("x" => 1, 1 => 2) }
report("Struct keyword_init unknown") { KeywordPoint.new(x: 1, "nope" => 2, 5 => 3) }
report("Coord with") { Coord.new(1, 2).with(y: 5) }
report("Coord with unknown") { Coord.new(1, 2).with(z: 5) }

section "Data.new call shapes"
WideCoord = Data.define(*(1..17).map { :"w#{_1}" })
report("keywords in another order") { Coord.new(y: 2, x: 1) }
report("Coord[x: 1, y: 2]") { Coord[x: 1, y: 2] }
report("BigCoord keywords") { BigCoord.new(**(1..12).to_h { [:"m#{_1}", _1] }).m12 }
report("BigCoord literal keywords") { BigCoord.new(m12: 12, m11: 11, m10: 10, m9: 9, m8: 8, m7: 7, m6: 6, m5: 5, m4: 4, m3: 3, m2: 2, m1: 1).to_h.values }
report("WideCoord positional") { WideCoord.new(*1..17).w17 }
report("WideCoord literal positional") { WideCoord.new(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17).w17 }
report("send(:new)") { Coord.send(:new, 1, 2) }
report("method(:new).call") { Coord.method(:new).call(x: 1, y: 2) }
report("block argument") { Coord.new(1, 2, &:itself) }
report("splat") { Coord.new(*[1, 2]) }
report("double splat") { Coord.new(**{x: 1, y: 2}) }
report("positional hash") { Coord.new({x: 1, y: 2}) }
report("self.new overridden") { Class.new(Coord) { def self.new(*args) = super(*args.reverse) }.new(1, 2) }
report("Data.new owner / arity") { [Coord.method(:new).owner == Coord.singleton_class, Coord.method(:new).arity, Coord.method(:new).parameters] }
report("object count after 1000 failures") do
  1000.times { Coord.new(x: 1) rescue nil }
  GC.start
  ObjectSpace.each_object(Coord).count { !_1.frozen? }
end

section "Data#with"
report("with two members") { Coord.new(1, 2).with(y: 5, x: 4) }
report("with nothing") { c = Coord.new(1, 2); c.with.equal?(c) }
report("with string key") { Coord.new(1, 2).with("y" => 5) }
report("with same member twice") { Coord.new(1, 2).with(:y => 5, "y" => 6) }
report("with unknown") { Coord.new(1, 2).with(y: 5, z: 6) }
report("with positional") { Coord.new(1, 2).with(1) }
report("with on overridden initialize") { TracedCoord.new(1, 2).with(y: 5) }
report("with does not copy ivars") { c = Coord.new(1, 2); c2 = c.with(y: 3); [c2, c2.instance_variables] }
report("with keeps singleton-less class") { Class.new(Coord).new(1, 2).with(x: 9).class.superclass }
trace_events("with traced") { Coord.new(1, 2).with(y: 5) }
allocation_info("with allocation") { Coord.new(1, 2).with(y: 5) }
report("BigCoord with") { BigCoord.new(*1..12).with(m12: 0, m1: 0).to_h.values }

section "to_h"
report("Struct#to_h") { Point.new(1, 2).to_h }
report("Data#to_h") { Coord.new(1, 2).to_h }
report("to_h with block") { Point.new(1, 2).to_h { |k, v| [k.to_s, v * 2] } }
report("to_h block returning a non-pair") { Point.new(1, 2).to_h { |k, v| k } }
report("to_h of 12 members keeps order") { BigCoord.new(*1..12).to_h.keys }
report("to_h of 200 members") { h = Wide.new(*1..200).to_h; [h.size, h.keys.first, h.keys.last, h[:m200]] }
report("to_h result is a plain mutable Hash") { h = Coord.new(1, 2).to_h; h[:z] = 3; [h, h.frozen?, h.compare_by_identity?, h.default] }
report("deconstruct_keys") { [Point.new(1, 2).deconstruct_keys([:x]), Coord.new(1, 2).deconstruct_keys(nil)] }

section "Data.new reaching an overridden initialize"
NeedsX = Data.define(:x, :y) { def initialize(x:) = super(x:, y: nil) }
TakesHash = Data.define(:x, :y) { def initialize(given) = super(**given) }
TakesRest = Data.define(:x, :y) { def initialize(*args, **kw) = (puts "    args=#{args.inspect} kw=#{kw.inspect}"; super(**kw)) }
Yields = Data.define(:x, :y) { def initialize(x:, y:) = (puts "    block_given=#{block_given?}"; super) }
Validates = Data.define(:x, :y) { def initialize(x:, y:) = (raise ArgumentError, "x must be positive" unless x.positive?; super) }
report("unknown keyword for initialize, positional") { NeedsX.new(1, 2) }
report("unknown keyword for initialize, keywords") { NeedsX.new(x: 1, y: 2) }
report("accepted subset") { NeedsX.new(1) }
report("missing keyword for initialize") { NeedsX.new }
report("initialize taking a positional Hash, positional") { TakesHash.new(1, 2) }
report("initialize taking a positional Hash, keywords") { TakesHash.new(x: 1, y: 2) }
report("initialize taking rest, positional") { TakesRest.new(1, 2) }
report("initialize taking rest, keywords") { TakesRest.new(y: 2, x: 1) }
report("block reaches initialize, positional") { Yields.new(1, 2) { } }
report("block reaches initialize, keywords") { Yields.new(x: 1, y: 2) { } }
report("raise from initialize, positional") { Validates.new(-1, 2) }
report("raise from initialize, keywords") { Validates.new(x: -1, y: 2) }
report("too many positional") { Validates.new(1, 2, 3) }
trace_events("overridden initialize traced") { Validates.new(1, 2) }
allocation_info("overridden initialize allocation, positional") { Validates.new(1, 2) }
allocation_info("overridden initialize allocation, keywords") { Validates.new(x: 1, y: 2) }

section "inspect"
Odd = Struct.new(:"a b", :Const, :_under, :"é")
report("named struct") { [Point.new(1, "two").inspect, Point.new(1, 2).to_s] }
report("anonymous struct and data") { [Struct.new(:a).new(1).inspect, Data.define(:a).new(1).inspect] }
report("member names that need quoting") { Odd.new(1, 2, 3, 4).inspect }
report("nested") { Point.new(Coord.new(1, [2, {k: Point.new(nil, :sym)}]), 2.5).inspect }
report("recursive") { s = Point.new(1, nil); s.y = s; [s.inspect, Struct.new(:me).new.tap { _1.me = _1 }.inspect.gsub(/0x\h+/, "0x…")] }
report("recursive through an Array") { s = Point.new(1, []); s.y << s; s.inspect }
report("encodings") { [Point.new("é", "\xff".b).inspect, Point.new("é".encode("UTF-16LE"), 1).inspect.encoding] }
report("many members") { s = BigCoord.new(*1..12).inspect; [s.size, s[0, 30], s[-12..]] }
report("200 members") { s = Wide.new(*1..200).inspect; [s.size, s[-20..]] }
report("member with its own inspect") { o = Object.new; def o.inspect = "<custom>"; Point.new(o, o).inspect }
report("result is a new unfrozen String") { a = Point.new(1, 2); [a.inspect.frozen?, a.inspect.equal?(a.inspect), a.inspect.encoding] }

section "initialize called again"
report("unfrozen struct, fewer args") { Point.new(1, 2).tap { _1.send(:initialize, 9) } }
report("unfrozen struct, no args") { Point.new(1, 2).tap { _1.send(:initialize) } }
report("frozen struct") { Point.new(1, 2).freeze.send(:initialize, 9) }
report("data") { Coord.new(1, 2).send(:initialize, x: 9, y: 9) }

section "overridden initialize"
report("TracedPoint.new(1, 2)") { TracedPoint.new(1, 2) }
report("TracedPoint.new(1, 2, 3)") { TracedPoint.new(1, 2, 3) }
report("TracedCoord.new(1, 2)") { TracedCoord.new(1, 2) }
report("TracedCoord.new(x: 1, y: 2)") { TracedCoord.new(x: 1, y: 2) }
report("TracedCoord.new(1)") { TracedCoord.new(1) }

section "TracePoint events"
trace_events("Point.new(1, 2)") { Point.new(1, 2) }
trace_events("Point.new(1, 2, 3)") { Point.new(1, 2, 3) }
trace_events("KeywordPoint.new(x: 1, y: 2)") { KeywordPoint.new(x: 1, y: 2) }
trace_events("Coord.new(1, 2)") { Coord.new(1, 2) }
trace_events("Coord.new(x: 1, y: 2)") { Coord.new(x: 1, y: 2) }
trace_events("Coord.new(1)") { Coord.new(1) }

section "allocation tracing"
allocation_info("Point.new(1, 2)") { Point.new(1, 2) }
allocation_info("KeywordPoint.new(x: 1, y: 2)") { KeywordPoint.new(x: 1, y: 2) }
allocation_info("Coord.new(1, 2)") { Coord.new(1, 2) }
allocation_info("Coord.new(x: 1, y: 2)") { Coord.new(x: 1, y: 2) }

section "copies and round trips"
report("Point dup") { Point.new(1, 2).dup }
report("Coord dup") { Coord.new(1, 2).dup }
report("Point Marshal") { Marshal.load(Marshal.dump(Point.new(1, [2]))) }
report("Coord Marshal") { Marshal.load(Marshal.dump(Coord.new(1, [2]))) }
report("memsize Point / Wide") { [ObjectSpace.memsize_of(Point.new(1, 2)), ObjectSpace.memsize_of(Wide.new)] }

section "initialize defined after instances were already created"
LateCoord = Data.define(:x, :y)
report("before override") { LateCoord.new(1, 2) }
LateCoord.class_eval do
  def initialize(x:, y:)
    puts "    LateCoord#initialize x=#{x.inspect} y=#{y.inspect}"
    super(x: x * 10, y:)
  end
end
report("after override") { LateCoord.new(1, 2) }

PrependedCoord = Data.define(:x, :y)
report("before prepend") { PrependedCoord.new(1, 2) }
PrependedCoord.prepend(Module.new {
  def initialize(**kwargs)
    puts "    prepended initialize #{kwargs.inspect}"
    super
  end
})
report("after prepend") { PrependedCoord.new(1, 2) }

report("subclass without initialize") { Class.new(Coord).new(1, 2) }
report("subclass with initialize") { Class.new(Coord) { def initialize(x:, y:) = super(x: y, y: x) }.new(1, 2) }
report("define block with initialize") { Data.define(:a) { def initialize(a:) = super(a: a.to_s) }.new(1) }
report("default through initialize") { Data.define(:a, :b) { def initialize(a:, b: 0) = super }.new(1) }

section "== / eql? / hash"
require "set"
Pair = Struct.new(:a, :b)
FrozenPair = Data.define(:a, :b)

class Noisy
  attr_reader :name
  def initialize(name, answer = true, &on_compare) = (@name, @answer, @on_compare = name, answer, on_compare)
  def ==(other) = (puts "    #{@name} == #{other.name}"; @on_compare&.call; @answer)
  def eql?(other) = (puts "    #{@name} eql? #{other.name}"; @answer)
  def hash = (puts "    #{@name} hash"; 7)
end

nan = Float::NAN
report("equal leaves") { [Pair.new(1, "x") == Pair.new(1, "x"), Pair.new(1, "x").eql?(Pair.new(1, "x"))] }
report("unequal leaves") { [Pair.new(1, "x") == Pair.new(1, "y"), Pair.new(1, "x").eql?(Pair.new(2, "x"))] }
report("same NaN object / different NaN") { [Pair.new(nan, 1) == Pair.new(nan, 1), Pair.new(0.0 / 0.0, 1) == Pair.new(0.0 / 0.0, 1)] }
report("0.0 and -0.0") { [Pair.new(0.0, 1) == Pair.new(-0.0, 1), Pair.new(0.0, 1).eql?(Pair.new(-0.0, 1))] }
report("1 and 1.0") { [Pair.new(1, 1) == Pair.new(1.0, 1), Pair.new(1, 1).eql?(Pair.new(1.0, 1))] }
report("bignum and symbols") { [Pair.new(2**80, :s) == Pair.new(2**80, :s), Pair.new(2**80, :s).eql?(Pair.new(2**80, :s))] }
report("encodings") { Pair.new("é", 1) == Pair.new("é".b, 1) }
report("other class, same members") { [Pair.new(1, 2) == Struct.new(:a, :b).new(1, 2), FrozenPair.new(1, 2) == Pair.new(1, 2)] }
report("noisy second member") { Pair.new(1, Noisy.new("left")) == Pair.new(1, Noisy.new("right")) }
report("noisy first member, second differs") { Pair.new(Noisy.new("left"), 1) == Pair.new(Noisy.new("right"), 2) }
report("first differs, noisy never asked") { Pair.new(1, Noisy.new("left")) == Pair.new(2, Noisy.new("right")) }
report("noisy eql?") { Pair.new(1, Noisy.new("left")).eql?(Pair.new(1, Noisy.new("right"))) }
report("recursive ==") { a = Pair.new(1, nil); a.b = a; b = Pair.new(1, nil); b.b = b; [a == b, a.eql?(b)] }
report("recursive through Array") { a = Pair.new(1, []); a.b << a; b = Pair.new(1, []); b.b << b; a == b }
report("recursive hash") { a = Pair.new(1, nil); a.b = a; a.hash == a.hash }
report("member == mutates the struct and re-enters") do
  left = Pair.new(1, nil)
  right = Pair.new(1, nil)
  left.b = Noisy.new("left") { left.b = 5; right.b = 6; puts "    re-entered: #{left == right}" }
  right.b = Noisy.new("right")
  left == right
end

report("Data as Hash key") { {FrozenPair.new(1, "k") => :found}[FrozenPair.new(1, "k")] }
report("Struct as Hash key") { {Pair.new(1, "k") => :found}[Pair.new(1, "k")] }
report("frozen Struct as Hash key") { {Pair.new(1, "k").freeze => :found}[Pair.new(1, "k").freeze] }
report("hash agrees with Hash lookup") { d = FrozenPair.new(1, "k"); [d.hash == FrozenPair.new(1, "k").hash, {d => 1}.key?(FrozenPair.new(1, "k"))] }
report("noisy member as key") { {FrozenPair.new(1, Noisy.new("stored")) => :found}[FrozenPair.new(1, Noisy.new("probe"))] }
report("nested Data key") { {FrozenPair.new(FrozenPair.new(1, 2), 3) => :found}[FrozenPair.new(FrozenPair.new(1, 2), 3)] }
report("Set and uniq") { [Set[FrozenPair.new(1, 2), FrozenPair.new(1, 2)].size, [Pair.new(1, 2), Pair.new(1, 2)].uniq.size] }
report("subclass overriding hash") { k = Class.new(FrozenPair) { def hash = (puts "    custom hash"; 1) }; {k.new(1, 2) => :found}[k.new(1, 2)] }
report("class with singleton hash") { k = Data.define(:a); def k.hash = (puts "    class hash"; 3); {k.new(1) => :found}[k.new(1)] }
trace_events("Hash lookup traced") { {FrozenPair.new(1, 2) => 1}[FrozenPair.new(1, 2)] }
report("member hash freezes and empties the struct, then re-hashes") do
  owner = Pair.new(1, nil)
  member = Object.new
  member.define_singleton_method(:hash) { owner.b = 2; owner.freeze; puts "    re-hashed: #{({owner => 1}.size)}"; 9 }
  owner.b = member
  {owner => 1}.size
end

section "deconstruct_keys"
report("some keys") { Point.new(1, 2).deconstruct_keys([:y]) }
report("duplicate keys") { Point.new(1, 2).deconstruct_keys([:x, :x]) }
report("unknown key stops") { Point.new(1, 2).deconstruct_keys([:x, :nope, :y]) }
report("string and integer keys on Struct") { Point.new(1, 2).deconstruct_keys(["x", 1]) }
report("string key on Data") { Coord.new(1, 2).deconstruct_keys(["x"]) }
report("more keys than members") { Point.new(1, 2).deconstruct_keys([:x, :y, :z]) }
report("not an Array") { Point.new(1, 2).deconstruct_keys(:x) }
report("pattern match") do
  case Coord.new(1, 2)
  in {x:, y:} then [x, y]
  end
end
report("12 members") { BigCoord.new(*1..12).deconstruct_keys([:m12, :m1]) }

section "Data#initialize itself replaced"
class Data
  alias_method :__probe_original_initialize, :initialize

  def initialize(**kwargs)
    puts "    Data#initialize replaced, got #{kwargs.inspect}"
    __probe_original_initialize(**kwargs)
  end
end
report("Coord.new(1, 2)") { Coord.new(1, 2) }
report("Coord.new(x: 1, y: 2)") { Coord.new(x: 1, y: 2) }

section "Integer#== redefined"
class Integer
  alias_method :__probe_original_eq, :==
  def ==(other) = (puts "    Integer#== #{self} #{other}"; __probe_original_eq(other))
end
report("after redefinition") { Pair.new(1, 2) == Pair.new(1, 2) }
report("Data after redefinition") { FrozenPair.new(1, 2) == FrozenPair.new(1, 3) }

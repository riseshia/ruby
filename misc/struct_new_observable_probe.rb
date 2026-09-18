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

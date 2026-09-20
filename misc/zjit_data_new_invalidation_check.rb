# Data.new compiled by the JIT must notice an initialize defined later, allocation tracing
# enabled later, and TracePoint enabled later.
require "objspace"
Coord = Data.define(:x, :y)
def make(a, b) = Coord.new(a, b)

5_000.times { |i| make(i, i) }
puts "warm: #{make(1, 2).inspect} frozen=#{make(1, 2).frozen?}"

Coord.class_eval { def initialize(x:, y:) = super(x: x * 10, y:) }
puts "after initialize defined: #{make(1, 2).inspect}"
5_000.times { |i| make(i, i) }
puts "recompiled: #{make(3, 4).inspect}"

Other = Data.define(:x, :y)
def make_other(a, b) = Other.new(a, b)
5_000.times { |i| make_other(i, i) }
object = nil
ObjectSpace.trace_object_allocations { object = make_other(1, 2) }
puts "allocation method under tracing: #{ObjectSpace.allocation_method_id(object).inspect}"
events = []
TracePoint.new(:c_call) { |tp| events << "#{tp.defined_class.inspect}##{tp.method_id}" }.enable { make_other(1, 2) }
puts "c_call events: #{events.inspect}"
puts "error path: #{begin; make_other(1, 2, 3) rescue "unreachable"; end}" rescue puts "arity: #{$!.class}"
def make_short(a) = Other.new(a)
begin
  5_000.times { make_short(1) }
rescue ArgumentError => e
  puts "missing: #{e.message} #{e.backtrace_locations.first(2).map(&:label).inspect}"
end

# Data.new compiled by a JIT: every form of the call, and what has to switch it off later
# (allocation tracing, TracePoint, initialize defined on the class / a subclass / a module).
require "objspace"
Coord = Data.define(:x, :y)
Sub = Class.new(Coord)
def pos(a, b) = Coord.new(a, b)
def kw(a, b) = Coord.new(y: b, x: a)
def bracket(a, b) = Coord[a, b]
def sub_kw(a, b) = Sub.new(x: a, y: b)
def missing(a) = Coord.new(x: a)
def unknown(a) = Coord.new(x: a, y: 1, z: 2)
def too_many(a) = Coord.new(a, 1, 2)
def dynamic(klass, a, b) = klass.new(a, b)
FORMS = %i[pos kw bracket sub_kw]

def report(title)
  puts "== #{title}"
  FORMS.each { |m| o = send(m, 1, 2); puts "#{m}: #{o.inspect} #{o.class} frozen=#{o.frozen?}" }
  %i[missing unknown too_many].each do |m|
    send(m, 1)
  rescue => e
    puts "#{m}: #{e.class}: #{e.message} | #{e.backtrace_locations.first(3).map(&:label).join(' < ')}"
  end
  [Coord, Sub, Struct.new(:x, :y), Array].each { |k| puts "dynamic #{k.name || 'anon'}: #{dynamic(k, 1, 2).inspect}" }
end

def warm = 3_000.times { |i| FORMS.each { |m| send(m, i, i) }; (missing(i) rescue nil); (unknown(i) rescue nil); (too_many(i) rescue nil) }

warm; report("warm")

ObjectSpace.trace_object_allocations do
  FORMS.each { |m| o = send(m, 1, 2); puts "traced #{m}: #{ObjectSpace.allocation_method_id(o).inspect} line=#{ObjectSpace.allocation_sourceline(o)}" }
end
warm; report("after allocation tracing")

events = []
tp = TracePoint.new(:c_call, :c_return, :call) { |t| events << [t.event, t.method_id] if t.path == __FILE__ || t.event != :call }
tp.enable { pos(1, 2); kw(1, 2) }
puts "traced events: #{events.inspect}"
warm; report("after TracePoint")

Sub.class_eval { def initialize(x:, y:) = super(x: x * 10, y:) }
report("after Sub#initialize"); warm; report("after Sub#initialize, warm")

Coord.prepend(Module.new { def initialize(x:, y:) = super(x:, y: y * 100) })
report("after prepend"); warm; report("after prepend, warm")

GC.stress = true
20.times { |i| raise "bad" unless pos(i, "s#{i}").y == "s#{i}00" * 1 || true }
GC.stress = false
puts "gc stress ok"

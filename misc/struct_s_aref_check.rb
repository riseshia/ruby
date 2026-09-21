# Class#new on a Struct class reached by a regular call: `Point[1, 2]`, send(:new), a variable class.
require "objspace"
P = Struct.new(:x, :y); Kw = Struct.new(:x, :y, keyword_init: true); Sub = Class.new(P); Big = Struct.new(*(1..100).map { :"m#{_1}" })
Custom = Struct.new(:x, :y) { def initialize(x, y = :dflt) = super(x, y) }
Raising = Struct.new(:x) { def initialize(x) = raise(ArgumentError, "no #{x}") }
class Plain; attr_reader :a; def initialize(a) = @a = a; def self.[](a) = new(a); end
def bracket(k, *a) = k[*a]
def two(k, a, b) = k[a, b]
def one(k, a) = k[a]
def none(k) = k[]
def via_send(k, a, b) = k.send(:new, a, b)
def with_block(k, a, b) = k.[](a, b) { :ignored }
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message} #{$!.backtrace_locations.first(3).map(&:label).inspect}")
3.times do
  [P, Sub, Custom].each { |k| 400.times { |i| two(k, i, "s#{i}"); one(k, i); via_send(k, i, i); with_block(k, i, i) } }
  400.times { |i| none(P); one(Big, i); (two(Kw, 1, 2) rescue nil); (one(Raising, i) rescue nil) }
  report("values") { [two(P, 1, "two").to_a, one(P, 1).to_a, none(P).to_a, two(Sub, 1, 2).class, two(Custom, 1, 2).to_a, one(Custom, 1).to_a, one(Big, :first).to_a.first(2), via_send(P, 1, 2).to_a, with_block(P, 1, 2).to_a, two(P, 1, 2).frozen?] }
  report("keyword_init class, positional") { two(Kw, 1, 2) }
  report("keyword_init class, keywords") { Kw[x: 1, y: 2].to_a }
  report("too many") { bracket(P, 1, 2, 3) }
  report("initialize raises") { one(Raising, 5) }
  report("a Hash is positional") { one(P, {x: 1}).to_a }
  report("a plain class with its own []") { [one(Plain, 7).a, Plain.send(:new, 8).a] }
end
ObjectSpace.trace_object_allocations { o = two(P, 1, 2); report("allocation tracing") { [ObjectSpace.allocation_method_id(o), ObjectSpace.allocation_class_path(o)] } }
report("after allocation tracing") { two(P, 1, 2).to_a }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { two(P, 1, 2) }
report("traced") { events }
GC.stress = true; ok = 30.times.all? { |i| two(P, "a#{i}", [i]).to_a == ["a#{i}", [i]] && one(Big, "b#{i}").m1 == "b#{i}" }; GC.stress = false
report("gc stress") { ok }
kept = 3000.times.map { |i| two(P, "k#{i}", [i]) }; GC.start(full_mark: false); GC.start
report("kept") { kept.each_with_index.all? { |o, i| o.x == "k#{i}" && o.y == [i] } }
P.class_eval { def initialize(x, y) = super(y, x) }
report("initialize defined later") { two(P, 1, 2).to_a }

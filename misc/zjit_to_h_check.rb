# Struct#to_h / Data#to_h run often enough to be JIT-compiled.
require "objspace"
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y); Sub = Class.new(D)
Big = Struct.new(*(1..20).map { :"m#{_1}" }); Odd = Struct.new(:"foo bar", :"a?")
Over = Struct.new(:x) { def to_h = {over: 1} }
def h(o) = o.to_h
def hb(o) = o.to_h { |k, v| [k.to_s, v] }
def hp(o, &b) = o.to_h(&b)
def report(title)
  puts "== #{title}"
  [S.new(1, "two", [3]), D.new(1, 2), Sub.new(3, 4), Big.new(*1..20), Odd.new(1, 2), Over.new(1), S.new].each do |o|
    a = h(o)
    puts "#{o.class}: #{a.inspect[0, 70]} keys=#{a.keys.first(3).inspect} frozen=#{a.frozen?} fresh=#{!a.equal?(h(o))} default=#{a.default.inspect} cmp=#{a.compare_by_identity?} block=#{hb(o).inspect[0, 40]} blockarg=#{hp(o) { |k, v| [v, k] }.inspect[0, 40]} noblockarg=#{hp(o).inspect[0, 30]}"
  end
  a = h(S.new(1, 2, 3)); a[:w] = 4; puts "mutable copy: #{a.inspect}"
end
def warm = 2_000.times { |i| o = S.new(i, i, i); h(o); hb(o); hp(o); d = D.new(i, i); h(d); hb(d) }
warm; report("warm")
ObjectSpace.trace_object_allocations { a = h(D.new(1, 2)); puts "traced: #{ObjectSpace.allocation_method_id(a).inspect}" }
warm; report("after allocation tracing")
events = []
TracePoint.new(:c_call) { |tp| events << tp.method_id }.enable { h(S.new(1, 2, 3)) }
puts "c_call: #{events.inspect}"
warm
D.class_eval { def to_h = {late: true} }
report("after Data#to_h redefined on the class")
GC.stress = true; 30.times { |i| raise "bad" unless h(S.new("a#{i}", [i], i)) == {x: "a#{i}", y: [i], z: i} }; GC.stress = false
puts "gc stress ok"

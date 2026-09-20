# Struct#to_a / values / deconstruct / size / length run often enough to be JIT-compiled.
require "objspace"
S = Struct.new(:x, :y, :z); Sub = Class.new(S); K = Struct.new(:a, keyword_init: true)
Big = Struct.new(*(1..100).map { :"m#{_1}" })
Over = Struct.new(:x) { def to_a = [:overridden]; def size = -1 }
def to_a_of(o) = o.to_a
def values_of(o) = o.values
def dec(o) = o.deconstruct
def size_of(o) = o.size
def length_of(o) = o.length
def pattern(o) = (o in [a, *rest]) ? [a, rest] : :no
def report(title)
  puts "== #{title}"
  [S.new(1, "two", [3]), Sub.new(4, 5, 6), K.new(a: 1), Big.new(*1..100), Over.new(1), S.new].each do |o|
    a = to_a_of(o)
    puts "#{o.class}: to_a=#{a.first(4).inspect} n=#{a.size} frozen=#{a.frozen?} fresh=#{!a.equal?(to_a_of(o))} values=#{values_of(o).first(2).inspect} deconstruct=#{dec(o).first(2).inspect} size=#{size_of(o)} length=#{length_of(o)} pattern=#{pattern(o).inspect[0, 40]}"
  end
  a = to_a_of(S.new(1, 2, 3)); a << 4; puts "mutable copy: #{a.inspect}"
end
def warm = 2_000.times { |i| o = S.new(i, i, i); to_a_of(o); values_of(o); dec(o); size_of(o); length_of(o); pattern(o) }
warm; report("warm")
ObjectSpace.trace_object_allocations { a = to_a_of(S.new(1, 2, 3)); puts "traced: #{ObjectSpace.allocation_method_id(a).inspect} #{ObjectSpace.allocation_class_path(a).inspect}" }
warm; report("after allocation tracing")
events = []
TracePoint.new(:c_call) { |tp| events << tp.method_id }.enable { to_a_of(S.new(1, 2, 3)); size_of(S.new(1, 2, 3)) }
puts "c_call: #{events.inspect}"
warm
S.class_eval { def to_a = [:late]; def size = :late }
report("after to_a / size redefined on the class")
GC.stress = true; 30.times { |i| raise "bad" unless to_a_of(Sub.new("a#{i}", [i], i)) == ["a#{i}", [i], i] }; GC.stress = false
puts "gc stress ok"

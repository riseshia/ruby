# Positional Struct#initialize compiled by YJIT with inline stores: values of every kind,
# fewer arguments than members, old receivers (write barrier), frozen receivers, GC stress.
S3 = Struct.new(:a, :b, :c); S8 = Struct.new(*(1..8).map { :"m#{_1}" }); S9 = Struct.new(*(1..9).map { :"m#{_1}" })
Sub = Class.new(S3) { def initialize(a, b = :default) = super(a, b) }
def make3(a, b, c) = S3.new(a, b, c)
def make1(a) = S3.new(a)
def make0 = S3.new
def make8(v) = S8.new(v, 2, "three", :four, 5.0, nil, [7], {k: 8})
def make9(v) = S9.new(v, 2, 3)
def sub(v) = Sub.new(v)
def reinit(s, v) = s.send(:initialize, v, [v], "s#{v}")
def reinit_direct(s, v) = s.instance_eval { initialize(v, [v]) }
3000.times { |i| make3(i, "s#{i}", [i]); make1(i); make0; make8(i); make9(i); sub(i) }
p make3(1, "two", [3]).to_a, make1(:only).to_a, make0.to_a, make8("v").to_a, make9(1).to_a, sub(1).to_a

old = S3.new(1, 2, 3); 4.times { GC.start }             # promote the receiver to the old generation
kept = []
2000.times { |i| reinit(old, i); reinit_direct(old, i); kept << old.b if i % 500 == 0 }
GC.start(full_mark: false); GC.start(full_mark: false)   # minor GCs: young values must survive through the old struct
p old.to_a, kept

frozen = S3.new(1, 2, 3).freeze
p((reinit(frozen, 1) rescue [$!.class, $!.backtrace_locations.first(2).map(&:label)]))
p((make3(1, 2, 3).tap { |s| def s.x = 1 }.send(:initialize, 9).then { nil }))
GC.stress = true
bad = 0
40.times { |i| s = make3("a#{i}", [i, [i]], {i => "v#{i}"}); t = make8("x#{i}"); bad += 1 unless s.to_a == ["a#{i}", [i, [i]], {i => "v#{i}"}] && t.m1 == "x#{i}" && t.m7 == [7] }
GC.stress = false
puts "gc stress bad=#{bad}"
GC.verify_internal_consistency
puts "heap consistent"

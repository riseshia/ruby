# Data instances allocated frozen from the start, with members stored without a write barrier:
# GC must still see every member, under generational and incremental marking, compaction and stress.
require "objspace"
Pair = Data.define(:a, :b); Wide = Data.define(*(1..12).map { :"m#{_1}" }); Sub = Class.new(Pair)
def pos(a, b) = Pair.new(a, b)
def kw(a, b) = Pair.new(b: b, a: a)
def with_b(d, v) = d.with(b: v)
def wide(i) = Wide.new(*(1..12).map { |j| "#{i}-#{j}" })
def wide_with(d, v) = d.with(m12: v, m1: v)
3000.times { |i| pos(i, i); kw(i, i); with_b(pos(i, i), i); wide_with(wide(i), i) }

d = pos("x", [1]); p [d.frozen?, d.instance_variables, ObjectSpace.memsize_of(d), (d.instance_variable_set(:@z, 1) rescue $!.class), d.dup.frozen?, d.clone(freeze: false).frozen?, Marshal.load(Marshal.dump(d)) == d]
p [with_b(d, 2).frozen?, kw(1, 2).frozen?, Sub.new(1, 2).frozen?, Sub.new(a: 1, b: 2).with(a: 3).class]
p [(d.send(:initialize, a: 1, b: 2) rescue $!.class), d.hash == pos("x", [1]).hash, d.eql?(pos("x", [1])), Ractor.shareable?(pos(1, :s))]

# keep many instances alive across minor GCs while their members are the only reference to young objects
kept = []
20.times do |round|
  2000.times { |i| kept << pos("s#{round}-#{i}", [round, i]) << kw({k: i}, "t#{i}") << with_b(kept.last || pos(1, 2), "w#{round}-#{i}") }
  GC.start(full_mark: false)
  kept = kept.last(3000)
end
GC.start; GC.compact if GC.respond_to?(:compact)
bad = kept.count { |x| !(x.frozen? && x.a && x.b) || (x.a.is_a?(String) && x.a !~ /\As\d+-\d+\z/) }
puts "kept=#{kept.size} bad=#{bad}"

# an old Data whose `with` copies point at young values, then only minor GCs
old = pos("old", "old"); 4.times { GC.start }
copies = 500.times.map { |i| with_b(old, "young#{i}") }
3.times { GC.start(full_mark: false) }
puts "copies ok=#{copies.each_with_index.all? { |c, i| c.b == "young#{i}" && c.a.equal?(old.a) }}"

GC.stress = true
ok = 60.times.all? { |i| a = pos("a#{i}", [i]); b = kw([i], "b#{i}"); c = with_b(a, {i => i}); w = wide_with(wide(i), "v#{i}"); a.a == "a#{i}" && b.b == "b#{i}" && c.b == {i => i} && w.m12 == "v#{i}" && w.m6 == "#{i}-6" }
GC.stress = false
puts "stress ok=#{ok}"
GC.verify_internal_consistency
GC.verify_compaction_references(expand_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
puts "heap consistent"

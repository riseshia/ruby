# Struct#to_h / Data#to_h: the Hash has to be an ordinary one in every respect, whatever
# the number of members, and stay one when it is changed afterwards.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
SIZES = [0, 1, 2, 3, 7, 8, 9, 10, 11, 16, 17, 40]
STRUCTS = SIZES.to_h { |n| [n, n.zero? ? nil : Struct.new(*Array.new(n) { :"m#{_1}" })] }
DATAS = SIZES.to_h { |n| [n, Data.define(*Array.new(n) { :"m#{_1}" })] }
dynamic = Array.new(5) { "dyn_#{_1}_#{rand(10**9)}".to_sym }
Dyn = Struct.new(*dynamic)
S3 = Struct.new(:x, :y, :z); D3 = Data.define(:x, :y, :z); Sub3 = Class.new(S3); Kw3 = Struct.new(:x, :y, :z, keyword_init: true)
def hot_s(o) = o.to_h
def hot_d(o) = o.to_h
def hot_any(o) = o.to_h
s3 = S3.new(1, "two", [3]); d3 = D3.new(1, "two", [3])
500.times { hot_s(s3); hot_d(d3); [s3, d3, Sub3.new(1, 2, 3), Kw3.new(x: 1, y: 2, z: 3)].each { hot_any(_1) } }

report("every size, struct") { SIZES.map { |n| k = STRUCTS[n] or next; h = k.new(*Array.new(n) { _1 * 2 }).to_h; [n, h.size, h.keys == k.members, h.values.sum, k.members.all? { |m| h[m] == h.fetch(m) && h.key?(m) }, h[:nope]] } }
report("every size, data") { SIZES.map { |n| k = DATAS[n]; h = k.new(*Array.new(n) { _1 * 2 }).to_h; [n, h.size, h.keys == k.members, h.values.sum, k.members.all? { |m| h.key?(m) }, h.class, h.frozen?, h.default, h.compare_by_identity?] } }
report("hot sites") { [hot_s(s3), hot_d(d3), hot_any(Sub3.new(4, 5, 6)), hot_any(Kw3.new(x: 7, y: 8, z: 9)), hot_s(d3), (hot_s(1) rescue $!.class)] }
report("fresh each time") { a = hot_s(s3); b = hot_s(s3); a[:x] = :changed; [a, b, s3.x, a.equal?(b)] }
report("values are the same objects") { h = hot_s(s3); [h[:y].equal?(s3.y), h[:z].equal?(s3.z)] }
report("grows past the small table") { SIZES.map { |n| k = DATAS[n]; h = k.new(*Array.new(n) { _1 }).to_h; 12.times { |i| h[:"extra#{i}"] = i; h["s#{i}"] = i }; [h.size, h[:m0], h[:extra11], h["s3"], h.keys.first(2)] } }
report("delete, reinsert, order") { h = hot_s(s3); h.delete(:y); h[:y] = 0; h[:a] = 1; h.delete(:x); [h, h.keys, h.first, h.to_a.last] }
report("rehash, dup, ==, hash, eql?") { h = hot_s(s3); g = { x: 1, y: "two", z: [3] }; [h.rehash == g, h.dup == g, h == g, g == h, h.hash == g.hash, h.eql?(g), h.merge(g) == g, h.compare_by_identity[:x]] }
report("dynamic symbols") { o = Dyn.new(*0...5); h = o.to_h; GC.start; [h.keys == dynamic, dynamic.map { h[_1] }, h.key?(dynamic[3].to_s.to_sym)] }
report("iteration and transforms") { h = hot_d(d3); [h.map { |k, v| [k, v.class] }, h.select { |k, _| k != :y }, h.transform_values(&:to_s), h.min_by { |k, _| k }, h.any? { |k, v| v == 1 }, h.sum { |_, v| v.is_a?(Integer) ? v : 0 }] }
report("with a block") { [s3.to_h { |k, v| [k.to_s, v] }, d3.to_h { |k, v| [v.to_s, k] }, (s3.to_h { 1 } rescue $!.class)] }
report("keyword splat of the result") { def kw(**o) = o; [kw(**hot_s(s3)), kw(**hot_d(d3), w: 1)] }
report("deconstruct_keys(nil)") { [s3.deconstruct_keys(nil), d3.deconstruct_keys(nil)] }
report("memsize") { [ObjectSpace.memsize_of(hot_s(s3)) == ObjectSpace.memsize_of({ x: 1, y: "two", z: [3] }), ObjectSpace.memsize_of(STRUCTS[8].new.to_h) == ObjectSpace.memsize_of(STRUCTS[8].members.to_h { [_1, nil] })] }
ObjectSpace.trace_object_allocations { h = hot_s(s3); g = hot_d(d3); report("allocation tracing") { [ObjectSpace.allocation_method_id(h), ObjectSpace.allocation_class_path(h), ObjectSpace.allocation_method_id(g)] } }
500.times { hot_s(s3); hot_d(d3) }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { hot_s(s3) }
report("traced") { events }
GC.stress = true; ok = 40.times.all? { hot_s(s3) == { x: 1, y: "two", z: [3] } && hot_d(d3)[:z] == [3] && STRUCTS[9].new(*0...9).to_h[:m8] == 8 }; GC.stress = false
report("gc stress") { ok }
old = hot_s(s3); 4.times { GC.start }; old_young = "young #{rand}"; s_old = S3.new(old_young, 1, 2); h_old = hot_s(s_old); 4.times { GC.start }
report("survives GC") { [old, h_old[:x] == old_young] }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [hot_s(s3), hot_d(d3), old] }
m = Marshal.load(Marshal.dump(hot_s(s3)))
report("marshal") { [m, m[:y]] }
class S3; def to_h = :redefined; end
report("redefined") { [hot_s(s3), hot_any(Sub3.new(1, 2, 3))] }

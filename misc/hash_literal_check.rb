# Hash literals with Symbol keys from hot code: the shapes ZJIT's NewHash can see.
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
def two(a, b) = { x: a, y: b }
def eight(v) = { a: v, b: v + 1, c: v + 2, d: v + 3, e: v + 4, f: v + 5, g: v + 6, h: v + 7 }
def nine(v) = { a: v, b: v + 1, c: v + 2, d: v + 3, e: v + 4, f: v + 5, g: v + 6, h: v + 7, i: v + 8 }
def twenty(v) = { k0: v, k1: v, k2: v, k3: v, k4: v, k5: v, k6: v, k7: v, k8: v, k9: v, k10: v, k11: v, k12: v, k13: v, k14: v, k15: v, k16: v, k17: v, k18: v, k19: v }
def duplicate(a, b) = eval("{ x: a, y: 0, x: b }")
def duplicate_literal(a, b) = { x: a, "y": 0, x: b }
def runtime_key(k, v) = { x: 1, k => v, z: 3 }
def runtime_sym_dup(k, v) = { x: 1, k.to_sym => v }
def mixed(v) = { x: v, "s" => v, 1 => v, nil => v }
def string_keys(v) = { "a" => v, "b" => v }
def nested(v) = { outer: { inner: v, other: [v] }, list: [{ id: v }] }
def splat(h, v) = { a: v, **h, z: v }
def kwargs(**o) = o
def pass(v) = kwargs(a: v, b: v + 1, c: [v])
def values(v) = { s: "str#{v}", a: [v], h: { v: v }, f: v.to_f, n: nil, t: true, sym: :"dyn#{v}" }
SITES = %i[two eight nine twenty]
600.times { |i| two(i, i); eight(i); nine(i); twenty(i); duplicate_literal(i, i); runtime_key(:w, i); runtime_sym_dup("q", i); mixed(i); string_keys(i); nested(i); splat({ m: 1 }, i); pass(i); values(i % 3) }
report("two") { h = two(1, "b"); [h, h[:x], h[:y], h[:z], h.keys, h.size, h.frozen?, h.compare_by_identity?] }
report("eight / nine / twenty") { [eight(1), nine(1), twenty(7).size, twenty(7)[:k19], twenty(7).keys.last, nine(1)[:i]] }
report("duplicate keys") { [duplicate(1, 2), duplicate_literal(1, 2), duplicate_literal(1, 2).keys] }
report("runtime keys") { [runtime_key(:w, 2), runtime_key(:x, 2), runtime_key(:z, 2), runtime_key("s", 2), runtime_sym_dup("x", 9), runtime_sym_dup("q", 9)] }
report("mixed, strings, nested") { [mixed(1), string_keys(1), string_keys(1).keys.map(&:frozen?), nested(2)] }
report("splat") { [splat({ m: 1 }, 0), splat({ a: :over, z: :under }, 0), splat({}, 0)] }
report("kwargs") { pass(1) }
report("values") { values(2) }
report("mutation afterwards") { h = eight(0); 10.times { |i| h[:"n#{i}"] = i }; h.delete(:a); h[:a] = :back; [h.size, h.keys.first, h.keys.last, h[:h], h[:n9]] }
report("equality with other hashes") { [two(1, 2) == { y: 2, x: 1 }, two(1, 2).hash == { x: 1, y: 2 }.hash, two(1, 2).eql?({ x: 1, y: 2 }), { two(1, 2) => 1 }[{ x: 1, y: 2 }]] }
GC.stress = true; ok = 30.times.all? { |i| two(i, [i]) == { x: i, y: [i] } && eight(i)[:h] == i + 7 && values(1)[:sym] == :dyn1 && nested(i)[:outer][:other] == [i] }; GC.stress = false
report("gc stress") { ok }
keep = Array.new(200) { |i| two("young#{i}", [i]) }; 4.times { GC.start }
report("old hashes keep young values") { keep.each_with_index.all? { |h, i| h == { x: "young#{i}", y: [i] } } }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [two(1, 2), keep[5], eight(0)[:d]] }
r = Ractor.new { h = { x: 1, y: [2] }; 500.times.map { { a: _1, b: h } }.last } rescue nil
report("ractor") { r ? (r.respond_to?(:value) ? r.value : r.take) : :no_ractor }

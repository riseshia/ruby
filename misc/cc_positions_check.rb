# One call site with literal keywords, many receiver classes: the site's call cache is per class,
# so what it remembers about member positions must never leak across classes or members.
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
def attempt = yield rescue "#{$!.class}: #{$!.message}"
A = Struct.new(:x, :y, :z, keyword_init: true); B = Struct.new(:z, :y, :x, keyword_init: true); C = Struct.new(:y, :x, keyword_init: true)
DA = Data.define(:x, :y, :z); DB = Data.define(:z, :y, :x); DC = Data.define(:y, :x); DD = Data.define(:x, :y)
Wide = Data.define(*Array.new(40) { :"m#{_1}" }); WideS = Struct.new(*Array.new(40) { :"m#{_1}" }, keyword_init: true)
def kw(k, a, b, c) = k.new(x: a, y: b, z: c)
def kw2(k, a, b) = k.new(y: b, x: a)
def with(o, v) = o.with(x: v)
def sup(k, a, b, c) = k.new(x: a, y: b, z: c)
Over = Data.define(:x, :y, :z) { def initialize(x:, y:, z:) = super(z: z, x: x, y: y) }
OverS = Struct.new(:x, :y, :z, keyword_init: true) { def initialize(x:, y:, z:) = super(y: y, x: x, z: z) }
def wide(k) = k.new(m39: 39, m0: 0, m31: 31, m32: 32, m5: 5)
def wide_full(k, h) = k.new(**h)
500.times { [A, B, DA, DB, Over, OverS].each { kw(_1, 1, 2, 3) }; [C, DC].each { kw2(_1, 1, 2) }; with(DA.new(1, 2, 3), 9); with(DB.new(1, 2, 3), 9); with(DD.new(1, 2), 9); wide(WideS) }
report("same site, classes with different member orders") { [A, B, DA, DB, Over, OverS].map { kw(_1, 1, 2, 3).to_h } }
report("two members") { [C, DC].map { kw2(_1, 1, 2).to_h } }
report("with across classes") { [with(DA.new(1, 2, 3), 9), with(DB.new(1, 2, 3), 9), with(DD.new(1, 2), 9)].map(&:to_h) }
report("wrong keywords at the site later") { [attempt { kw(C, 1, 2, 3) }, attempt { kw(DC, 1, 2, 3) }, attempt { kw2(A, 1, 2).to_h }, attempt { kw2(DA, 1, 2) }] }
report("positions past the word") { [wide(WideS).to_h.compact, attempt { wide(Wide) }] }
Sub = Class.new(A); SubD = Class.new(DA)
report("subclasses at the same site") { [kw(Sub, 4, 5, 6).to_h, kw(SubD, 4, 5, 6).to_h, kw(A, 7, 8, 9).to_h] }
report("a class that stops taking keywords") { k = Struct.new(:x, :y, :z, keyword_init: true); r1 = kw(k, 1, 2, 3).to_h; k2 = Struct.new(:x, :y, :z, keyword_init: false); [r1, attempt { kw(k2, 1, 2, 3) }] }
report("initialize redefined after the site is hot") { k = Data.define(:x, :y, :z); 300.times { kw(k, 1, 2, 3) }; r1 = kw(k, 1, 2, 3); k.class_eval { def initialize(x:, y:, z:) = super(x: x * 10, y:, z:) }; [r1, kw(k, 1, 2, 3)] }
report("frozen receiver at a hot super site") { o = OverS.new(x: 1, y: 2, z: 3); o.freeze; attempt { o.send(:initialize, x: 4, y: 5, z: 6) } }
threads = 4.times.map { |t| Thread.new { 3000.times.map { |i| [kw(A, i, t, 0).x, kw(DB, i, t, 0).z, kw2(DC, i, t).x, with(DA.new(1, 2, 3), i).x].sum }.sum } }
report("threads") { threads.map(&:value) }
r = Ractor.new { k = Data.define(:x, :y, :z); 500.times.map { |i| k.new(x: i, y: 2, z: 3).x }.sum }
report("ractor") { r.respond_to?(:value) ? r.value : r.take }
GC.stress = true; ok = 20.times.all? { |i| kw(A, i, [i], "s").to_a == [i, [i], "s"] && kw(DB, i, [i], "s").to_h == { z: "s", y: [i], x: i } }; GC.stress = false
report("gc stress") { ok }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [kw(A, 1, 2, 3).to_a, kw(DB, 1, 2, 3).to_h, with(DA.new(1, 2, 3), 0).to_h] }

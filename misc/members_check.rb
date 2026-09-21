# Struct#members / Data#members from hot call sites: a fresh Array each time, for every kind of class.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
S = Struct.new(:a, :b)
Sub = Class.new(S)
SubSub = Class.new(Sub) { def extra = 1 }
Big = Struct.new(*(:m0..:m11))
Kw = Struct.new(:a, :b, keyword_init: true)
D = Data.define(:x, :y)
DSub = Class.new(D)
Empty = Data.define
Overridden = Struct.new(:a) { def members = [:mine] }
def of(o) = o.members
OBJS = [S.new(1, 2), Sub.new(1, 2), SubSub.new(1, 2), Big.new, Kw.new(a: 1, b: 2), D.new(1, 2), DSub.new(1, 2), Empty.new, Overridden.new(1)]
single = S.new(1, 2); def single.tag = :singleton
def mono_s(o) = o.members
def mono_d(o) = o.members
def mono_sub(o) = o.members
def mono_single(o) = o.members
500.times { OBJS.each { of(_1) }; mono_s(OBJS[0]); mono_d(OBJS[5]); mono_sub(OBJS[2]); mono_single(single) }
report("each class") { OBJS.map { of(_1) } }
report("monomorphic") { [mono_s(OBJS[0]), mono_d(OBJS[5]), mono_sub(OBJS[2]), mono_single(single)] }
report("fresh and mutable") { a = mono_s(OBJS[0]); b = mono_s(OBJS[0]); a << :z; [a, b, a.equal?(b), a.frozen?, a.class, mono_s(OBJS[0])] }
report("data fresh") { a = mono_d(OBJS[5]); a.clear; [a, mono_d(OBJS[5]), D.members] }
report("other receiver at a monomorphic site") { [mono_s(OBJS[5]), mono_s(OBJS[3]), (mono_s(1) rescue $!.class)] }
report("with a block / argument") { [OBJS[0].members { 1 }, (OBJS[0].members(1) rescue $!.class)] }
ObjectSpace.trace_object_allocations { m = mono_s(OBJS[0]); d = mono_d(OBJS[5]); report("allocation tracing") { [ObjectSpace.allocation_method_id(m), ObjectSpace.allocation_class_path(m), ObjectSpace.allocation_method_id(d)] } }
500.times { mono_s(OBJS[0]); mono_d(OBJS[5]) }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { mono_s(OBJS[0]) }
report("traced") { events }
GC.stress = true; ok = 40.times.all? { mono_s(OBJS[0]) == [:a, :b] && mono_d(OBJS[5]) == [:x, :y] && mono_sub(OBJS[2]) == [:a, :b] }; GC.stress = false
report("gc stress") { ok }
GC.compact if GC.respond_to?(:compact)
report("after compaction") { [mono_s(OBJS[0]), mono_d(OBJS[5]), mono_sub(OBJS[2])] }
class S; def members = [:redefined]; end
report("redefined") { [mono_s(OBJS[0]), of(OBJS[1])] }
class S; remove_method :members; end
report("restored") { [mono_s(OBJS[0]), of(OBJS[1])] }

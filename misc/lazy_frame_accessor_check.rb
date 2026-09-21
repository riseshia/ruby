# Struct#[] / []= / size / to_a / members called without a frame by YJIT: the frame must be there
# for every error, for conversions that run Ruby code, and for allocation tracing.
require "objspace"
S = Struct.new(:a, :b); D = Data.define(:a, :b); Big = Struct.new(*(1..100).map { :"m#{_1}" })
class Idx; def initialize(i) = @i = i; def to_int = ($seen = caller_locations(0, 3).map(&:label); @i); end
class BadIdx; def to_int = raise("boom in to_int"); end
def aref(s, k) = s[k]
def aset(s, k, v) = (s[k] = v)
def size_of(s) = s.size
def to_a_of(s) = s.to_a
def members_of(s) = s.members
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message} #{$!.backtrace_locations.first(3).map(&:label).inspect}")
s = S.new(1, "two"); big = Big.new(*1..100)
2000.times { aref(s, :a); aref(s, 1); aref(s, "b"); aset(s, :a, 1); aset(s, 0, 1); size_of(s); to_a_of(s); members_of(s); members_of(D.new(1, 2)); aref(big, 99) }
3.times do
  report("values") { [aref(s, :a), aref(s, "b"), aref(s, 1), aref(s, -1), aref(s, 1.9), aref(big, :m100), aref(big, -100), size_of(s), size_of(big), to_a_of(s), members_of(s), members_of(D.new(1, 2))] }
  report("aset") { t = S.new(1, 2); [aset(t, :a, :x), aset(t, -1, [1]), aset(t, "a", "y"), t.to_a] }
  report("no member") { aref(s, :zz) }
  report("no member, string") { aref(s, "zz") }
  report("offset too large") { aref(s, 2) }
  report("offset too small") { aref(s, -3) }
  report("not convertible") { aref(s, Object.new) }
  report("nil key") { aref(s, nil) }
  report("to_int is called") { [aref(s, Idx.new(1)), $seen] }
  report("to_int raises") { aref(s, BadIdx.new) }
  report("aset no member") { aset(S.new(1, 2), :zz, 1) }
  report("aset frozen") { aset(S.new(1, 2).freeze, :a, 1) }
  report("aset to_int") { t = S.new(1, 2); aset(t, Idx.new(0), 9); [t.to_a, $seen] }
  report("fresh arrays") { [to_a_of(s).equal?(to_a_of(s)), members_of(s).equal?(members_of(s)), to_a_of(s).frozen?] }
end
# one call site, many keys (and many classes): the site must end up generic, never wrong
T = Struct.new(:b, :a, :c)
def dyn(o, k) = o[k]
def dyn_set(o, k, v) = (o[k] = v)
keys = [:a, :b, 0, 1, -1, "a", 1.5, :a, :a, -2]
out = []
300.times { |i| k = keys[i % keys.size]; o = i.odd? ? S.new(i, -i) : T.new(i, -i, 0); out << dyn(o, k); dyn_set(o, k, i * 2); out << o.to_a }
report("rotating keys and classes") { [out.size, out.hash.class, out.last(4)] }
report("rotating, then a bad key") { dyn(S.new(1, 2), :zz) }
report("rotating set, frozen") { dyn_set(S.new(1, 2).freeze, :a, 1) }
mono = S.new(1, 2); 3000.times { dyn_set(mono, :b, "v"); dyn(mono, :b) }
report("same key, frozen later") { dyn_set(mono.freeze, :b, 1) }
report("same key, other class with the member elsewhere") { [dyn(T.new(1, 2, 3), :b), dyn(T.new(1, 2, 3), :a)] }
ObjectSpace.trace_object_allocations do
  a = to_a_of(s); m = members_of(s); dm = members_of(D.new(1, 2))
  report("allocation tracing") { [ObjectSpace.allocation_method_id(a), ObjectSpace.allocation_method_id(m), ObjectSpace.allocation_method_id(dm), ObjectSpace.allocation_class_path(a)] }
end
report("after allocation tracing") { [to_a_of(s), members_of(s)] }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { aref(s, :a); size_of(s); to_a_of(s) }
report("traced") { events }
young = S.new(nil, nil); 4.times { GC.start }
500.times { |i| aset(young, :a, "v#{i}"); aset(young, 1, [i]) }; GC.start(full_mark: false)
report("young values in an old struct") { young.to_a }
GC.stress = true; ok = 30.times.all? { |i| t = S.new(i, "s#{i}"); aset(t, :b, "n#{i}"); to_a_of(t) == [i, "n#{i}"] && members_of(t) == %i[a b] }; GC.stress = false
report("gc stress") { ok }
S.class_eval { def [](k) = :redefined; def size = :redefined }
report("redefined") { [aref(s, :a), size_of(s)] }

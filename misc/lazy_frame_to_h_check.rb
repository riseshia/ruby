# to_h / deconstruct_keys called without a frame by YJIT. The caller having a block must not matter.
require "objspace"
S = Struct.new(:a, :b); D = Data.define(:a, :b)
class Key; def to_int = ($seen = caller_locations(0, 3).map(&:label); 0); end
def plain(o) = o.to_h
def caller_has_block(o) = o.to_h             # called with a block below: to_h must not yield to it
def with_block(o) = o.to_h { |k, v| [k.to_s, v] }
def pass_block(o, &blk) = o.to_h(&blk)
def keys(o, ks) = o.deconstruct_keys(ks)
def keys_caller_block(o) = o.deconstruct_keys(nil)
def match(o) = (o in {a: Integer => x, b:}) ? [x, b] : :no
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, "0x")}") rescue puts("#{label}: #{$!.class}: #{$!.message} #{$!.backtrace_locations.first(3).map(&:label).inspect}")
s = S.new(1, "two"); d = D.new(1, "two")
2000.times { [s, d].each { |o| plain(o); caller_has_block(o) { raise "must not be called" }; with_block(o); pass_block(o); pass_block(o) { |k, v| [v, k] }; keys(o, %i[a b]); keys(o, nil); keys_caller_block(o) { raise "no" }; match(o) } }
3.times do
  [s, d].each do |o|
    report("#{o.class} to_h") { [plain(o), caller_has_block(o) { raise "must not be called" }, with_block(o), pass_block(o), pass_block(o) { |k, v| [v, k] }, plain(o).equal?(plain(o)), plain(o).frozen?] }
    report("#{o.class} deconstruct_keys") { [keys(o, %i[a b]), keys(o, [:b]), keys(o, [:zz, :a]), keys(o, %i[a b c]), keys(o, []), keys(o, nil), keys_caller_block(o) { raise "no" }, match(o)] }
    report("#{o.class} deconstruct_keys, string / integer keys") { [keys(o, ["a"]), (keys(o, [0]) rescue $!.class), (keys(o, [Key.new]) rescue $!.class), $seen] }
    report("#{o.class} deconstruct_keys, not an array") { keys(o, :a) }
  end
end
ObjectSpace.trace_object_allocations do
  report("allocation tracing") { [plain(s), keys(s, [:a]), plain(d), keys(d, nil)].map { ObjectSpace.allocation_method_id(_1) } }
end
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { plain(s); keys(d, [:a]) }
report("traced") { events }
GC.stress = true; ok = 30.times.all? { |i| t = S.new("k#{i}", [i]); plain(t) == {a: "k#{i}", b: [i]} && keys(t, [:b]) == {b: [i]} && match(D.new(i, "v#{i}")) == [i, "v#{i}"] }; GC.stress = false
report("gc stress") { ok }
D.class_eval { def to_h = {late: true} }
report("redefined") { [plain(d), keys(d, nil)] }

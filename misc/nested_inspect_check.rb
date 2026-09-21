# inspect of structs holding structs: every shape of nesting, and everything that must keep
# a nested struct from being written in place.
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message.gsub(/0x\h+/, '0x')}")
def describe(str) = [str, str.encoding.to_s, str.bytesize, str.frozen?]
In = Struct.new(:a, :b); Out = Struct.new(:x, :y); DIn = Data.define(:a, :b); DOut = Data.define(:x, :y)
Custom = Struct.new(:a) { def inspect = "custom(#{a})" }
CustomToS = Struct.new(:a) { def to_s = "to_s(#{a})" }
SubIn = Class.new(In); Named = Class.new(In); Anon = Struct.new(:a)
ÜStruct = Struct.new(:a); Uni = Struct.new(:"é")
Wide = Struct.new(*Array.new(30) { :"m#{_1}" })
def hot(o) = o.inspect
def hot_s(o) = o.to_s
300.times { hot(Out.new(In.new(1, 2), DIn.new(:a, nil))); hot(DOut.new(DIn.new(1, 2), 3)); hot_s(Out.new(In.new(1, 2), 3)) }
report("two levels") { [Out.new(In.new(1, "two"), DIn.new(:a, nil)), DOut.new(In.new(1.5, -2), DOut.new(1, 2))].map { describe(hot(_1)) } }
report("to_s") { describe(hot_s(Out.new(In.new(1, 2), DIn.new(3, 4)))) }
deep = (1..6).inject(In.new(0, :leaf)) { |acc, i| Out.new(i, acc) }
report("six levels") { describe(hot(deep)) }
report("custom inspect inside") { [Out.new(Custom.new(1), 2), Out.new(In.new(Custom.new(1), 2), 3), DOut.new(CustomToS.new(1), 2)].map { hot(_1) } }
report("subclass, anonymous, non-ASCII names inside") { [Out.new(SubIn.new(1, 2), Anon.new(3)), Out.new(ÜStruct.new(1), Uni.new(2)), Out.new(Class.new(In).new(1, 2), 3)].map { describe(hot(_1)) } }
report("non-leaf members inside") { [Out.new(In.new([1, 2], { k: 1 }), 2), Out.new(In.new(Object.new.then { |o| def o.inspect = "obj"; o }, 1), 2), Out.new(In.new(1..2, 3), nil)].map { hot(_1) } }
a = In.new(1, nil); b = Out.new(a, 2); a.b = b
report("cycle through a nested struct") { [hot(b), hot(a)] }
shared = In.new(1, 2)
report("same struct twice") { hot(Out.new(shared, shared)) }
self_ref = In.new(1, nil); self_ref.b = self_ref
report("self reference") { [hot(self_ref), hot(Out.new(self_ref, 1))] }
report("wide and long") { describe(hot(Out.new(Wide.new(*0...30), Out.new("s" * 300, Wide.new)))).values_at(1, 2) }
report("strings with encodings inside") { [Out.new(In.new("é", "日本".encode("EUC-JP")), In.new("\xff".b, :"é"))].map { describe(hot(_1)) } }
report("inside an Array / Hash") { [[Out.new(In.new(1, 2), 3)].inspect, { k: DOut.new(DIn.new(1, 2), 3) }.inspect] }
class In; alias_method :orig_inspect, :inspect; def inspect = "redefined"; end
report("inspect of the inner class redefined") { hot(Out.new(In.new(1, 2), DIn.new(3, 4))) }
class In; alias_method :inspect, :orig_inspect; end
report("alias restored") { hot(Out.new(In.new(1, 2), 3)) }
class Integer; alias_method :orig_inspect, :inspect; def inspect = "int"; end
report("Integer#inspect redefined") { hot(Out.new(In.new(1, 2), 3)) }
class Integer; alias_method :inspect, :orig_inspect; end
events = []
TracePoint.new(:c_call) { |tp| events << tp.method_id if tp.method_id == :inspect }.enable { hot(Out.new(In.new(1, 2), 3)) }
report("traced") { events }
300.times { hot(Out.new(In.new(1, 2), 3)) }
GC.stress = true; ok = 15.times.all? { |i| hot(Out.new(In.new("s#{i}", [i].size), DIn.new(i * 1.5, :"y#{i}"))) == "#<struct Out x=#<struct In a=\"s#{i}\", b=1>, y=#<data DIn a=#{i * 1.5}, b=:y#{i}>>" }; GC.stress = false
report("gc stress") { ok }

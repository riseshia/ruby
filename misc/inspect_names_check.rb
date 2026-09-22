# Struct#inspect around the per-class cache of member name texts: classes that cannot take
# an ivar, names that are not plain, classes shared across Ractors and boxes.
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message.gsub(/0x\h+/, '0x')}")
Frozen = Struct.new(:a, :b).freeze
FrozenD = Data.define(:a).freeze
Odd = Struct.new(:"a b", :"c-d", :e)
Op = Data.define(:+, :"[]", :ok?)
Const = Struct.new(:A, :b)
Uni = Struct.new(:"é", :"日本")
Dyn = Struct.new("x#{1 + 1}".to_sym, :y)
Sub = Class.new(Struct.new(:p, :q))
SubSub = Class.new(Sub)
Plain = Struct.new(:x, :y)
report("frozen class") { [Frozen.new(1, 2).inspect, FrozenD.new(1).inspect, Frozen.instance_variables, Frozen.frozen?] }
report("odd names") { [Odd.new(1, 2, 3).inspect, Op.new(1, 2, 3).inspect, Const.new(1, 2).inspect, Uni.new(1, 2).inspect, Dyn.new(1, 2).inspect] }
report("subclasses") { [Sub.new(1, 2).inspect, SubSub.new(3, 4).inspect, Sub.instance_variables, SubSub.instance_variables] }
class Symbol; alias_method :orig_inspect, :inspect; def inspect = "SYM(#{to_s})"; end
report("Symbol#inspect redefined") { [Odd.new(1, 2, 3).inspect, Plain.new(1, 2).inspect] }
class Symbol; alias_method :inspect, :orig_inspect; end
report("restored") { [Odd.new(1, 2, 3).inspect, Plain.new(1, 2).inspect] }
report("instance_variables stay hidden") { [Plain.instance_variables, Plain.instance_variable_defined?(:@x), (Plain.instance_variable_get(:__inspect_names__) rescue $!.class)] }
report("class frozen after first inspect") { k = Struct.new(:m); k.new(1).inspect; k.freeze; [k.new(2).inspect, k.frozen?] }
report("shareable class") { k = Struct.new(:m); Ractor.make_shareable(k); [k.new(1).inspect, k.new(2).inspect] }
r = Ractor.new { k = Struct.new(:rx, :ry); [k.new(1, 2).inspect, k.new(3, 4).inspect, Plain.new(5, 6).inspect, Sub.new(7, 8).inspect] }
report("inspect in another Ractor") { r.respond_to?(:value) ? r.value : r.take }
report("after the Ractor, in main") { [Plain.new(1, 2).inspect, Sub.new(1, 2).inspect] }
GC.stress = true; ok = 20.times.all? { |i| k = Struct.new(:"g#{i}"); k.new(i).inspect == "#<struct g#{i}=#{i}>" && Plain.new(i, [i]).inspect == "#<struct Plain x=#{i}, y=[#{i}]>" }; GC.stress = false
report("gc stress with fresh classes") { ok }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [Plain.new(1, 2).inspect, Odd.new(1, 2, 3).inspect] }

# Struct classes' [] (positional and keyword) against master: results, errors, backtraces, events
require "objspace"
def show(*a) = puts(a.map(&:inspect).join(" "))
def err = (yield; :no_error) rescue [$!.class, $!.message, $!.backtrace.first(3).map { _1.sub(/:\d+:in/, ":in") }]
S = Struct.new(:a, :b, :c); SK = Struct.new(:a, :b, :c, keyword_init: true); SF = Struct.new(:a, :b, keyword_init: false)
class Sub < S; end
class Init < S; def initialize(*a, **k) = (super; self.c = :init); end
3.times do
  show S[1, 2, 3], S[1], S[], S[a: 1, c: 3], S[{a: 1}], SK[a: 1, b: 2], SK[], Sub[1, 2], Sub[a: 9], Init[1, 2], Init[a: 1]
  show SF[{a: 1}], SF[{a: 1}, 2], (SF[a: 1] rescue $!.class)
  show err { S[1, 2, 3, 4] }, err { S[a: 1, z: 2] }, err { SK[1, 2] }, err { SK[a: 1, "b" => 2] }, err { S[a: 1, "b" => 2] }
  show err { S[*Array.new(3)] }, S[*[1, 2]], S[**{a: 1}], S[**{}], SK[**{c: 3}]
  h = {a: 1, b: 2}; o = S[**h]; h[:a] = 99; show o, h
  show S.method(:new) == S.method(:[]), S.method(:new).unbind == S.method(:[]).unbind, Struct.new(:x).method(:[]) == Class.instance_method(:new).bind(Struct.new(:y)), S.method(:[]).arity, S.method(:[]).owner.inspect.sub(/0x\h+/, "X"), S.method(:[]).name
  show ObjectSpace.trace_object_allocations { o = S[1, 2, 3]; [ObjectSpace.allocation_method_id(o), ObjectSpace.allocation_class_path(o)] }
  show ObjectSpace.trace_object_allocations { o = S[a: 1]; ObjectSpace.allocation_method_id(o) }
  ev = []; TracePoint.new(:c_call, :c_return, :call) { |t| ev << [t.event, t.method_id] }.enable { S[1, 2]; S[a: 1]; SK[a: 1] }; show ev
  # initialize redefined after use; [] redefined on the class
  k = Struct.new(:x); k[1]; k.class_eval { def initialize(*) = (super; self.x = :redef) }; show k[1], k[x: 1]
  k2 = Struct.new(:x); def k2.[](*a) = :own; show k2[1]
  m = Module.new { def initialize(*a, **kw) = (super; self.a = :prepended) }; k3 = Struct.new(:a); k3[1]; k3.prepend(m); show k3[1], k3[a: 2]
  # block given, frozen class, big struct
  show S[1] { :blk }, Struct.new(*(:a..:z)).then { |w| w[*1..26].to_a.sum }, Struct.new(*(:a..:z)).then { |w| w[**(:a..:z).each_with_index.to_h].to_a.sum }
  fk = Struct.new(:a).freeze; show fk[1], fk[a: 2]
  # GC stress
  GC.stress = true; show S[+"x", [1], {}], S[a: +"y"], SK[b: [2]]; GC.stress = false
end

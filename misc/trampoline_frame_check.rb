# Data.new with an initialize written in Ruby: every way control can leave initialize, and
# everything that can look at the frame of new while it runs.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message} #{$!.backtrace_locations.first(4).map(&:label).inspect}")
Plain = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
Peek = Data.define(:x) { def initialize(x:) = ($seen = [caller_locations(0, 4).map(&:label), caller(0, 3).map { _1[/in .*/] }, __method__]; super) }
Raise = Data.define(:x) { def initialize(x:) = raise(ArgumentError, "bad #{x}") }
Rescue = Data.define(:x) { def initialize(x:) = (begin; raise "inner"; rescue => e; super(x: e.message); end) }
Ensure = Data.define(:x) { def initialize(x:) = (begin; super; ensure; $ensured = true; end) }
EarlyReturn = Data.define(:x) { def initialize(x:) = (return if x.nil?; super) }
BlockReturn = Data.define(:x) { def initialize(x:) = ([1].each { return if x == :bail }; super) }
ProcReturn = Data.define(:x) { def initialize(x:) = (pr = proc { return }; pr.call if x == :bail; super) }
Throw = Data.define(:x) { def initialize(x:) = (throw :out, :thrown if x == :bail; super) }
Break = Data.define(:x) { def initialize(x:) = super(x: [1, 2, 3].each { |v| break v * x }) }
Nested = Data.define(:x) { def initialize(x:) = super(x: x > 0 ? Nested.new(x: x - 1) : :leaf) }
Yielder = Data.define(:x) { def initialize(x:) = super(x: Fiber.yield(x)) }
Binding = Data.define(:x) { def initialize(x:) = ($b = binding; super) }
Alloc = Data.define(:x) { def initialize(x:) = super(x: [x]) }
Tailish = Data.define(:x) { def initialize(x:) = helper(x); def helper(x) = nil }
Missing = Data.define(:x, :y) { def initialize(x:, y:) = super }
Deep = Data.define(:x) { def initialize(x:) = super(x: x.zero? ? caller.size : Deep.new(x: x - 1).x) }
def make(k, **kw) = k.new(**kw)
def lit(k) = k.new(x: 1)
def pos(k) = k.new(1)
3.times do |round|
  [Plain, Peek, Rescue, Ensure, EarlyReturn, BlockReturn, ProcReturn, Throw, Break, Alloc].each { |k| 300.times { lit(k); pos(k) } } if round > 0
  report("plain") { [Plain.new(x: 1), Plain.new(x: 1, y: 2), Plain.new(1), Plain.new(1, 2), lit(Plain), pos(Plain), Plain.new(x: 1).frozen?] }
  report("frames seen from initialize") { lit(Peek); $seen }
  report("frames seen, positional") { pos(Peek); $seen }
  report("raise") { lit(Raise) }
  report("raise, positional") { pos(Raise) }
  report("rescue inside") { lit(Rescue) }
  report("ensure inside") { $ensured = false; [lit(Ensure), $ensured] }
  report("early return") { [EarlyReturn.new(x: nil), EarlyReturn.new(x: nil).frozen?, EarlyReturn.new(x: 1)] }
  report("return from a block") { [BlockReturn.new(x: :bail), BlockReturn.new(x: 1)] }
  report("return from a proc") { [ProcReturn.new(x: :bail), ProcReturn.new(x: 1)] }
  report("throw") { [catch(:out) { Throw.new(x: :bail) }, Throw.new(x: 1)] }
  report("break inside") { Break.new(x: 5) }
  report("nested new") { Nested.new(x: 3) }
  report("stack depth") { Deep.new(x: 5).x - caller.size }
  report("missing keyword") { Missing.new(x: 1) }
  report("unknown keyword") { Plain.new(x: 1, z: 2) }
  report("too many positional") { Plain.new(1, 2, 3) }
  report("helper call") { Tailish.new(x: 1) }
  report("binding") { lit(Binding); [$b.local_variables, $b.receiver.class, $b.eval("x")] }
  f = Fiber.new { Yielder.new(x: 1) }
  report("fiber suspended inside initialize") { [f.resume, Plain.new(x: 9), f.resume(:resumed), f.alive?] }
  abandoned = Fiber.new { Yielder.new(x: 1) }; abandoned.resume
  report("after an abandoned fiber") { lit(Plain) }
  report("thread") { Thread.new { [lit(Plain), (lit(Raise) rescue $!.message)] }.value }
  report("via send / public_send / method") { [Plain.send(:new, x: 1), Plain.public_send(:new, 1), Plain.method(:new).call(x: 2), Plain.method(:new).to_proc.call(3)] }
  report("splat forms") { h = {x: 1}; a = [1, 2]; [Plain.new(**h), Plain.new(*a), make(Plain, x: 4)] }
  report("block passed to new") { Plain.new(x: 1) { :ignored } }
end
ObjectSpace.trace_object_allocations { o = lit(Alloc); report("allocation tracing") { [ObjectSpace.allocation_method_id(o), ObjectSpace.allocation_method_id(o.x)] } }
events = []
TracePoint.new(:c_call, :c_return, :call, :return) { |tp| events << [tp.event, tp.method_id] }.enable { lit(Plain) }
report("traced") { events }
Late = Data.define(:x) { def initialize(x:) = ($tp = TracePoint.new(:c_return) { |tp| $late << [tp.method_id, tp.return_value.class] if tp.method_id == :new }; $tp.enable; super) }
$late = []; Late.new(x: 1); $tp.disable
report("c_return enabled inside initialize") { $late }
GC.stress = true; ok = 25.times.all? { |i| lit(Alloc).x == [1] && pos(Plain).y == 0 && (lit(Raise) rescue true) && BlockReturn.new(x: :bail).x.nil? }; GC.stress = false
report("gc stress") { ok }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [lit(Plain), pos(Peek).x] }
c = callcc_available = (require "continuation"; true) rescue false
if callcc_available
  K = Data.define(:x) { def initialize(x:) = (callcc { |k| $k = k }; super(x: $count += 1)) }
  $count = 0; first = K.new(x: 0); $k.call if $count < 3
  report("continuation re-entering initialize") { [$count, first.x] }
end

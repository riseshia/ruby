# Data.new with an initialize written in Ruby, from call sites a JIT compiles: the receiver is a
# constant and every site is hot before it is looked at. Run with a low call threshold.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message} #{$!.backtrace_locations.first(4).map(&:label).inspect}")

Plain = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
Zsuper = Data.define(:x, :y) { def initialize(x:, y: 0) = super }
Coerce = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x: x + 1, y: y.to_s) }
Peek = Data.define(:x) { def initialize(x:) = ($seen = [caller_locations(0, 4).map(&:label), __method__]; super) }
Raise = Data.define(:x) { def initialize(x:) = (raise(ArgumentError, "bad #{x}") if x == :bad; super) }
Rescue = Data.define(:x) { def initialize(x:) = (begin; raise "inner" if x == :bad; super; rescue => e; super(x: e.message); end) }
EarlyReturn = Data.define(:x) { def initialize(x:) = (return if x.nil?; super) }
BlockReturn = Data.define(:x) { def initialize(x:) = ([1].each { return if x == :bail }; super) }
Throw = Data.define(:x) { def initialize(x:) = (throw :out, :thrown if x == :bail; super) }
Nested = Data.define(:x) { def initialize(x:) = super(x: x > 0 ? Nested.new(x: x - 1) : :leaf) }
Alloc = Data.define(:x) { def initialize(x:) = super(x: [x, x.to_s]) }
Rest = Data.define(:x, :y) { def initialize(**kw) = super(**kw.transform_values { _1 * 2 }) }
HashArg = Data.define(:x) { def initialize(h) = super(x: h) }
Optional = Data.define(:x, :y) { def initialize(x:, y: x * 10) = super }
Extra = Data.define(:x) { def initialize(x:, scale: 1) = super(x: x * scale) }
Poly = Data.define(:x) { def initialize(x:) = super(x: x + x) }
Traced = Data.define(:x) { def initialize(x:) = ($tp&.enable; super) }
Redefined = Data.define(:x) { def initialize(x:) = super(x: [:first, x]) }

def plain_kw(i) = Plain.new(x: i, y: 2)
def plain_swapped(i) = Plain.new(y: 2, x: i)
def plain_default(i) = Plain.new(x: i)
def plain_pos(i) = Plain.new(i, 2)
def plain_pos1(i) = Plain.new(i)
def plain_unknown(i) = Plain.new(x: i, z: 1)
def plain_missing(i) = Plain.new(y: i)
def plain_too_many(i) = Plain.new(i, 2, 3)
def zsuper_kw(i) = Zsuper.new(x: i, y: 2)
def coerce_kw(i) = Coerce.new(x: i, y: 2)
def peek_kw(i) = Peek.new(x: i)
def peek_pos(i) = Peek.new(i)
def raise_kw(v) = Raise.new(x: v)
def rescue_kw(v) = Rescue.new(x: v)
def early(v) = EarlyReturn.new(x: v)
def block_return(v) = BlockReturn.new(x: v)
def thrower(v) = Throw.new(x: v)
def nested(i) = Nested.new(x: i)
def alloc(i) = Alloc.new(x: i)
def rest(i) = Rest.new(x: i, y: 3)
def hash_arg(i) = HashArg.new(x: i)
def optional(i) = Optional.new(x: i)
def extra(i) = Extra.new(x: i, scale: 3)
def poly(v) = Poly.new(x: v)
def traced(i) = Traced.new(x: i)
def redefined(i) = Redefined.new(x: i)
def rescued_at_caller(v) = (begin; Raise.new(x: v); rescue ArgumentError => e; [:caught, e.message]; end)
def ensured_at_caller(v) = (begin; Raise.new(x: v); ensure; $ensured += 1; end)

HOT = %i[plain_kw plain_swapped plain_default plain_pos plain_pos1 zsuper_kw coerce_kw peek_kw peek_pos nested alloc rest optional extra traced redefined]
def warm = 400.times { |i| HOT.each { send(_1, i % 5) }; raise_kw(1); rescue_kw(1); early(1); block_return(1); thrower(1); poly(1); hash_arg(i) rescue nil; rescued_at_caller(1); ensured_at_caller(1) }
$ensured = 0
warm

report("keywords") { [plain_kw(1), plain_swapped(2), plain_default(3), plain_kw(1).frozen?] }
report("positional") { [plain_pos(1), plain_pos1(2)] }
report("zsuper") { zsuper_kw(7) }
report("initialize changes the values") { coerce_kw(7) }
report("frames seen from initialize") { peek_kw(1); $seen }
report("frames seen, positional") { peek_pos(1); $seen }
report("unknown keyword") { plain_unknown(1) }
report("missing keyword") { plain_missing(1) }
report("too many positional") { plain_too_many(1) }
report("raise from hot initialize") { raise_kw(:bad) }
report("rescue inside hot initialize") { [rescue_kw(:bad), rescue_kw(2)] }
report("rescue at the caller") { [rescued_at_caller(:bad), rescued_at_caller(3)] }
report("ensure at the caller") { before = $ensured; [(ensured_at_caller(:bad) rescue :raised), $ensured - before] }
report("early return") { [early(nil), early(nil).frozen?, early(1)] }
report("return from a block") { [block_return(:bail), block_return(1)] }
report("throw") { [catch(:out) { thrower(:bail) }, thrower(1)] }
report("nested new") { nested(4) }
report("allocating initialize") { alloc(5) }
report("keyword rest") { rest(4) }
report("positional hash parameter") { hash_arg(1) }
report("optional keyword default") { optional(4) }
report("keyword that is not a member") { extra(5) }
# The callee leaves compiled code: an argument type it has not seen
report("side exit inside initialize") { [poly("ab"), poly(2.5), poly([1]), poly(3)] }
report("side exit inside initialize, raising") { poly(nil) }
report("after the side exits") { [poly(4), plain_kw(9)] }

$late = []
$tp = TracePoint.new(:c_return) { |tp| $late << [tp.method_id, tp.return_value.class] if tp.method_id == :new }
report("c_return enabled inside initialize") { o = traced(1); $tp.disable; [o, $late] }
$tp = nil
report("after tracing") { [traced(2), plain_kw(3)] }

events = []
TracePoint.new(:c_call, :c_return, :call, :return) { |tp| events << [tp.event, tp.method_id] }.enable { plain_kw(1) }
report("traced call") { events }
warm

ObjectSpace.trace_object_allocations { o = alloc(1); report("allocation tracing") { [ObjectSpace.allocation_method_id(o), ObjectSpace.allocation_method_id(o.x)] } }
warm

GC.stress = true
ok = 30.times.all? { |i| alloc(i).x == [i, i.to_s] && plain_pos(i).y == 2 && (raise_kw(:bad) rescue true) && block_return(:bail).x.nil? && nested(2).x.x.x == :leaf }
GC.stress = false
report("gc stress") { ok }
GC.compact if GC.respond_to?(:compact)
GC.verify_internal_consistency
report("after compaction") { [plain_kw(1), peek_pos(2).x, alloc(3)] }

class Redefined; def initialize(x:) = super(x: [:second, x]); end
report("initialize redefined") { redefined(1) }
class Redefined; remove_method :initialize; end
report("initialize removed") { redefined(2) }
class << Plain; alias_method :original_new, :new; def new(*, **) = :singleton_new; end
report("new redefined") { [plain_kw(1), plain_pos(1)] }
class << Plain; alias_method :new, :original_new; end
report("new restored") { [plain_kw(1), plain_pos(1)] }

Deep = Data.define(:x) { def initialize(x:) = super(x: x.zero? ? 0 : Deep.new(x: x - 1).x + 1) }
def deep(n) = Deep.new(x: n)
300.times { deep(3) }
report("recursion") { deep(200).x }
report("stack overflow") { begin; deep(1_000_000); rescue SystemStackError => e; e.class; end }
report("after stack overflow") { [deep(5).x, plain_kw(1)] }

threads = 4.times.map { |t| Thread.new { 2000.times.map { |i| plain_kw(i).x + alloc(i).x[0] + nested(1).x.x.size }.sum } }
report("threads") { threads.map(&:value) }
f = Fiber.new { Data.define(:x) { def initialize(x:) = super(x: Fiber.yield(x)) }.new(x: 1) }
report("fiber") { [f.resume, plain_kw(1), f.resume(:resumed)] }

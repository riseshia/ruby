# Prints what a Ruby program can observe about Array#== / eql? / hash and Arrays used as Hash keys.
# Run it with a baseline and a patched build: the two outputs must be identical.

require "set"

def section(title) = puts("\n== #{title}")

def report(label)
  value = yield
  puts "  #{label}: #{value.inspect}"
rescue SystemStackError => error
  puts "  #{label}: #{error.class}"
rescue => error
  puts "  #{label}: #{error.class}: #{error.message}"
  puts "    backtrace labels: #{error.backtrace_locations.first(4).map(&:label).inspect}"
end

def trace_events(label)
  events = []
  tracer = TracePoint.new(:c_call, :c_return, :call, :return) { |tp| events << "#{tp.event} #{tp.defined_class.inspect}##{tp.method_id}" }
  tracer.enable { yield }
  puts "  #{label}:"
  events.each { puts "    #{_1}" }
end

class Noisy
  attr_reader :name
  def initialize(name, answer = true, &on_use) = (@name, @answer, @on_use = name, answer, on_use)
  def ==(other) = (puts "    #{@name} == #{other.respond_to?(:name) ? other.name : other.inspect}"; @on_use&.call; @answer)
  def eql?(other) = (puts "    #{@name} eql? #{other.name}"; @on_use&.call; @answer)
  def hash = (puts "    #{@name} hash"; @on_use&.call; 7)
end

class ArrayLike
  def initialize(items) = @items = items
  def to_ary = @items
  def ==(other) = (puts "    ArrayLike#== called with #{other.inspect}"; @items == other)
end

class LoudArray < Array
  def ==(other) = (puts "    LoudArray#=="; super)
  def hash = (puts "    LoudArray#hash"; super)
end

nan = Float::NAN

section "== and eql? on plain values"
report("equal") { [[1, "x", :s] == [1, "x", :s], [1, "x", :s].eql?([1, "x", :s])] }
report("unequal") { [[1, "x"] == [1, "y"], [1, "x"].eql?([2, "x"])] }
report("empty / different length") { [[] == [], [].eql?([]), [1] == [1, 2], [1, 2] == [1]] }
report("same NaN object / different NaN") { [[nan] == [nan], [0.0 / 0.0] == [0.0 / 0.0], [nan].eql?([nan])] }
report("0.0 and -0.0") { [[0.0] == [-0.0], [0.0].eql?([-0.0])] }
report("1 and 1.0") { [[1] == [1.0], [1].eql?([1.0]), [1.0] == [1]] }
report("bignum, rational, complex") { [[2**80] == [2**80], [1r] == [1], [Complex(1, 0)] == [1]] }
report("encodings") { [["é"] == ["é".b], ["a"] == ["a".b]] }
report("nested") { [[[1, [2, [3]]]] == [[1, [2, [3]]]], [[1, [2, [3]]]] == [[1, [2, [4]]]], [[1, [2]]].eql?([[1, [2]]])] }
report("frozen and shared") { a = [1, 2, 3].freeze; b = a.dup; [a == b, a == a[0..], a.eql?(b)] }
report("not an Array") { [[1] == 1, [1] == nil, [1].eql?(1), [1] == "1"] }
report("to_ary on the right") { [1, 2] == ArrayLike.new([1, 2]) }
report("subclass with ==") { [LoudArray[1, 2] == [1, 2], [1, 2] == LoudArray[1, 2]] }
report("large equal / large differing at the end") { a = Array.new(1000) { _1 }; b = a.dup; c = a.dup; c[-1] = :x; [a == b, a == c] }

section "elements with their own =="
report("noisy second element") { [1, Noisy.new("left")] == [1, Noisy.new("right")] }
report("noisy first element, second differs") { [Noisy.new("left"), 1] == [Noisy.new("right"), 2] }
report("first differs, noisy never asked") { [1, Noisy.new("left")] == [2, Noisy.new("right")] }
report("noisy eql?") { [1, Noisy.new("left")].eql?([1, Noisy.new("right")]) }
report("noisy says false") { [Noisy.new("left", false), 1] == [Noisy.new("right"), 1] }
report("element == shrinks the arrays") do
  left = [nil, 2, 3]
  right = [nil, 2, 3]
  left[0] = Noisy.new("left") { left.pop; right.pop }
  right[0] = Noisy.new("right")
  [left == right, left.size]
end
report("element == empties the left array") do
  left = [nil, 2]
  right = [nil, 2]
  left[0] = Noisy.new("left") { left.clear }
  right[0] = Noisy.new("right")
  left == right
end

section "recursion"
report("recursive ==") { a = [1]; a << a; b = [1]; b << b; [a == b, a.eql?(b), a == a] }
report("recursive, differing leaf") { a = [1]; a << a; b = [2]; b << b; a == b }
report("mutually recursive") { a = [1]; b = [1]; a << b; b << a; [a == b, a.eql?(b)] }
report("recursive through Hash") { a = [1, {}]; a[1][:k] = a; b = [1, {}]; b[1][:k] = b; a == b }
report("recursive hash value") { a = [1]; a << a; a.hash == a.hash }
report("element == turns the pair into plain values and re-enters") do
  left = [1, nil]
  right = [1, nil]
  left[1] = Noisy.new("left") { left[1] = 5; right[1] = 6; puts "    re-entered: #{left == right}" }
  right[1] = Noisy.new("right")
  left == right
end
report("element eql? re-enters") do
  left = [1, nil]
  right = [1, nil]
  left[1] = Noisy.new("left") { left[1] = 5; right[1] = 6; puts "    re-entered: #{left.eql?(right)}" }
  right[1] = Noisy.new("right")
  left.eql?(right)
end

section "Arrays as Hash keys"
report("lookup") { [{[1, "k"] => :found}[[1, "k"]], {[1, "k"] => :found}[[1, "j"]], {[] => :empty}[[]]] }
report("nested key") { {[1, [2, [3, :s]]] => :found}[[1, [2, [3, :s]]]] }
report("hash agrees with lookup") { a = [1, "k", :s, 2.5, nil, true, 2**70]; [a.hash == a.dup.hash, {a => 1}.key?(a.dup)] }
report("float keys") { [{[0.0] => 1}[[-0.0]], {[nan] => 1}[[nan]], {[1] => 1}[[1.0]]] }
report("noisy element in key") { {[1, Noisy.new("stored")] => :found}[[1, Noisy.new("probe")]] }
report("subclass with hash") { {LoudArray[1, 2] => :found}[LoudArray[1, 2]] }
report("frozen key, mutated key") { k = [1, 2]; h = {k => :v}; k << 3; [h[[1, 2]], h[[1, 2, 3]], h.rehash[[1, 2, 3]]] }
report("compare_by_identity") { k = [1, 2]; h = {}.compare_by_identity; h[k] = :v; [h[k], h[[1, 2]]] }
report("uniq, Set, group_by, -, &, |") do
  pairs = [[1, 2], [1, 2], [3, 4]]
  [pairs.uniq, Set.new(pairs).size, pairs.group_by(&:itself).keys, pairs - [[1, 2]], pairs & [[3, 4]], pairs | [[5]]]
end
report("tally and include?") { [[[1], [1], [2]].tally, [[1, 2], [3]].include?([1, 2]), [[1, 2], [3]].index([3])] }
report("element hash empties its array and re-hashes it") do
  owner = [1, nil]
  member = Object.new
  member.define_singleton_method(:hash) { owner[1] = 2; puts "    re-hashed: #{({owner => 1}.size)}"; 9 }
  owner[1] = member
  {owner => 1}.size
end
report("element hash looks another array key up") do
  other = {[5, 6] => :inner}
  member = Object.new
  member.define_singleton_method(:hash) { puts "    inner lookup: #{other[[5, 6]]}"; 9 }
  {[1, member] => :outer}.size
end
trace_events("lookup traced") { {[1, 2] => 1}[[1, 2]] }
trace_events("== traced") { [1, 2] == [1, 2] }

section "in other contexts"
report("in a Fiber") { Fiber.new { [[1, 2] == [1, 2], {[1] => :v}[[1]]] }.resume }
report("in a Thread") { Thread.new { [[1, 2] == [1, 3], {[1] => :v}[[1]]] }.value }
report("inside an outer comparison") do
  inner = nil
  probe = Noisy.new("outer") { inner = [[7, 8] == [7, 8], [7, 8] == [7, 9], {[7] => :v}[[7]]] }
  [[probe] == [Noisy.new("other")], inner]
end

section "Integer#== and Array#hash redefined"
class Integer
  alias_method :__probe_eq, :==
  def ==(other) = (puts "    Integer#== #{self} #{other}"; __probe_eq(other))
end
report("after Integer#==") { [[1, 2] == [1, 2], [1, 2] == [1, 3]] }
class Array
  alias_method :__probe_hash, :hash
  def hash = (puts "    Array#hash redefined"; __probe_hash)
end
report("after Array#hash") { {[1, 2] => :found}[[1, 2]] }

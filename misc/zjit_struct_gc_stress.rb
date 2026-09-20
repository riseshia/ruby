# Exercises JIT-allocated Struct / Data instances under GC pressure: young members held by the
# instance must survive, instances must compact, and values must stay what was stored.
require "objspace"
Pair = Struct.new(:left, :right)
Triple = Struct.new(:a, :b, :c)
Frozen = Data.define(:left, :right)
class Sub < Pair; end

def make_pair(i) = Pair.new("left #{i}", [i, i.to_s])
def make_partial(i) = Triple.new("only #{i}")
def make_sub(i) = Sub.new(i, "sub #{i}")
def make_data(i) = Frozen.new("data #{i}", [i])

kept = []
30_000.times do |i|
  pair = make_pair(i)
  partial = make_partial(i)
  sub = make_sub(i)
  data = make_data(i)
  kept << [pair, partial, sub, data] if i % 100 == 0
  GC.start if i % 5_000 == 0
  GC.compact if i % 10_000 == 0 && GC.respond_to?(:compact)
end
GC.stress = true
200.times { |i| kept << [make_pair(-i), make_partial(-i), make_sub(-i), make_data(-i)] }
GC.stress = false
GC.start

bad = kept.reject { |pair, partial, sub, data|
  i = pair.right[0]
  pair.left == "left #{i}" && pair.right == [i, i.to_s] &&
    partial.to_a == ["only #{i}", nil, nil] &&
    sub.class == Sub && sub.to_a == [i, "sub #{i}"] &&
    data.left == "data #{i}" && data.right == [i] && data.frozen? && !pair.frozen?
}
pair = kept.last[0]
pair.instance_variable_set(:@tag, :t)
puts "kept=#{kept.size} bad=#{bad.size} memsize=#{ObjectSpace.memsize_of(pair)} ivar=#{pair.instance_variable_get(:@tag)} embedded=#{ObjectSpace.dump(pair)[/"embedded":\w+/]}"

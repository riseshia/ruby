# Several Ractors hammering construction, with, to_h, ==, hash and inspect of different Struct / Data
# classes at once: the per-ivar caches in struct.c are process-wide and the classes have different shapes.
Warning[:experimental] = false
CLASSES = 6.times.map { |k| [Struct.new(*(0..k + 1).map { :"s#{k}_#{_1}" }), Data.define(*(0..k + 1).map { :"d#{k}_#{_1}" }),
                             Class.new(Struct.new(:x, :y, keyword_init: true)) { def initialize(x:, y: 0) = super }] }.freeze
Ractor.make_shareable(CLASSES)
ractors = 6.times.map do |r|
  Ractor.new(r) do |seed|
    bad = 0
    20_000.times do |i|
      s_class, d_class, k_class = CLASSES[(seed + i) % CLASSES.size]
      n = s_class.members.size
      values = Array.new(n) { |j| i + j }
      s = s_class.new(*values); d = d_class.new(*values); k = k_class.new(x: i)
      kw = d_class.members.zip(values).to_h
      bad += 1 unless s.to_a == values && d.to_h == kw && d_class.new(**kw) == d && d.with(d_class.members.last => -1).to_h.values.last == -1
      bad += 1 unless k.to_h == {x: i, y: 0} && s == s_class.new(*values) && s.hash == s_class.new(*values).hash && {d => 1}[d_class.new(*values)] == 1
      bad += 1 unless s.inspect.include?("#{s_class.members.first}=#{i}") && s.size == n && s[0] == i
    end
    bad
  end
end
puts "bad=#{ractors.sum(&:value)}"

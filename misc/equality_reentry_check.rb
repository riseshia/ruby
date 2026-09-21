# Struct#== / eql? when a member's == re-enters the comparison of the same pair, with and without
# mutating the structs or their values in between. The answers come from the recursion guard.
class Reenter
  def initialize(&blk) = @blk = blk
  def ==(other) = @blk.call
  alias eql? ==
  def hash = 0
end
S = Struct.new(:a, :b, :c); D = Data.define(:a, :b, :c)
results = []
# 1. plain re-entry
a = S.new(1, nil, 3); b = S.new(1, nil, 3)
a.b = Reenter.new { a == b }; b.b = Reenter.new { true }
results << [:reentry, a == b]
# 2. re-entry after mutating an earlier member of an unfrozen struct
a = S.new(1, nil, 3); b = S.new(1, nil, 3)
a.b = Reenter.new { a.a = 99; a == b }; b.b = Reenter.new { true }
results << [:mutated_slot, a == b, a.a]
# 3. re-entry after mutating an earlier String value in place
str = +"x"; a = S.new(str, nil, 3); b = S.new(+"x", nil, 3)
a.b = Reenter.new { str << "y"; a == b }; b.b = Reenter.new { true }
results << [:mutated_value, a == b]
# 4. the same with Data (slots cannot change) and a mutable String
str = +"x"; holder = []
a = D.new(str, Reenter.new { str << "y"; holder[0] == holder[1] }, 3); b = D.new(+"x", Reenter.new { true }, 3)
holder.replace([a, b])
results << [:data_mutated_value, a == b]
# 5. Data with frozen values: plain answers
results << [:data_frozen, D.new(1, :s, "f".freeze) == D.new(1, :s, "f".freeze), D.new(1, :s, "f".freeze) == D.new(2, :s, "f".freeze), D.new(1, :s, "f".freeze) == D.new(1, :t, "f".freeze), D.new(1, :s, "f".freeze) == D.new(1, :s, "g".freeze), D.new(1.5, 2**70, nil) == D.new(1.5, 2**70 + 1, nil)]
# 6. eql? variants
a = S.new(1, nil, 3); b = S.new(1, nil, 3)
a.b = Reenter.new { a.a = 99; a.eql?(b) }; b.b = Reenter.new { true }
results << [:eql_mutated_slot, a.eql?(b)]
results << [:eql, D.new(1, :s, 2.0).eql?(D.new(1, :s, 2.0)), D.new(1, :s, 2.0).eql?(D.new(1, :s, 2)), D.new(1, 1.0, 2).eql?(D.new(1, 1, 2)), D.new(1, 1.0, 2) == D.new(1, 1, 2)]
# 7. recursive structures
r1 = S.new(1, 2, nil); r1.c = r1; r2 = S.new(1, 2, nil); r2.c = r2
results << [:recursive, r1 == r2, r1 == S.new(1, 2, r1), r1.eql?(r2), r1.hash == r2.hash]
results.each { p _1 }
hot = [D.new(1, :s, "f".freeze), D.new(2, :s, "f".freeze)]
p 5000.times.map { |i| hot[0] == hot[i % 2] }.tally, 5000.times.map { |i| hot[0].eql?(hot[i % 2]) }.tally, hot.uniq.size, hot.include?(D.new(2, :s, "f".freeze)), hot.index(D.new(2, :s, "f"))

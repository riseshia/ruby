# A member's == / hash changes the struct and freezes it, then compares or hashes it again.
# master catches the inner call with the recursion guard; a fast path must not answer differently.
def show(*a) = puts(a.map(&:inspect).join(" "))
S = Struct.new(:a, :b)
[[1, 2], [1, "x".freeze]].each do |changed|
  s = S.new(1, nil); s2 = S.new(1, nil)
  m = Object.new
  m.define_singleton_method(:==) { |o| s.b = changed[1]; s2.b = 99; s.freeze; s2.freeze; show :inner, s == s2, s.eql?(s2); false }
  m.define_singleton_method(:eql?) { |o| s.b = changed[1]; s2.b = 99; show :inner_eql, s.eql?(s2); false }
  s.b = m; s2.b = Object.new
  show :outer, (s == s2 rescue $!.class)
end
owner = S.new(1, nil); member = Object.new
member.define_singleton_method(:hash) { owner.b = 2; owner.freeze; puts "  re-hashed: #{({owner => 1}.size)}"; 9 }
owner.b = member
show :hash_outer, ({owner => 1}.size rescue $!.class)
D = Data.define(:a, :b)
show :data, D.new(1, 2) == D.new(1, 3), {D.new(1, 2) => 1}[D.new(1, 2)]

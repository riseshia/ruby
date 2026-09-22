# Struct / Data as Hash keys: lookup, eql? calls, hash consistency (compare against master)
def show(*a) = puts(a.map(&:inspect).join(" "))
S = Struct.new(:a, :b); D = Data.define(:a, :b)
[S, D].each do |k|
  o = k.new(1, "x"); o2 = k.new(1, "x"); o3 = k.new(1, "y")
  h = { o => :one }
  show h[o2], h[o3], h.key?(o2), h.fetch(o2), o.hash == o2.hash, o.hash == o3.hash
  # hash under TracePoint c_call must give the same value and the same lookups
  tp_hash = nil; tp_val = nil
  TracePoint.new(:c_call) { |t| }.enable { tp_hash = o2.hash; tp_val = h[o2] }
  show tp_hash == o2.hash, tp_val
  ev = []; TracePoint.new(:c_call) { |t| ev << t.method_id if [:hash, :eql?, :==].include?(t.method_id) }.enable { h[o2] }; show ev
  # big hash (st table) and many keys
  big = {}; 40.times { |i| big[k.new(i, i.to_s)] = i }; show big[k.new(7, "7")], big[k.new(7, "8")], big.size
  # keys with members that need eql? calls
  m = { k.new([1, 2], 1.0) => :arr }; show m[k.new([1, 2], 1.0)], m[k.new([1, 2], 1)]
  # nil / mutable members, changed after insertion
  o4 = k.new(nil, nil); h2 = { o4 => 1 }; show h2[k.new(nil, nil)]
  if k == S
    o5 = S.new(1, 2); h3 = { o5 => 1 }; o5.a = 9; show h3[o5], h3[S.new(1, 2)], h3.rehash[o5]
  end
  # eql? overridden, ==, hash overridden
  sub = Class.new(k) { def eql?(o) = true; def hash = 0 }
  hs = { sub.new(1, 2) => :any }; show hs[sub.new(3, 4)]
  sub2 = Class.new(k) { def hash = 0 }
  hs2 = { sub2.new(1, 2) => :a }; show hs2[sub2.new(1, 2)], hs2[sub2.new(1, 3)]
  # class with singleton hash method
  sub3 = Class.new(k); def sub3.hash = 12345
  hs3 = { sub3.new(1, 2) => :a }; show hs3[sub3.new(1, 2)], sub3.new(1, 2).hash == sub3.new(1, 2).hash
  # recursive struct as key
  if k == S
    r = S.new(1, nil); r.b = r; hr = { r => 1 }; show hr[r], r.hash == r.hash
    r2 = S.new(1, nil); r2.b = r2; show hr[r2]
  end
  # compare_by_identity
  ci = {}.compare_by_identity; ci[o] = 1; show ci[o2], ci[o]
  # Symbol vs struct mix, frozen keys
  show({ o.freeze => 1 }[o2], { :a => 1, o => 2 }[o2])
end
show S.new(1, 2).eql?(S.new(1, 2)), S.new(1, 2).eql?(D.new(1, 2)), S.new(1, 2).eql?(S.new(1, 2.0)), S.new(1, 2) == S.new(1, 2.0)
show({ S.new(1, 2) => 1 }[S.new(1, 2.0)], { S.new(1, 2.0) => 1 }[S.new(1, 2.0)])

S = Struct.new(:x, :y, :z)
def run(o, n) = (i = 0; while i < n; case o; in {x:, y:} then x; end; i += 1; end)
o = S.new(1, 2, 3)
w = 0; while w < 200; run(o, 10); w += 1; end
run(o, 2_000_000)

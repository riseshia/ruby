# Tight construction loop for perf. Usage: ruby [--yjit] new_loop.rb class|struct|data [N]
class C2; def initialize(x, y) = (@x = x; @y = y); end
S2 = Struct.new(:x, :y); D2 = Data.define(:x, :y)
eval "def run(n) = (i = 0; while i < n; #{{"class" => "C2", "struct" => "S2", "data" => "D2"}.fetch(ARGV[0])}.new(1, 2); i += 1; end)"
w = 0; while w < 200; run(10); w += 1; end
run((ARGV[1] || 30_000_000).to_i)

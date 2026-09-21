# ns/op for the usual ways of overriding initialize. Usage: ruby [--yjit|--zjit] override_idioms.rb CELL
class CRest; attr_reader :x, :y; def initialize(*args) = (@x, @y = args); end
class COpt; attr_reader :x, :y; def initialize(x, y = 0) = (@x = x; @y = y); end
class CKwrest; attr_reader :x, :y; def initialize(**kw) = (@x = kw[:x]; @y = kw[:y]); end
SRest = Struct.new(:x, :y) { def initialize(*args) = super }
SRestExplicit = Struct.new(:x, :y) { def initialize(*args) = super(*args) }
SOpt = Struct.new(:x, :y) { def initialize(x, y = 0) = super }
SKwrest = Struct.new(:x, :y, keyword_init: true) { def initialize(**kw) = super }
SKwrestExplicit = Struct.new(:x, :y, keyword_init: true) { def initialize(**kw) = super(**kw) }
SKwDefaults = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y: 0) = super }
DKwrest = Data.define(:x, :y) { def initialize(**kw) = super }
DKwrestExplicit = Data.define(:x, :y) { def initialize(**kw) = super(**kw) }
DKwMerge = Data.define(:x, :y) { def initialize(**kw) = super(y: 0, **kw) }
DKwDefaults = Data.define(:x, :y) { def initialize(x:, y: 0) = super }
DPosConvert = Data.define(:x, :y) { def initialize(x:, y:) = super(x: Integer(x), y: Integer(y)) }
CELLS = {
  "class_rest" => "CRest.new(i, 2)", "struct_rest" => "SRest.new(i, 2)", "struct_rest_explicit" => "SRestExplicit.new(i, 2)",
  "class_opt" => "COpt.new(i, 2)", "struct_opt" => "SOpt.new(i, 2)", "struct_opt_default" => "SOpt.new(i)",
  "class_kwrest" => "CKwrest.new(x: i, y: 2)", "struct_kwrest" => "SKwrest.new(x: i, y: 2)", "struct_kwrest_explicit" => "SKwrestExplicit.new(x: i, y: 2)", "struct_kw_defaults" => "SKwDefaults.new(x: i)",
  "data_kwrest" => "DKwrest.new(x: i, y: 2)", "data_kwrest_explicit" => "DKwrestExplicit.new(x: i, y: 2)", "data_kwrest_pos" => "DKwrest.new(i, 2)", "data_kw_merge" => "DKwMerge.new(x: i)",
  "data_kw_defaults" => "DKwDefaults.new(x: i)", "data_convert" => "DPosConvert.new(i, 2)",
}
expr = CELLS.fetch(ARGV.fetch(0))
eval "def run(n) = (i = 0; sum = 0; while i < n; o = #{expr}; sum += o.x; i += 1; end; sum)"
w = 0; while w < 300; run(20); w += 1; end
n = 3_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC); sum = run(n)
raise "bad sum #{sum}" unless sum == n * (n - 1) / 2
printf "%-24s %6.1f\n", ARGV[0], (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9

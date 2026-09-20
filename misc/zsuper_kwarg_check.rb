# zsuper (`super` with no argument list) from methods with keyword parameters, into every
# kind of receiver-side signature. What super receives must not depend on how it is compiled.
class Base
  def kw(x:, y: :dy) = [:kw, x, y]
  def kwrest(**kw) = [:kwrest, kw, kw.frozen?, kw.class]
  def rest(*args) = [:rest, args, args.last.class, (Hash.ruby2_keywords_hash?(args.last) rescue nil)]
  def opt_hash(h = :none) = [:opt_hash, h]
  def lead_kw(a, b = :db, x:, y: :dy) = [:lead_kw, a, b, x, y]
  def rest_kw(*a, x:) = [:rest_kw, a, x]
  def post_kw(a, *r, z, x:) = [:post_kw, a, r, z, x]
  def blk(x:, &b) = [:blk, x, b&.call]
  def missing(x:) = [:missing, x]
  def mutate(x:, y:) = [:mutate, x, y]
  def none = [:none]
  def in_block(x:, y: 1) = [:in_block, x, y]
  def ident(**kw) = kw
  ruby2_keywords def r2k(*args) = [:r2k, args, Hash.ruby2_keywords_hash?(args.last)]
  def optional_order(a: 1, b: 2, c:) = [:optional_order, a, b, c]
  def only_rest(*args) = [:only_rest, args]
end
class Sub < Base
  def kw(x:, y: :sub_default) = super
  def kwrest(x:, y: 2) = super
  def rest(x:, y: 2) = super
  def opt_hash(x:, y: 2) = super
  def lead_kw(a, b = :sb, x:, y: :sy) = super
  def rest_kw(*a, x:) = super
  def post_kw(a, *r, z, x:) = super
  def blk(x:, &b) = super
  def missing(x:, extra: 1) = super
  def mutate(x:, y:) = (x = x * 10; y = nil; super)
  def none(x: 1) = super
  def in_block(x:, y: 1) = [1].map { super }.first
  def ident(x:, y: 2) = super
  def r2k(x:, y: 2) = super
  def optional_order(c:, a: 10, b: 20) = super
  def own_kwrest(x:, **rest) = super
  def only_rest(*args, bar: :x) = super
end
class Base; def own_kwrest(**kw) = [:own_kwrest, kw]; end

s = Sub.new
CASES = {
  "kw" => -> { [s.kw(x: 1), s.kw(x: 1, y: 2)] },
  "kwrest" => -> { s.kwrest(x: 1) },
  "rest" => -> { s.rest(x: 1) },
  "opt_hash" => -> { s.opt_hash(x: 1) },
  "lead_kw" => -> { [s.lead_kw(1, x: 2), s.lead_kw(1, 2, x: 3, y: 4)] },
  "rest_kw" => -> { [s.rest_kw(x: 1), s.rest_kw(1, 2, x: 3)] },
  "post_kw" => -> { s.post_kw(1, 2, 3, 4, x: 5) },
  "blk" => -> { [s.blk(x: 1), s.blk(x: 1) { :yielded }] },
  "unknown keyword in super" => -> { s.missing(x: 1) },
  "reassigned locals" => -> { s.mutate(x: 1, y: 2) },
  "super takes nothing" => -> { s.none },
  "inside a block" => -> { s.in_block(x: 1) },
  "identity of the Hash" => -> { a = s.ident(x: 1); b = s.ident(x: 1); [a, a.equal?(b), a.frozen?] },
  "ruby2_keywords target" => -> { s.r2k(x: 1) },
  "keyword order follows the caller's parameters" => -> { s.optional_order(c: 3) },
  "own **rest still splats" => -> { s.own_kwrest(x: 1, z: 3) },
  "rest and keyword into rest only" => -> { [s.only_rest(42), s.only_rest(1, 2, bar: 3), s.only_rest] },
  "Data zsuper" => -> { d = Data.define(:x, :y) { def initialize(x:, y: 0) = super }; [d.new(x: 1).to_h, d.new(1, 2).to_h] },
  "Struct zsuper" => -> { t = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y: 0) = super }; t.new(x: 1).to_a },
  "Struct zsuper, keyword_init unset" => -> { t = Struct.new(:x, :y) { def initialize(x:, y: 0) = super }; t.new(x: 1).to_a },
}.freeze
DZ = Data.define(:x, :y) { def initialize(x:, y: 0) = super }
CASES.each do |label, body|
  result = nil
  300.times do
    result = begin
      body.call.inspect
    rescue => error
      "#{error.class}: #{error.message} #{error.backtrace_locations.first(3).map(&:label).inspect}"
    end
  end
  puts "#{label}: #{result}"
end
3000.times { DZ.new(x: 1) }
puts "hot Data zsuper: #{DZ.new(x: 1).to_h} #{DZ.new(3, 4).to_h}"
iseq = RubyVM::InstructionSequence.compile("class Q < Base; def kw(x:, y: 1) = super; end; Q.new.kw(x: 5)")
puts "binary round trip: #{RubyVM::InstructionSequence.load_from_binary(iseq.to_binary).eval.inspect}"

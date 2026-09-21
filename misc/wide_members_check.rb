# Construction of records with 7..20 members from hot call sites: every width around the
# limits of the JIT fast paths (8 and 16 arguments), in member order and not.
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
def attempt = yield rescue "#{$!.class}: #{$!.message}"
WIDTHS = [7, 8, 9, 12, 15, 16, 17, 20, 33, 63, 64, 65, 70]
WIDTHS.each do |n|
  names = Array.new(n) { :"m#{_1}" }
  s = Object.const_set(:"S#{n}", Struct.new(*names)); d = Object.const_set(:"D#{n}", Data.define(*names)); k = Object.const_set(:"K#{n}", Struct.new(*names, keyword_init: true))
  over = Object.const_set(:"O#{n}", Data.define(*names) { eval "def initialize(#{names.map { "#{_1}:" }.join(', ')}) = super(#{names.map { "#{_1}: #{_1}.to_s" }.join(', ')})" })
  sover = Object.const_set(:"SO#{n}", Struct.new(*names, keyword_init: true) { eval "def initialize(#{names.map { "#{_1}:" }.join(', ')}) = super(#{names.reverse.map { "#{_1}:" }.join(', ')})" })
  vals = (1..n).map { "v#{_1}" }
  forward = names.each_with_index.map { |nm, i| "#{nm}: a[#{i}]" }.join(", ")
  backward = names.each_with_index.map { |nm, i| "#{nm}: a[#{i}]" }.reverse.join(", ")
  shuffled = names.each_with_index.map { |nm, i| "#{nm}: a[#{i}]" }.rotate(n / 2).join(", ")
  partial = names.each_with_index.map { |nm, i| "#{nm}: a[#{i}]" }.each_slice(2).map(&:first).join(", ")
  positional = (0...n).map { "a[#{_1}]" }.join(", ")
  eval <<~RUBY
    def s_pos#{n}(a) = S#{n}.new(#{positional})
    def s_kw#{n}(a) = S#{n}.new(#{forward})
    def s_back#{n}(a) = S#{n}.new(#{backward})
    def s_part#{n}(a) = S#{n}.new(#{partial})
    def k_shuf#{n}(a) = K#{n}.new(#{shuffled})
    def k_unknown#{n}(a) = K#{n}.new(#{forward}, nope: 1)
    def d_pos#{n}(a) = D#{n}.new(#{positional})
    def d_kw#{n}(a) = D#{n}.new(#{forward})
    def d_shuf#{n}(a) = D#{n}.new(#{shuffled})
    def d_part#{n}(a) = D#{n}.new(#{partial})
    def d_with#{n}(o, a) = o.with(#{backward})
    def d_with_part#{n}(o, a) = o.with(#{partial})
    def o_kw#{n}(a) = O#{n}.new(#{shuffled})
    def so_kw#{n}(a) = SO#{n}.new(#{forward})
    def aref#{n}(a) = S#{n}[#{positional}]
  RUBY
  base = d.new(*vals.map(&:upcase))
  300.times { %w[s_pos s_kw s_back s_part k_shuf d_pos d_kw d_shuf o_kw so_kw aref].each { |m| send("#{m}#{n}", vals) }; send("d_with#{n}", base, vals); send("d_with_part#{n}", base, vals) }
  %w[s_pos s_kw s_back s_part k_shuf k_unknown d_pos d_kw d_shuf d_part o_kw so_kw aref].each do |m|
    report("#{m} #{n}") { attempt { r = send("#{m}#{n}", vals); [r.to_h.values, r.frozen?, r.class.name] } }
  end
  report("d_with #{n}") { [send("d_with#{n}", base, vals).to_h.values, send("d_with_part#{n}", base, vals).to_h.values, base.to_h.values == vals.map(&:upcase)] }
  GC.stress = true; ok = 3.times.all? { |i| v = (1..n).map { "g#{i}_#{_1}" }; send("d_kw#{n}", v).to_h.values == v && send("s_back#{n}", v).to_h.values == v && send("d_with#{n}", base, v).to_h.values == v && send("o_kw#{n}", v).to_h.values == v }; GC.stress = false
  report("gc stress #{n}") { ok }
end

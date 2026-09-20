class Plain
  def initialize(x, y) = (@x = x; @y = y)
end
Point = Struct.new(:x, :y)
Coord = Data.define(:x, :y)

def make_plain = Plain.new(1, 2)
def make_struct = Point.new(1, 2)
def make_data = Coord.new(1, 2)

3000.times { make_plain; make_struct; make_data }

# frozen_string_literal: true
# Counts, by receiver class, the calls of a few methods whose cost depends on what they are called on.

require_relative "../harness/harness-common"

RECV_TALLY_DIR = File.expand_path("../recv-tally", __dir__)
RECV_METHODS = %i[!= dup].freeze

def run_benchmark(_hint, **)
  yield

  counts = Hash.new(0)
  tracer = TracePoint.new(:c_call) do |tp|
    next unless RECV_METHODS.include?(tp.method_id)
    next unless tp.defined_class == BasicObject || tp.defined_class == Kernel

    receiver = tp.self
    kind = Module === receiver ? "a Class/Module" : (receiver.class.name || "(anonymous)")
    counts["#{tp.method_id} on #{kind}"] += 1
  end
  tracer.enable { yield }

  name = File.basename(File.dirname(File.expand_path($PROGRAM_NAME)))
  File.write(File.join(RECV_TALLY_DIR, "#{name}.txt"), counts.sort_by { -_2 }.map { |k, v| "#{v}\t#{k}" }.join("\n") + "\n")
  return_results([], [0.001])
end

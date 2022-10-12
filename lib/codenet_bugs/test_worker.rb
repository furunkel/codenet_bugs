require 'open3'
require 'stringio'
require 'io/wait'
require 'logger'
require 'json'

require 'codenet_bugs/bug'
require 'codenet_bugs/test'
require 'codenet_bugs/submission'
require 'codenet_bugs/test_runner2'

module CodenetBugs
  class TestWorker

    HEADER = "BUGS".freeze

    def initialize(id:, read_fd:, write_fd:)
      @id = id
      @read_io = IO.for_fd read_fd
      @write_io = IO.for_fd write_fd

      @logger = Logger.new $stdout
      @logger.formatter = proc do |severity, datetime, _progname, msg|
        date_format = datetime.strftime("%Y-%m-%d %H:%M:%S")
        sprintf "[Worker#%d] [%s] %-5s: %s\n", id, date_format, severity, msg
      end

      # p Dir["#{Dir.home}/**/*"]
    end

    def run!
      loop do
        @read_io.wait_readable
        header = @read_io.read(HEADER.bytesize)
        raise "expected header but got #{header}" if header != TestWorker::HEADER

        size = @read_io.read(8).unpack1('q')
        @logger.debug("Read size: #{size}")
        input_str = @read_io.read(size)
        input = JSON.parse(input_str)
        @logger.debug("Read: #{input.inspect}")

        submission = Submission.from_hash(input[0])
        io_samples = input[1].map { Test.from_hash _1 }
        options = input[2].transform_keys(&:to_sym)

        @logger.debug("Running submisison #{submission} on #{io_samples.map(&:id)}")

        runner = TestRunner2.new(submission, io_samples, logger: @logger, **options)
        results = runner.run!

        result_json = results.to_json
        @write_io.write(HEADER)
        @write_io.write([result_json.bytesize].pack('q'))
        @write_io.write(result_json)
        @write_io.flush
        # sleep 10
      end
    end
  end
end
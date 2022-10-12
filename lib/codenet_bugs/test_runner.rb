require 'open3'
require 'bigdecimal'
require 'logger'
require 'io/wait'
require 'strscan'

module CodenetBugs
  class TestRunner
    # largest sample output is 1098
    MAX_OUTPUT_LENGTH = 1024 * 2
    MAX_ERROR_OUTPUT_LENGTH = 1024 * 4
    NO_RLIMIT_LANGUAGES = %i[java javascript go].freeze
    JAVA_CLASS_REGEX = /^\s*(?:(?:public|static|protected|private|final)\s+)*class\s+([a-zA-Z0-9_]+)/

    MAX_READ_WAIT = 3

    class OutputParser
      class ParseError < StandardError; end

      def initialize(output, strict: false)
        @output = output
        @s = StringScanner.new output
        @strict = strict
      end

      def parse
        lines = []
        lines << parse_line while @s.rest?

        lines
      end

      def parse_line
        line = []

        loop do
          skip
          # p ['debug', @s.peek(10)]
          break if end_of_line?
          skip
          element = parse_element
          raise ParseError, "failed to match element at '#{@s.peek(10)}'" if element.nil?
          line << element if element
        end

        line
      end

      def skip
        @s.skip(/[ \t\r\f\v]+/)
      end

      def end_of_line?
        @s.eos? || @s.scan(/\n/)
      end

      def parse_element
        if (n = parse_number)
          return n
        end

        @s.scan(/[^\s]+/)
      end

      # def parse_separator
      #   return s if (s = @s.scan(/(;|,)/))
      # end

      def parse_number
        if (number = @s.scan(/-?\d+(?:\.\d+)?/))
          if @strict && number =~ /^-?\d+?$/
            Integer(number)
          else
            BigDecimal(number)
          end
        end
      end
    end

    DEFAULT_FLOAT_EPS = 1e-4
    FLOAT_EPS = {
      # P02400: the description states abs. error <= 1e-5, however, we see
      # accepted submissions with errors slightly above that, so increasing slightly
      'p02400' => 1e-5,
      'p02008' => 1e-6,
      'p03882' => 1e-9,
      'p02805' => 1e-6,
      'p03585' => 1e-9,
      'p03619' => 1e-11,
      'p01562' => 1e-6,
      'p03428' => 1e-5,
      'p01837' => 1e-6,
      'p03135' => 1e-3,
      'p02764' => 1e-6,
      'p03888' => 1e-6,
      'p03110' => 1e-5,
      'p03901' => 1e-6,
      'p01836' => 1e-8,
      'p00973' => 1e-6,
      'p03043' => 1e-9,
      'p01948' => 1e-6,
      'p01800' => 1e-6,
      'p03304' => 1e-6,
      'p01704' => 1e-4,
      'p03001' => 1e-9,
      'p02072' => 1e-3,
      'p02897' => 1e-6,
      'p03754' => 1e-6,
      'p02731' => 1e-6,
      'p03879' => 1e-9,
      'p02677' => 1e-9,
      'p03953' => 1e-9,
      'p02894' => 1e-9,
      'p02705' => 1e-2,
      'p01825' => 1e-6,
      'p03514' => 1e-9,
      'p01672' => 1e-8,
      'p02882' => 1e-6,
      'p03881' => 1e-9,
      'p02075' => 1e-9,
      'p00988' => 1e-7,
      'p03744' => 1e-6,
      'p01685' => 1e-6,
      'p03872' => 1e-9,
      'p01703' => 1e-8, #FIXME: states relative error only!!
      'p03869' => 1e-9,
      'p02884' => 1e-6,
      'p03866' => 1e-9,
      'p02780' => 1e-6,
      'p01568' => 1e-6,
      'p01705' => 1e-4,
      'p01576' => 1e-8,
      'p02935' => 1e-5,
      'p03004' => 1e-9,
      'p02011' => 1e-6,
      'p01708' => 1e-2,
      'p03776' => 1e-6,
      'p02934' => 1e-5,
      'p01363' => 1e-6,
      'p01510' => 1e-9,
      'p03871' => 1e-9,
      'p02379' => 1e-4
    }.freeze

    def self.output_matches?(expected_output, actual_output, problem_id)
      return false if actual_output.nil?

      expected_output = expected_output.chomp
      actual_output = actual_output.chomp
      return true if expected_output == actual_output

      expected_parsed = OutputParser.new(expected_output).parse
      actual_parsed = OutputParser.new(actual_output).parse

      return false if expected_parsed.size != actual_parsed.size

      # p expected_parsed
      # p actual_parsed

      float_eps = FLOAT_EPS.fetch(problem_id, DEFAULT_FLOAT_EPS)

      expected_parsed.zip(actual_parsed).all? do |expected_line, actual_line|
        next false if expected_line.size != actual_line.size

        expected_line.zip(actual_line).all? do |expected_element, actual_element|
          if expected_element.is_a?(BigDecimal) && actual_element.is_a?(BigDecimal)
            (actual_element - expected_element).abs <= float_eps
          else
            actual_element == expected_element
          end
        end
      end
    end


    def initialize(submission, io_samples, abort_on_timeout: false, abort_on_fail: false,
                  abort_on_error: false, truncate_output: true, logger_level: Logger::WARN, logger: nil)
      @truncate_output = truncate_output
      @submission = submission
      @submission_language = @submission.language.to_sym
      @io_samples = io_samples
      @abort_on_timeout = abort_on_timeout
      @abort_on_fail = abort_on_fail
      @abort_on_error = abort_on_error

      if logger
        @logger = logger
      else
        @logger = defined?(Rails) ? Rails.logger : Logger.new($stdout)
        @logger.level = logger_level
      end
    end

    def run!
      @counters = {timeout: 0, fail: 0, error: 0}
      @aborted = false

      @logger.debug "Running #{@submission.id} on #{@io_samples.map(&:id)} (worker #{Parallel.worker_number}"
      return [] if @io_samples.empty?
      compile_and_run_in_sandbox
    end

    def aborted? = @aborted

    class CompilationError < StandardError; end
    class BWrapError < StandardError; end

    private

    def truncate_output(output, max_size)
      output.length > max_size ? "#{output[0...max_size]}<truncated>" : output
    end

    def compile_and_run(cmd, input_filename, input, *args)
      Dir.mktmpdir do |dir|
        #Dir.chdir(dir) do
          File.write(File.join(dir, input_filename), input)
          output, status = Open3.capture2e(*cmd, input_filename, *args, chdir: dir)
          if status.exitstatus.zero?
            yield dir
          else
            # FIXME: pass error message
            raise CompilationError.new(output)
          end
        #end
      end
    end

    def find_java_main_class(submission)
      tree = submission.tree
      query = TreeSitter::Java::Query.new("([(method_declaration)] @f)")
      methods = []
      query.run tree.root_node do |captures, _index|
        captures.each do |n|
          methods << n if n.dig(:name)&.text == 'main'
        end
      end

      return nil if methods.size > 1 || methods.empty?

      main_method = methods.first
      p main_method.parents.map(&:type)
      class_decl = main_method.parents.find { _1.type? :class_declaration }
      class_decl.dig(:name).text

      # Dir.chdir(dir) do
      #   Dir['*.class'].each do |class_filename|
      #     class_name = File.basename(class_filename)
      #     output, status = Open3.capture2e('javap', class_name)
      #     if status.success?
      #       return class_name if output.include?('void main(')
      #     end
      #   end
      # end
    end

    def compile_and_run_java(&block)
      # we ignore packages to simplify compilation
      content = @submission.content.sub(/package\s+([a-zA-Z0-9_.]+)\s*;/, '')
      class_name = @submission.main_class
      # class_names = content.scan(JAVA_CLASS_REGEX).flatten
      # class_name = class_names.first if class_names.size == 1
      # class_name ||= find_java_main_class(@submission)
      raise CompilationError, 'missing main class' if class_name.nil?

      compile_and_run('javac', "#{class_name}.java", content) do |tmp_dir|
        class_filenames = Dir[File.join(tmp_dir, '*.class')]
        sandbox_filenames = class_filenames.map { File.join('/tmp', File.basename(_1)) }
        block[class_filenames.zip(sandbox_filenames), { class_name: class_name }]
      end
    end

    def compile_and_run_c(cc, ext, &block)
      compile_and_run(cc, "program.#{ext}", @submission.content, '-lm') do |tmp_dir|
        block[[[File.join(tmp_dir, 'a.out'), '/tmp/a.out']], {}]
      end
    end

    def compile_and_run_go(&block)
      compile_and_run(['go', 'build', '-o', 'a.out'], 'program.go', @submission.content) do |tmp_dir|
        block[[[File.join(tmp_dir, 'a.out'), '/tmp/a.out']], {}]
      end
    end

    def run_interpreter(&block)
      Tempfile.create(['program', @submission.filename_ext]) do |tmp_file|
        tmp_file.write(@submission.content)
        tmp_file.flush
        tmp_file.rewind
        block[[[tmp_file, "/tmp/file.#{@submission.filename_ext}"]], {}]
      end
    end

    def compile(&block)
      case @submission_language
      when :java
        compile_and_run_java(&block)
      when :cpp
        compile_and_run_c('g++', 'cpp', &block)
      when :c
        compile_and_run_c('gcc', 'c', &block)
      when :go
        compile_and_run_go(&block)
      else
        run_interpreter(&block)
      end
    end

    def bwrap_cmd(fd_map, context)
      cmd = [
        '/usr/bin/bwrap',
        '--ro-bind', '/usr', '/usr',
        '--ro-bind', '/etc/alternatives', '/etc/alternatives',
        '--dir', '/tmp',
        '--dir', '/var',
        '--symlink', '../tmp', 'var/tmp',
        '--proc', '/proc',
        '--dev', '/dev',
        '--symlink', 'usr/lib', '/lib',
        '--symlink', 'usr/lib64', '/lib64',
        '--symlink', 'usr/bin', '/bin',
        '--symlink', 'usr/sbin', '/sbin',
        '--chdir', '/tmp',
        '--unshare-all',
        '--new-session',
        '--die-with-parent'
      ]

      fd_map.each do |fd, filename|
        cmd << '--perms' << '0760'
        cmd << '--file' << fd.to_s << filename
      end

      _, filename = fd_map.first

      cmd << '--setenv' << 'OPENBLAS_NUM_THREADS' << '1'
      cmd << '--setenv' << 'GOTO_NUM_THREADS' << '1'
      cmd << '--setenv' << 'OMP_NUM_THREADS' << '1'

      case @submission_language
      when :ruby
        cmd << '/usr/bin/ruby' << '--disable-gems' << filename
      when :python
        cmd << '/usr/bin/python3' << filename
      when :php
        cmd << '/usr/bin/php7.4' << filename
      when :javascript
        cmd << '/usr/bin/node' << '--max-old-space-size=512' << filename
      when :c, :cpp, :go
        cmd << './a.out'
      # when 'go'
        # cmd << '--setenv' << 'GOPATH' << '/tmp'
        # cmd << '--setenv' << 'GOCACHE' << '/tmp'
        # cmd << '/usr/bin/go' << 'run' << filename
      when :java
        cmd << '/usr/bin/java' << '-mx512m' << '-XX:TieredStopAtLevel=1' << context.fetch(:class_name)
        # cmd << '/usr/lib/jvm/java-17-openjdk-amd64/bin/java' <<
      else
        raise "language #{@submission_language} is not supported"
      end
      cmd
    end

    def abort?(result_type, abort_count, result1, result2=result1)
      if result_type == result1 || result_type == result2 && abort_count
        @counters[result1] += 1
        if abort_count == true || @counters[result1] >= abort_count
          @logger.warn "#{@counters[result1]} #{result1}s...aborting"
          return true
        end
      end
      false
    end

    def run_all_samples(file_mappings, context)
      @io_samples.each_with_object([]) do |io_sample, results|
        result = run_sample_in_sandbox(file_mappings, context, io_sample)
        if result
          result_type = result[:result]
          results << result

          return results if abort?(result_type, @abort_on_timeout, :timeout, :timeout2) ||
                            abort?(result_type, @abort_on_fail, :fail) ||
                            abort?(result_type, @abort_on_error, :error)
        end
      end
    end

    def run_sample_in_sandbox(file_mappings, context, io_sample)
      sample_input = io_sample.input
      sample_output = io_sample.output.strip

      fd_map = {}
      popen_opts = {
        unsetenv_others: true,
        rlimit_cpu: 10
      }

      file_mappings.each_with_index do |(host_io_or_filename, sandbox_filename), index|
        fd = 11 + (Parallel.worker_number || 0) * 10 + index
        popen_opts[fd] = host_io_or_filename
        fd_map[fd] = sandbox_filename

        if host_io_or_filename.is_a?(IO)
          host_io_or_filename.rewind
        end
      end

      cmd = bwrap_cmd(fd_map, context)

      output = nil
      exit_status = nil
      error_output = nil
      result = nil

      # Limit causes JVM to crash. We can limit memory using JVM anyway
      popen_opts[:rlimit_as] = 512 * 1024 * 1024 unless NO_RLIMIT_LANGUAGES.include?(@submission_language)

      @logger.debug("Running submission #{@submission.id} on sample #{io_sample.id} on worker #{Parallel.worker_number} (#{file_mappings.inspect})")

      Open3.popen3({}, *cmd, popen_opts) do |stdin, stdout, stderr, wait_thr|

        out_reader = Thread.new do
          begin
            next :timeout if stdout.wait_readable(MAX_READ_WAIT).nil?
            stdout.read
          rescue IOError
            @logger.warn('IOError in reader thread')
            :io_error
          end
        end
        err_reader = Thread.new do
          begin
            stderr.read
          rescue IOError
            @logger.warn('IOError in stderr reader thread')
            :io_error
          end
        end

        kill_thr = Thread.new do
          sleep(MAX_READ_WAIT + 3)
          if wait_thr.alive?
            @logger.info "wait thread is still alive...killing pid"
            begin
              Process.kill 'KILL', wait_thr.pid
            rescue Errno::ESRCH
              @logger.info "pid was no longer alive"
            end
          end
        end

        begin
          stdin.write sample_input
          stdin.write "\n"
          stdin.close
        rescue Errno::EPIPE
          @logger.warn "ignoring EPIPE"
        end


        output = out_reader.value
        error_output = err_reader.value

        if output == :io_error || error_output == :io_error
          @logger.warn "IOError in thread..."
          return nil
        end

        if output == :timeout || output == :io_error
          result = output
          output = nil
          @logger.debug 'killing process...'
          begin
            Process.kill 'KILL', wait_thr.pid
          rescue Errno::ESRCH
            @logger.debug '...killing failed (ESRCH)'
          end
        end

        # if wait_thr.alive?
        #   @logger.warn 'killing process (wait thread timeout)'
        #   begin
        #     Process.kill 'KILL', wait_thr.pid
        #   rescue Errno::ESRCH
        #     @logger.warn 'pid no longer alive'
        #   end
        # end

        exit_status = wait_thr.value
      end

      # p ['run done', output, error_output, exit_status]

      # NOTE: we storing output as text, which causes trouble if output is binary
      # Output should be encodable as UTF-8. However, some programs output invalid UTF-8.
      # We drop non-encodable bytes

      output = output&.size&.positive? ? output.encode('UTF-8', invalid: :replace, replace: '') : nil
      error_output = error_output&.size&.positive? ? error_output.encode('UTF-8', invalid: :replace, replace: '') : nil

      output = output&.strip&.delete "\u0000"
      error_output = error_output&.delete "\u0000"

      if error_output =~ /bwrap:/
        raise BWrapError.new(error_output)
      end

      @logger.debug("Program process exited with status #{exit_status} (output length #{output&.size})")
      # puts "=========================="
      # p sample_output
      # puts "----------------------"
      # p output
      # puts output == sample_output
      # puts "=========================="

      if output && @truncate_output
        output = truncate_output(output, [(1.8 * sample_output.size).to_i, MAX_OUTPUT_LENGTH].max)
      end

      result ||=
        if exit_status.signaled? || exit_status.termsig
          :timeout2
        elsif self.class.output_matches?(sample_output, output, @submission.problem_id)
          :pass
        elsif exit_status.exitstatus != 0 && error_output
          :error
        else
          :fail
        end

      if error_output
        error_output = truncate_output(error_output.gsub('/tmp/', ''), MAX_ERROR_OUTPUT_LENGTH)
      end

      icon =
        case result
        when :pass then "\u{2705}"
        when :fail then "\u{274C}"
        when :error then "\u{1F480}"
        when :timeout then "\u{23F1}"
        else "\u{003F}"
        end

      if (@submission.accepted? && result != :pass) ||
          (!@submission.accepted? && result == :pass)
        @logger.warn("Run result does not match submission status: #{@submission.id} #{icon}")
      end

      {
        result: result,
        submission_id: @submission.id,
        io_sample_id: io_sample.id,
        error_output: error_output,
        output: output
      }
    end

    def compile_and_run_in_sandbox
      attributes =
        begin
          compile do |file_mappings, context|
            @logger.debug "Compiling submission #{@submission.id} done"
            begin
              run_all_samples(file_mappings, context)
            # rescue Errno::EPIPE, IOError => e
            #   @logger.warn "Received EPIPE/IOError, repeating execution (#{e})"
            #   retry
            end
          end
        rescue CompilationError => e
          @logger.warn("Submission #{@submission.id} failed to compile (#{e.message})")
          [{
            result: :compilation_error,
            submission_id: @submission.id,
            io_sample_id: @io_samples.first.id,
            error_output: e.message,
            output: nil
          }]
        end

      attributes
    end
  end
end
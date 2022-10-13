require 'zlib'
require 'json'
require 'logger'
require 'parallel'
require 'tempfile'
require 'concurrent'

require 'codenet_bugs/test_worker_pool'
require 'codenet_bugs/thread_pool'
require 'codenet_bugs/bug'
require 'codenet_bugs/submission'
require 'codenet_bugs/test'

module CodenetBugs
  module Evaluator



    def load_jsonl(filename)
      Zlib::GzipReader.open(filename) do |gz|
        gz.each_line do |line|
          yield JSON.parse(line)
        end
      end
    end
    module_function :load_jsonl

    class Logger < ::Logger
      attr_reader :progress

      class Formatter
        def initialize(logger)
          @logger = logger
        end

        def call(severity, datetime, progname, msg)
          date_format = datetime.strftime("%Y-%m-%d %H:%M:%S")
          sprintf "[%d%%] [%s] %-5s: %s\n", (@logger.progress * 100).round(2), date_format, severity, msg
        end
      end

      def initialize
        super($stdout)
        @progress = 0.0
        self.formatter = Formatter.new(self)
      end

      def progress=(progress)
        @progress = [[@progress, progress].max, 1.0].min
      end
    end


    class Tests
      def [](problem_id)
        @tests.fetch(problem_id)
      end

      def initialize(tests)
        @tests = tests
      end

      class << self
        def load(filename)
          tests = Hash.new { |h, k| h[k] = [] }
          Evaluator.load_jsonl(filename) do |hash|
            test = Test.new(
              id: hash.fetch('id'),
              input: hash.fetch('input'),
              output: hash.fetch('output'),
            )
            tests[hash['problem_id'].to_sym] << test
          end

          new tests
        end

        private :new
      end
    end

    class Bugs
      include Enumerable

      def each(...) = @bugs.each_value(...)

      def initialize(bugs, logger_level: Logger::INFO)
        @bugs = bugs
        @logger = Logger.new
        @logger.level = logger_level
      end

      def restart!(checkpoint)
        @logger.warn "Restarting process..."
        sleep 60 * 10
        Kernel.exec("bundle exec #{$0} #{ARGV.join ' '} --checkpoint #{checkpoint}")
      end

      def [](bug_id)
        @bugs[bug_id.to_i]
      end

      def evaluate!(tests, predictions: true, abort_on_timeout: 1, abort_on_fail:1, abort_on_error: 1, checkpoint: nil)
        restart = false
        if checkpoint
          all_rows = JSON.load_file(checkpoint).transform_keys(&:to_i)
          bugs = @bugs.reject { |bug_id, _bug| all_rows.key? bug_id }
          @logger.info "Continuing evaluation from checkpoint, #{@bugs.size - bugs.size} bugs already evaluated"
        else
          all_rows = {}
          bugs = @bugs
        end

        test_worker_pool = TestWorkerPool.new @logger, size: 8
        eval_rows = Concurrent::Hash.new
        pool = ThreadPool.new size: 8

        bugs.each_with_index do |(bug_id, bug), bug_index|
          pool.post do
            io_samples = tests[bug.problem_id]
            @logger.progress = (all_rows.size + bug_index.to_f + 0.5) / @bugs.size
            #p bug.source_submission.accepted?
            #p bug.target_submission.accepted?

            begin

              if predictions
                rows = bug.candidate_submissions.inject([]) do |acc, candidate_submission|
                  runs = test_worker_pool.submit(candidate_submission, io_samples, 
                                                    abort_on_timeout: abort_on_timeout,
                                                    abort_on_error: abort_on_error,
                                                    abort_on_fail: abort_on_fail)
                  acc << runs
                  break acc if runs.all? { _1.fetch('result') == 'pass' }
                  acc
                end
              else
                raise
              end
              #rows = IOSampleRunner.new(bug.source_submission, io_samples, abort_on_timeout: abort_on_timeout).run!
              #rows2 = IOSampleRunner.new(bug.target_submission, io_samples, abort_on_timeout: abort_on_timeout).run!
              eval_rows[bug.id] = rows if rows
              max_run = rows.max_by { |runs| runs.count { _1.fetch('result') == 'pass' }}
              passed = max_run.all? { _1.fetch('result') == 'pass' }
              @logger.info("Bug #{bug.id} (#{bug.language}): #{passed} #{max_run ? max_run.size : 0}/#{io_samples.size}")
            rescue TestRunner::BWrapError => e
              @logger.error e
              restart = true
              pool.stop!
            end
          end
        end

        pool.start!
        test_worker_pool.shutdown

        all_rows.merge! eval_rows

        checkpoint = "/tmp/codenet_bugs_checkpoint_#{Time.now.to_i}.json"
        File.write(checkpoint, all_rows.to_h.to_json)
        @logger.info "Writing checkpoint to #{checkpoint}"
        restart! checkpoint if restart
      end

      class << self
        def load(filenames, preds_filename=nil)
          filenames = Array(filenames)
          languages = filenames.map do |filename|
            if (match = filename.match(/_(c|cpp|javascript|java|ruby|python|php|go)_/))
              match[1].to_sym
            else
              raise ArgumentError, "invalid submissions filename '#{filename}'"
            end
          end

          bugs = {}

          filenames.zip(languages) do |filename, language|
            Evaluator.load_jsonl(filename) do |hash|
              problem_id = hash.fetch('problem_id').to_sym

              source_submission = Submission.new(
                id: hash.fetch('source_submission_id'),
                content: hash.fetch('source'),
                main_class: hash['source_main_class'],
                accepted: false,
                problem_id:,
                language:, 
              )

              target_submission = Submission.new(
                id: hash.fetch('target_submission_id'),
                content: hash.fetch('target'),
                main_class: hash['target_main_class'],
                accepted: true,
                problem_id:,
                language:
              )

              bug = Bug.new(
                id: hash.fetch('id'),
                language:,
                problem_id:,
                user_id: hash.fetch('user_id').to_sym,
                labels: hash.fetch('labels'),
                change_count: hash.fetch('change_count'),
                source_submission:,
                target_submission:
              )

              raise if bugs.key? bug.id

              bugs[bug.id] = bug
            end
          end

          if preds_filename
            Evaluator.load_jsonl(preds_filename) do |hash|
              bug = bugs.fetch(hash['id'])
              candidate_submissions = hash.fetch('preds').map do |predicted_content|
                Submission.new(
                  id: bug.source_submission.id,
                  content: predicted_content,
                  main_class: bug.target_submission.main_class,
                  accepted: true,
                  problem_id: bug.problem_id,
                  language: bug.language
                )
              end
              bug.candidate_submissions = candidate_submissions
            end
          end

          new bugs
        end

        private :new
      end
    end

  end
end


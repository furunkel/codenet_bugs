require 'logger'
require 'json'

require 'codenet_bugs/jsonl'
require 'codenet_bugs/thread_pool'
require 'codenet_bugs/test_worker_pool'
require 'codenet_bugs/test_runner'
require 'codenet_bugs/logger'

module CodenetBugs
  class Bugs
    include Enumerable

    def each(...) = @bugs.each_value(...)

    def initialize(bugs, logger_level: Logger::INFO, logger: nil)
      @bugs = bugs
      @logger = Logger.new || logger
      @logger.level = logger_level
    end

    def size = @bugs.size

    def restart!(checkpoint)
      @logger.warn "Restarting process..."
      sleep 60 * 10
      Kernel.exec("bundle exec #{$0} #{ARGV.join ' '} --checkpoint #{checkpoint}")
    end

    def [](bug_id)
      @bugs[bug_id.to_i]
    end

    def bug_ids
      @bugs.keys
    end

    def evaluate!(tests, sanity_check: true, abort_on_timeout: 1, abort_on_fail:1, abort_on_error: 1, checkpoint: nil)
      restart = false
      if checkpoint
        all_rows = JSON.load_file(checkpoint, symbolize_names: true).transform_keys(&:to_i)
        bugs = @bugs.reject { |bug_id, _bug| all_rows.key? bug_id }
        @logger.info "Continuing evaluation from checkpoint, #{@bugs.size - bugs.size} bugs already evaluated"
      else
        all_rows = {}
        bugs = @bugs
      end

      progress_proc = proc do |bug_index|
        (all_rows.size + bug_index.to_f + 0.5) / @bugs.size
      end

      eval_rows = evaluate_bugs(bugs, tests, sanity_check:, abort_on_timeout:, abort_on_fail:, abort_on_error:, progress_proc:)

      all_rows.merge! eval_rows

      checkpoint = "/tmp/codenet_bugs_checkpoint_#{Time.now.to_i}.json"
      File.write(checkpoint, all_rows.to_h.to_json)
      @logger.info "Writing checkpoint to #{checkpoint}"
      restart! checkpoint if restart
    end

    def inspect
      to_s
    end

    private

    def evaluate_bugs(bugs, tests, sanity_check: true, abort_on_timeout: 1, abort_on_fail:1, abort_on_error: 1, progress_proc: nil)
      test_worker_pool = TestWorkerPool.new logger: @logger, size: 8
      eval_rows = {}
      eval_rows_mutex = Mutex.new
      pool = ThreadPool.new size: 8

      bugs.each_with_index do |(bug_id, bug), bug_index|
        pool.post do
          io_samples = tests[bug.problem_id]
          progress = progress_proc&.call bug_index
          #p bug.buggy_submission.accepted?
          #p bug.fixed_submission.accepted?

          begin
            rows =
              if sanity_check
                runs, worker_info = test_worker_pool.submit(bug.fixed_submission, io_samples,
                                              abort_on_timeout: abort_on_timeout,
                                              abort_on_error: abort_on_error,
                                              abort_on_fail: abort_on_fail)

                [runs]
              else
                bug.candidate_submissions.inject([]) do |acc, candidate_submission|
                  runs, worker_info = test_worker_pool.submit(candidate_submission, io_samples,
                                                    abort_on_timeout: abort_on_timeout,
                                                    abort_on_error: abort_on_error,
                                                    abort_on_fail: abort_on_fail)
                  acc << runs
                  break acc if runs.all? { _1.fetch(:result) == 'pass' }
                  acc
                end
              end
            #rows = IOSampleRunner.new(bug.buggy_submission, io_samples, abort_on_timeout: abort_on_timeout).run!
            #rows2 = IOSampleRunner.new(bug.fixed_submission, io_samples, abort_on_timeout: abort_on_timeout).run!
            eval_rows_mutex.synchronize do
              eval_rows[bug.id] = rows if rows
            end
            max_run = rows.max_by { |runs| runs.count { _1.fetch(:result) == 'pass' }}
            passed = max_run.all? { _1.fetch(:result) == 'pass' }
            @logger.info("[#{(progress * 100).round}%] [Worker#{worker_info[:worker_id]}] Bug #{bug.id} (#{bug.language}): #{passed} #{max_run ? max_run.size : 0}/#{io_samples.size}")
          rescue TestRunner::BWrapError => e
            @logger.error e
            pool.stop!
          end
        end
      end

      pool.start!
      test_worker_pool.shutdown

      eval_rows
    end

    class << self
      SPLITS = %i[train valid test].freeze
      ALL_LANGUAGES = %i[c cpp go java javascript php python ruby].freeze

      def load_internal(split = nil, preds_filename = nil, languages: ALL_LANGUAGES)
        raise ArgumentError, "invalid split '#{split}'" unless split.nil? || SPLITS.include?(split)

        filenames = Dir[File.join(CodenetBugs.data_dir, 'export', "*_{#{Array(languages).join(',')}}_#{split}*.jsonl.gz")]
        load(filenames, preds_filename)
      end

      def load(filenames, preds_filename = nil)
        filenames = Array(filenames)
        languages = filenames.map do |filename|
          if (match = filename.match(/_(c|cpp|javascript|java|ruby|python|php|go)_/))
            match[1].to_sym
          else
            raise ArgumentError, "invalid submissions filename '#{filename}'"
          end
        end

        logger = Logger.new
        bugs = {}

        filenames.zip(languages) do |filename, language|
          JSONL.load_file(filename) do |hash|
            problem_id = hash.fetch(:problem_id).to_sym

            buggy_submission = Submission.new(
              id: hash.fetch(:buggy_submission_id),
              code: hash.fetch(:buggy_code),
              main_class: hash[:buggy_main_class],
              accepted: false,
              problem_id:,
              language:, 
            )

            fixed_submission = Submission.new(
              id: hash.fetch(:fixed_submission_id),
              code: hash.fetch(:fixed_code),
              main_class: hash[:fixed_main_class],
              accepted: true,
              problem_id:,
              language:
            )

            bug = Bug.new(
              id: hash.fetch(:id),
              language:,
              problem_id:,
              user_id: hash.fetch(:user_id).to_sym,
              labels: hash.fetch(:labels),
              change_count: hash.fetch(:change_count),
              buggy_submission:,
              fixed_submission:
            )

            raise 'duplicate bug' if bugs.key? bug.id

            bugs[bug.id] = bug
          end
        end

        if preds_filename
          JSONL.load_file(preds_filename) do |hash|
            bug = bugs[hash[:id]]

            if bug.nil?
              logger.warn("Prediction for unknown bug #{hash[:id]}")
              next
            end

            candidate_submissions = hash.fetch(:preds).map do |predicted_code|
              Submission.new(
                id: bug.buggy_submission.id,
                code: predicted_code,
                main_class: bug.fixed_submission.main_class,
                accepted: true,
                problem_id: bug.problem_id,
                language: bug.language
              )
            end
            bug.candidate_submissions = candidate_submissions
          end
        end

        new bugs, logger: logger
      end

      private :new
    end
  end
end
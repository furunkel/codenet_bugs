require 'logger'
require 'json'

require 'run_bug_run/dataset'
require 'run_bug_run/json_utils'
require 'run_bug_run/thread_pool'
require 'run_bug_run/test_worker_pool'
require 'run_bug_run/test_runner'
require 'run_bug_run/logger'

module RunBugRun
  class Bugs
    include Enumerable

    SPLITS = %i[train valid test].freeze
    ALL_LANGUAGES = %i[c cpp go java javascript php python ruby].freeze

    LANGUAGE_NAME_MAP = {
      c: 'C',
      cpp: 'C++',
      javascript: 'JavaScript',
      java: 'Java',
      ruby: 'Ruby',
      python: 'Python',
      php: 'PHP',
      go: 'Go'
    }.freeze

    attr_reader :split, :languages, :version

    def each(...) = @bugs.each_value(...)

    def initialize(bugs, logger_level: Logger::INFO, logger: nil, split: nil, languages: nil, version: nil)
      @bugs = bugs
      @logger = Logger.new || logger
      @logger.level = logger_level
      @split = split
      @languages = languages
      @version = version
    end

    def size = @bugs.size
    def values_at(...) = @bugs.values_at(...)

    # def restart!(checkpoint)
    #   @logger.warn "Restarting process..."
    #   sleep 60 * 10
    #   Kernel.exec("bundle exec #{$0} #{ARGV.join ' '} --checkpoint #{checkpoint}")
    # end

    def [](bug_id)
      @bugs[bug_id.to_i]
    end

    def bug_ids
      @bugs.keys
    end

    def evaluate!(tests, output_filename:, fixed: false, buggy: false, abort_on_timeout: 1, abort_on_fail:1, abort_on_error: 1, checkpoint: nil, workers: 8)
      if checkpoint
        all_rows = JSONUtils.load_json(checkpoint, compression: :gzip)
        all_rows.transform_keys!(&:to_i)
        bugs = @bugs.reject { |bug_id, _bug| all_rows.key? bug_id }
        @logger.info "Continuing evaluation from checkpoint, #{@bugs.size - bugs.size} bugs already evaluated"
      else
        all_rows = {}
        bugs = @bugs
      end

      progress_proc = proc do |bug_index|
        (all_rows.size + bug_index.to_f + 0.5) / @bugs.size
      end

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      eval_rows = evaluate_bugs(bugs, tests, fixed:, buggy:, abort_on_timeout:, abort_on_fail:, abort_on_error:, progress_proc:, workers:)
      end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      all_rows.merge! eval_rows
    ensure
      passing_rows = all_rows.select do |_bug_id, candidate_runs|
        candidate_runs.any? {|runs| runs.all? { _1.fetch(:result) == 'pass' } }
      end
      print_short_summary passing_rows, all_rows, output_filename, start_time, end_time
      passing_ids = passing_rows.map(&:first)

      json = {
        results: all_rows,
        split: @split,
        languages: @languages,
        version: @version
      }

      if passing_rows.size < all_rows.size / 2
        json[:passing] = passing_ids
      else
        json[:failing] = all_rows.keys - passing_ids
      end

      JSONUtils.write_json output_filename, json, compression: :gzip
    end

    def inspect
      to_s
    end

    private

    module Emojis
      CHECK = "\u{2705}".freeze
      SKULL = "\u{1F480}".freeze
      RED_CROSS = "\u{274C}".freeze
      STOP_WATCH = "\u{23F1}".freeze
      QUESTION_MARK = "\u{003F}".freeze
    end

    RESULT_EMOJIS = {
      pass: Emojis::CHECK,
      fail: Emojis::RED_CROSS,
      error: Emojis::SKULL,
      timeout: Emojis::STOP_WATCH
    }.tap { _1.default = Emojis::QUESTION_MARK }.freeze

    def print_short_summary(passing_rows, all_rows, output_filename, start_time, end_time)
      elapsed_time = (end_time - start_time).to_f
      bug_count = all_rows.size
      submission_count = all_rows.values.flatten(1).size
      run_count = all_rows.values.flatten(2).size
      bugs_per_s = (bug_count / elapsed_time).round(2)
      submissions_per_s = (submission_count / elapsed_time).round(2)
      runs_per_s = (run_count / elapsed_time).round(2)

      puts "#{passing_rows.size}/#{all_rows.size} passed (#{(passing_rows.size / all_rows.size.to_f * 100.0).round(2)}%)"
      puts "Evaluated #{bug_count} bugs (#{bugs_per_s}/s), #{submission_count} submissions (#{submissions_per_s}/s), #{run_count} runs (#{runs_per_s}/s) in #{seconds_to_time_str elapsed_time} seconds"
      puts "Evaluation results written to #{output_filename}"
      puts "Use `rbugr analyze #{output_filename}` to analyze performance"
    end


    def seconds_to_time_str(seconds)
      format('%02d:%02d:%02d', seconds / 3600, (seconds / 60) % 60, seconds % 60)
    end

    def evaluate_bugs(bugs, tests, fixed:, buggy:, abort_on_timeout: 1, abort_on_fail:1, abort_on_error: 1, progress_proc: nil, workers:)
      test_worker_pool = TestWorkerPool.new logger: @logger, size: workers
      eval_rows = {}
      eval_rows_mutex = Mutex.new
      pool = ThreadPool.new size: workers

      bugs.each_with_index do |(bug_id, bug), bug_index|
        pool.post do
          problem_tests = tests[bug.problem_id]
          progress = progress_proc&.call bug_index

          begin
            rows =
              if fixed || buggy
                submission = fixed ? bug.fixed_submission : bug.buggy_submission
                runs, worker_info = test_worker_pool.submit(submission, problem_tests,
                                              abort_on_timeout: abort_on_timeout,
                                              abort_on_error: abort_on_error,
                                              abort_on_fail: abort_on_fail)

                [runs]
              elsif bug.candidate_submissions.nil?
                puts "No candidates for bug #{bug.id}"
                []
              else
                bug.candidate_submissions.inject([]) do |acc, candidate_submission|
                  runs, worker_info = test_worker_pool.submit(candidate_submission, problem_tests,
                                                    abort_on_timeout: abort_on_timeout,
                                                    abort_on_error: abort_on_error,
                                                    abort_on_fail: abort_on_fail)
                  acc << runs
                  break acc if runs.all? { _1.fetch(:result) == 'pass' }
                  acc
                end
              end
            eval_rows_mutex.synchronize do
              eval_rows[bug.id] = rows if rows
            end
            max_run = rows.max_by { |runs| runs.count { _1.fetch(:result) == 'pass' }}
            language = Bugs::LANGUAGE_NAME_MAP.fetch(bug.language)
            progress_str = format('[%2d%%]', (progress * 100).round)
            if max_run
              # passed = max_run.all? { _1.fetch(:result) == 'pass' }
              emoji_str = max_run.map { RESULT_EMOJIS[_1.fetch(:result).to_sym] }.tally.map { format("%3d\u{00d7}%s", _2, _1) }.join(' ')
              @logger.info("#{progress_str} [Worker#{worker_info[:worker_id]}] Bug #{format('%6d', bug.id)} (#{language}): #{emoji_str} #{max_run.size}/#{problem_tests.size}")
            else
              @logger.info("#{progress_str} Bug #{format('%5d', bug.id)} (#{language}): no prediction found")
            end
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
      def load(filenames, preds_filename = nil, split: nil, languages: nil, version: nil)
        filenames = Array(filenames)
        languages = filenames.map do |filename|
          if (match = filename.match(/(c|cpp|javascript|java|ruby|python|php|go)_/))
            match[1].to_sym
          else
            raise ArgumentError, "invalid submissions filename '#{filename}'"
          end
        end

        logger = Logger.new
        bugs = {}

        filenames.zip(languages) do |filename, language|
          JSONUtils.load_file(filename).each do |hash|
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
              line_hunks: hash.fetch(:line_hunks),
              buggy_submission:,
              fixed_submission:
            )

            raise 'duplicate bug' if bugs.key? bug.id

            bugs[bug.id] = bug
          end
        end

        if preds_filename
          JSONUtils.load_file(preds_filename).each do |hash|
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

        new bugs, logger: logger, split:, languages:, version:
      end

      private :new
    end
  end
end
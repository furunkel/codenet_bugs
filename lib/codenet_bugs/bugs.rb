require 'logger'
require 'json'

require 'codenet_bugs/jsonl'
require 'codenet_bugs/thread_pool'
require 'codenet_bugs/test_worker_pool'
require 'codenet_bugs/test_runner2'
require 'codenet_bugs/logger'

module CodenetBugs
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
        @logger.progress = (all_rows.size + bug_index.to_f + 0.5) / @bugs.size
      end

      eval_rows = evaluate_bugs(bugs, tests, sanity_check:, abort_on_timeout:, abort_on_fail:, abort_on_error:, progress_proc:)

      all_rows.merge! eval_rows

      checkpoint = "/tmp/codenet_bugs_checkpoint_#{Time.now.to_i}.json"
      File.write(checkpoint, all_rows.to_h.to_json)
      @logger.info "Writing checkpoint to #{checkpoint}"
      restart! checkpoint if restart
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
          progress_proc&.call bug_index
          #p bug.source_submission.accepted?
          #p bug.target_submission.accepted?

          begin
            rows =
              if sanity_check
                runs = test_worker_pool.submit(bug.target_submission, io_samples,
                                              abort_on_timeout: abort_on_timeout,
                                              abort_on_error: abort_on_error,
                                              abort_on_fail: abort_on_fail)

                [runs]
              else
                bug.candidate_submissions.inject([]) do |acc, candidate_submission|
                  runs = test_worker_pool.submit(candidate_submission, io_samples,
                                                    abort_on_timeout: abort_on_timeout,
                                                    abort_on_error: abort_on_error,
                                                    abort_on_fail: abort_on_fail)
                  acc << runs
                  break acc if runs.all? { _1.fetch(:result) == 'pass' }
                  acc
                end
              end
            #rows = IOSampleRunner.new(bug.source_submission, io_samples, abort_on_timeout: abort_on_timeout).run!
            #rows2 = IOSampleRunner.new(bug.target_submission, io_samples, abort_on_timeout: abort_on_timeout).run!
            eval_rows_mutex.synchronize do
              eval_rows[bug.id] = rows if rows
            end
            max_run = rows.max_by { |runs| runs.count { _1.fetch(:result) == 'pass' }}
            passed = max_run.all? { _1.fetch(:result) == 'pass' }
            @logger.info("Bug #{bug.id} (#{bug.language}): #{passed} #{max_run ? max_run.size : 0}/#{io_samples.size}")
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
      def load_internal(preds_filename = nil)
        filenames = Dir[File.join(CodenetBugs.data_dir, '*_{c,cpp,go,java,javascript,php,python,ruby}_*.jsonl.gz')]
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

        bugs = {}

        filenames.zip(languages) do |filename, language|
          JSONL.load_file(filename) do |hash|
            problem_id = hash.fetch(:problem_id).to_sym

            source_submission = Submission.new(
              id: hash.fetch(:source_submission_id),
              content: hash.fetch(:source),
              main_class: hash[:source_main_class],
              accepted: false,
              problem_id:,
              language:, 
            )

            target_submission = Submission.new(
              id: hash.fetch(:target_submission_id),
              content: hash.fetch(:target),
              main_class: hash[:target_main_class],
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
              source_submission:,
              target_submission:
            )

            raise 'duplicate bug' if bugs.key? bug.id

            bugs[bug.id] = bug
          end
        end

        if preds_filename
          JSONL.load_file(preds_filename) do |hash|
            bug = bugs.fetch(hash[:id])
            candidate_submissions = hash.fetch(:preds).map do |predicted_content|
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
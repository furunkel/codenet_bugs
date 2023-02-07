require 'run_bug_run/dataset'

module RunBugRun
  module CLI
    class Bugs < SubCommand

      no_commands {
        def load_bug(id)
          version = options.fetch(:version) { RunBugRun::Dataset.last_version }
          dataset = RunBugRun::Dataset.new(version:)
          filename = dataset.find_filename_by_id(:bugs, id)
          bugs = RunBugRun::Bugs.load([filename])
          [dataset, bugs[id]]
        end
      }

      desc "diff ID", "show diff of given bug"
      def diff(id)
        _, bug = load_bug(id)
        puts bug.diff(:buggy, :fixed)
      end

      desc "show ID", "show bug for given ID"
      method_option :version, type: :string
      # method_option :language, type: :string, enum: RunBugRun::Bugs::ALL_LANGUAGES.map(&:to_s)
      # method_option :split, type: :string, enum: RunBugRun::Bugs::SPLITS.map(&:to_s)
      def show(id)
        _, bug = load_bug(id)
        hash = {
          id: bug.id,
          language: bug.language,
          problem_id: bug.problem_id,
          change_count: bug.change_count,
          labels: bug.labels
        }

        puts JSON.pretty_generate(hash)
      end

      desc "exec ID [FILES]", "execute specified bug"
      method_option :fixed, desc: 'run the fixed version of the specified bug (as a sanity check)', type: :boolean, default: false
      method_option :abort_on_error, desc: 'stop execution on first error', type: :boolean, default: true
      method_option :abort_on_fail, desc: 'stop execution on first failing test', type: :boolean, default: false
      method_option :abort_on_timeout, desc: 'stop execution after specified number of seconds', type: :numeric, default: 1
      def exec(id)
        dataset, bug = load_bug(id)
        tests = dataset.load_tests

        test_worker_pool = TestWorkerPool.new size: 1

        submission =
          if options.fetch(:fixed)
            bug.fixed_submission
          else
            bug.buggy_submission
          end

        abort_on_timeout = options.fetch(:abort_on_timeout)
        abort_on_error = options.fetch(:abort_on_error)
        abort_on_fail = options.fetch(:abort_on_fail)
        
        submission_tests = tests[bug.problem_id]
        runs, _worker_info = test_worker_pool.submit(submission, submission_tests,
                                       abort_on_timeout:,
                                       abort_on_error:,
                                       abort_on_fail:)

        puts JSON.pretty_generate(runs)
      end

    end
  end
end
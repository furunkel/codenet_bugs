require 'thor'

require 'codenet_bugs/bugs'
require 'codenet_bugs/tests'

module CodenetBugs
  module CLI
    class Main < Thor
      # desc "eval", "create and publish docs"
      # subcommand "eval", Eval

      # desc "run", "create and publish docs"
      # # subcommand "run", Run

      desc "exec BUG_ID [FILES]", "exec specified bug"
      method_option :fixed, desc: 'Run the fixed version of the specified bug (as a sanity check)', type: :boolean, default: false
      def exec(bug_id)
        bugs = Bugs.load_internal
        tests = Tests.load_internal
        bug = bugs[bug_id]

        test_worker_pool = TestWorkerPool.new size: 1

        submission =
          if options.fetch(:fixed)
            bug.target_submission
          else
            #TODO
            raise
          end

        # submission = submission.dup
        # submission.content = "n,m=gets.split;x = n.to_i.times.map{gets}; p x; x = x.reverse.uniq[0,m.to_i]; p x; puts x.join"

        abort_on_timeout = 1
        abort_on_error = nil
        abort_on_fail = nil
        
        submission_tests = tests[bug.problem_id]
        runs = test_worker_pool.submit(submission, submission_tests,
                                       abort_on_timeout: abort_on_timeout,
                                       abort_on_error: abort_on_error,
                                       abort_on_fail: abort_on_fail)

        p runs
      end
    end
  end

  # class SubCommand < Thor
  #   def self.banner(command, namespace = nil, subcommand = false)
  #     "#{basename} #{subcommand_prefix} #{command.usage}"
  #   end

  #   def self.subcommand_prefix
  #     self.name.gsub(%r{.*::}, '').gsub(%r{^[A-Z]}) { |match| match[0].downcase }.gsub(%r{[A-Z]}) { |match| "-#{match[0].downcase}" }
  #   end
  # end
end

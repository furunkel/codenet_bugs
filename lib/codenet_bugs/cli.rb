require 'thor'
require 'pp'
require 'codenet_bugs/bugs'
require 'codenet_bugs/tests'

module CodenetBugs
  module CLI
    class Main < Thor
      # desc "eval", "create and publish docs"
      # subcommand "eval", Eval

      # desc "run", "create and publish docs"
      # # subcommand "run", Run

      desc "junit BUG_IDS", "generate JUnit tests for the specified bugs"
      method_option :o, desc: 'Output directory', type: :string, required: true
      method_option :version, desc: 'Bug version (prediction, buggy or fixed)', type: :string, default: :buggy
      def junit(*bug_ids)
        require 'codenet_bugs/junit_generator'

        bugs = Bugs.load_internal :test, languages: :java
        version = options.fetch(:version).to_sym
        output_dir = options.fetch(:o)

        tests = Tests.load_internal

        generator = JUnitGenerator.new(bugs.take(1), tests, output_dir:, version:)
        generator.generate!
      end


      desc "exec BUG_ID [FILES]", "execute specified bug"
      method_option :fixed, desc: 'Run the fixed version of the specified bug (as a sanity check)', type: :boolean, default: false
      def exec(bug_id)
        bugs = Bugs.load_internal :test
        tests = Tests.load_internal
        bug = bugs[bug_id]

        test_worker_pool = TestWorkerPool.new size: 1

        submission =
          if options.fetch(:fixed)
            bug.fixed_submission
          else
            #TODO
            raise
          end

        abort_on_timeout = 1
        abort_on_error = nil
        abort_on_fail = nil
        
        submission_tests = tests[bug.problem_id]
        runs, _worker_info = test_worker_pool.submit(submission, submission_tests,
                                       abort_on_timeout: abort_on_timeout,
                                       abort_on_error: abort_on_error,
                                       abort_on_fail: abort_on_fail)

        pp runs
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

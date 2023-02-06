require 'thor'
require 'pp'
require 'run_bug_run/bugs'
require 'run_bug_run/tests'

module RunBugRun
  module CLI

    class SubCommand < Thor
      def self.banner(command, namespace = nil, subcommand = false)
        "#{basename} #{subcommand_prefix} #{command.usage}"
      end

      def self.subcommand_prefix
        self.name.gsub(%r{.*::}, '').gsub(%r{^[A-Z]}) { |match| match[0].downcase }.gsub(%r{[A-Z]}) { |match| "-#{match[0].downcase}" }
      end
    end
    
    class Main < Thor
      # desc "eval", "create and publish docs"
      # subcommand "eval", Eval

      # desc "run", "create and publish docs"
      # # subcommand "run", Run

      def self.exit_on_failure?
          true
      end

      desc "junit BUG_IDS", "generate JUnit tests for the specified bugs"
      method_option :o, desc: 'Output directory', type: :string, required: true
      method_option :version, desc: 'Bug version (prediction, buggy or fixed)', type: :string, required: true
      method_option :limit, desc: 'Only export the first n bugs', type: :numeric, default: nil
      def junit(*bug_ids)
        require 'run_bug_run/junit_generator'

        bugs = Bugs.load_internal :test, languages: :java

        if bug_ids.any?
          bugs = bugs.values_at(*bug_ids.map(&:to_i))
        end

        version = options.fetch(:version).to_sym
        output_dir = options.fetch(:o)

        tests = Tests.load_internal

        if options[:limit]
          bugs = bugs.take(options[:limit])
        end
        generator = JUnitGenerator.new(bugs, tests, output_dir:, version:)
        generator.generate!
      end

      desc "label_stats OUTPUT_FILE", "analyze output file"
      def label_stats(output_filename)
        runs = JSON.load_file!(output_filename)
        ids = runs.keys

        p runs.size
        p ids

        bugs = RunBugRun::Bugs.load_internal :test

        labels = []

        ids.each do |id|
          bug = bugs[id]
          if bug.nil?
            puts "Bug with id #{id} not found..."
            next
          end
          labels.concat(bug.labels) if bug.labels
        end

        diffs = []
        runs.each do |id, run|
          puts id
          puts %Q("#{run.dig(0, 'patches', 0, 'PATCH_DIFF_ORIG')}").undump
          puts "###"
        end

        pp labels.tally.sort_by{_2}
        pp ids.size
      end

      no_commands do
        def partition_runs(runs, options = {})
          if options[:only_passing]
            [runs, []]
          else
            runs.partition { |_bug_id, pred_runs| pred_runs.any?{ |pr| pr.all? { _1['result'] == 'pass'}}}
          end
        end
      end

      desc "analyze OUTPUT_FILE", "analyze evaluation results"
      method_option :by_language, desc: 'Analyze per language', type: :boolean, default: false
      method_option :by_change_count, desc: 'Analyze per language', type: :boolean, default: false
      method_option :by_label, desc: 'Analyze per label', type: :boolean, default: false
      method_option :only_passing, desc: 'The file to analyze contains passing bugs only', type: :boolean, default: false
      method_option :language, desc: 'Restrict to a single language only', type: :string
      def analyze(output_filename)
        runs = JSON.load_file output_filename

        valid_bugs, _failing_bugs = partition_runs(runs, options)

        bugs = Bugs.load_internal :test, languages: Array(options.fetch(:language, Bugs::ALL_LANGUAGES))

        p "#{bugs.size}/#{runs.size}"

        run_count = (options[:only_passing] ? bugs : runs).size.to_f

        result = {
          plausibility_rate: (valid_bugs.size / run_count).round(4)
        }

        if options.fetch(:by_label)
          all_labels = Hash.new { |h, k| h[k] = 0 }
          bugs.each do |bug|
            # bug = bugs[bug_id]
            bug&.labels&.each { all_labels[_1] += 1}
            # if bug.nil?
            #   puts "Missing bug #{bug_id}"
            # end
          end

          # Remove low-frequency labels
          all_labels.delete_if { |k, v| v < 30 }

          all_labels_abs = all_labels.dup
          all_labels_sum = all_labels.sum(0) { _2 }.to_f
          all_labels = all_labels.transform_values { [_1 / all_labels_sum, _1] }

          # label_dist = JSONUtils.load_internal('export', 'export_label_dist_test.json.gz', symbolize_names: false)
          valid_labels = Hash.new { |h, k| h[k] = 0 }

          valid_bugs.each do |bug_id, _pred_runs|
            bug = bugs[bug_id]
            bug&.labels&.each { valid_labels[_1] += 1}
          end

          # only keep frequent labels
          valid_labels.delete_if { |k, v| !all_labels.key? k }

          valid_labels_sum = valid_labels.sum(0) { _2 }.to_f
          valid_labels = valid_labels.map { |k, v| [k, [v / valid_labels_sum, v]] }.to_h

          scores = all_labels.map do |label, (rel_f, abs_f)|
            [
              label,
              [((valid_labels.dig(label, 0) || 0.0)) / rel_f, valid_labels.dig(label, 1) || 0, abs_f]
            ]
          end

          p scores.sort_by{ [-_2[0], -_2[-1]] }.take(15)
          p scores.sort_by{ [_2[0], -_2[-1]] }.take(15)
        end

        if options.fetch(:by_language) && !options[:language] && !options[:only_passing]
          runs.group_by { |bug_id, _pred_runs| bugs[bug_id]&.language }.each do |language, runs|
            # valid_bugs, _failing_bugs = runs.partition { |_bug_id, pred_runs|  pred_runs.any?{ |pr| pr.all? { _1['result'] == 'pass'}}}
            valid_bugs, _failing_bugs = partition_runs(runs, options)
            result[:"plausibility_rate_#{language}"] = (valid_bugs.size / runs.size.to_f).round(4)
          end
        end

        if options.fetch(:by_change_count)
          runs.group_by { |bug_id, _pred_runs| bugs[bug_id]&.change_count }.each do |change_count, runs|
            valid_bugs, _failing_bugs = partition_runs(runs, options)

            p [change_count, runs.size]

            z = 
              if options[:only_passing]
                bugs.count { |bug| bug.change_count == change_count }.to_f
              else
                runs.size.to_f
              end

            result[:"plausibility_rate_change_count#{change_count}"] = (valid_bugs.size / z).round(4)
          end

          runs.group_by { |bug_id, _pred_runs| bugs[bug_id]&.line_hunks&.then{ _1 ? _1 : 'other' } }.each do |change_count, runs|
            valid_bugs, _failing_bugs = partition_runs(runs, options)
            z = 
              if options[:only_passing]
                bugs.count { |bug| bug.change_count == change_count }.to_f
              else
                runs.size.to_f
              end
            result[:"plausibility_rate_line_hunks#{change_count}"] = (valid_bugs.size / z).round(4)
          end
        end

        pp result.sort_by { _1 }.to_h
      end

      desc "exec BUG_ID [FILES]", "execute specified bug"
      method_option :fixed, desc: 'Run the fixed version of the specified bug (as a sanity check)', type: :boolean, default: false
      def exec(bug_id)
        bugs = Bugs.load_internal
        tests = Tests.load_internal
        bug = bugs[bug_id]

        test_worker_pool = TestWorkerPool.new size: 1

        submission =
          if options.fetch(:fixed)
            bug.fixed_submission
          else
            bug.buggy_submission
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

      require 'run_bug_run/cli/dataset'
      desc "dataset", "Download and manage dataset versions"
      subcommand "dataset", CLI::Dataset
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
require 'thor'
require 'pp'
require 'run_bug_run/bugs'
require 'run_bug_run/tests'

module RunBugRun
  module CLI

    class SubCommand < Thor
      def self.banner(command, _namespace = nil, _subcommand = false)
        "#{basename} #{subcommand_prefix} #{command.usage}"
      end

      def self.subcommand_prefix
        self.name.gsub(%r{.*::}, '').gsub(%r{^[A-Z]}) { |match| match[0].downcase }.gsub(%r{[A-Z]}) { |match| "-#{match[0].downcase}" }
      end
    end
    
    class Main < Thor

      def self.exit_on_failure?
        true
      end

      desc 'eval [FILENAME]', 'evaluate candidate fixes stored in FILENAME'
      method_option :checkpoint, desc: 'continue evaluation from previous (aborted) evaluation', type: :string, default: nil
      method_option :output_filename, desc: 'output filename', type: :string, required: true, aliases: %w[-o]
      method_option :version, desc: 'dataset version (defaults to most recent installed version)', type: :string
      method_option :languages, desc: 'languages to evaluate (defaults to all)', type: :array, default: RunBugRun::Bugs::ALL_LANGUAGES.map(&:to_s)
      method_option :split, desc: 'split to evaluate (defaults to the test set)', type: :string, enum: RunBugRun::Bugs::SPLITS.map(&:to_s)
      method_option :fixed, desc: 'evaluate the fixed version of the specified bug (as a sanity check)', type: :boolean, default: false
      method_option :buggy, desc: 'evaluate the buggy version of the specified bug', type: :boolean, default: false
      method_option :abort_on_error, desc: 'stop execution on first error', type: :boolean, default: true
      method_option :abort_on_fail, desc: 'stop execution on first failing test', type: :boolean, default: false
      method_option :abort_on_timeout, desc: 'stop execution after specified number of seconds', type: :numeric, default: 1
      method_option :workers, desc: 'number of workers to use for evaluation', type: :numeric, default: 8
      def eval(filename=nil)
        version = options.fetch(:version) { RunBugRun::Dataset.last_version }
        languages = options.fetch(:languages, RunBugRun::Bugs::ALL_LANGUAGES).map(&:to_sym)
        unless (languages - RunBugRun::Bugs::ALL_LANGUAGES).empty?
          raise ArgumentError, "invalid languages: must be subset of #{RunBugRun::Bugs::ALL_LANGUAGES}"
        end
        dataset = RunBugRun::Dataset.new(version:)
        bugs = dataset.load_bugs split: options.fetch(:split, :test).to_sym, languages: languages.map(&:to_sym)
        tests = dataset.load_tests
        bugs.evaluate! tests,
          checkpoint: options.fetch(:checkpoint, nil),
          output_filename: options.fetch(:output_filename),
          fixed: options.fetch(:fixed),
          buggy: options.fetch(:buggy),
          abort_on_timeout: options.fetch(:abort_on_timeout),
          abort_on_fail: options.fetch(:abort_on_fail),
          abort_on_error: options.fetch(:abort_on_error)
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

      desc 'label_stats OUTPUT_FILE', 'analyze output file'
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
            runs.partition { |_bug_id, pred_runs| pred_runs.any?{ |pr| pr.all? { _1.fetch('result') == 'pass'}}}
          end
        end
      end

      desc 'failing OUTPUT_FILE', 'show ids of failing bugs'
      def failing(output_filename)
        eval_output = JSONUtils.load_file output_filename
        results = eval_output[:results]

        failing = results.select do |_bug_id, candidate_runs|
          candidate_runs.any? {|runs| runs.any? { _1.fetch(:result) != 'pass' } }
        end

        puts JSON.pretty_generate(failing)
      end

      desc 'passing OUTPUT_FILE', 'show ids of passing bugs'
      def passing(output_filename)
        eval_output = JSONUtils.load_file output_filename
        results = eval_output[:results]

        passing = results.select do |_bug_id, candidate_runs|
          candidate_runs.any? {|runs| runs.all? { _1.fetch(:result) == 'pass' } }
        end

        puts JSON.pretty_generate(passing)
      end

      desc 'analyze OUTPUT_FILE', 'analyze evaluation results'
      method_option :by_language, desc: 'Analyze per language', type: :boolean, default: false
      method_option :by_change_count, desc: 'Analyze per language', type: :boolean, default: false
      method_option :by_label, desc: 'Analyze per label', type: :boolean, default: false
      method_option :only_passing, desc: 'The file to analyze contains passing bugs only', type: :boolean, default: false
      def analyze(output_filename)
        output = JSONUtils.load_file output_filename, symbolize_names: false
        version = output.fetch('version')
        languages = output.fetch('languages').map(&:to_sym)
        dataset = RunBugRun::Dataset.new(version:)
        bugs = dataset.load_bugs(split: output.fetch('split').to_sym, languages:)

        runs = output.fetch('results')
        valid_bugs, _failing_bugs = partition_runs(runs, options)

        run_count = (options[:only_passing] ? bugs : runs).size.to_f

        result = {
          plausibility_rate: (valid_bugs.size / run_count).round(4),
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

          best_labels = scores.sort_by{ [-_2[0], -_2[-1]] }.take(15).to_h
          worst_labels = scores.sort_by{ [_2[0], -_2[-1]] }.take(15).to_h

          result[:best_labels] = best_labels
          result[:wort_labels] = worst_labels
        end

        if options.fetch(:by_language) && !options[:only_passing]
          runs.group_by { |bug_id, _pred_runs| bugs[bug_id]&.language }.each do |language, runs|
            # valid_bugs, _failing_bugs = runs.partition { |_bug_id, pred_runs|  pred_runs.any?{ |pr| pr.all? { _1['result'] == 'pass'}}}
            valid_bugs, _failing_bugs = partition_runs(runs, options)
            result[:"plausibility_rate_#{language}"] = (valid_bugs.size / runs.size.to_f).round(4)
          end
        end

        if options.fetch(:by_change_count)
          runs.group_by { |bug_id, _pred_runs| bugs[bug_id]&.change_count }.each do |change_count, runs|
            valid_bugs, _failing_bugs = partition_runs(runs, options)

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

        puts JSON.pretty_generate(result.sort.to_h)
      end

      require 'run_bug_run/cli/dataset'
      desc "dataset", "Download and manage dataset versions"
      subcommand "dataset", CLI::Dataset

      require 'run_bug_run/cli/bugs'
      desc 'bugs', "Get information on bugs"
      subcommand "bugs", CLI::Bugs
    end
  end
end
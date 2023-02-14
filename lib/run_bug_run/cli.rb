require 'thor'
require 'pp'
require 'run_bug_run/bugs'
require 'run_bug_run/tests'
require 'run_bug_run/candidate_submissions'

module RunBugRun
  module CLI
    class SubCommand < Thor
      def self.banner(command, _namespace = nil, _subcommand = false)
        "#{basename} #{subcommand_prefix} #{command.usage}"
      end

      def self.subcommand_prefix
        name.gsub(/.*::/, '').gsub(/^[A-Z]/) do |match|
          match[0].downcase
        end.gsub(/[A-Z]/) { |match| "-#{match[0].downcase}" }
      end
    end

    class Main < Thor
      def self.exit_on_failure?
        true
      end

      no_commands do
        def seconds_to_time_str(seconds)
          format('%02d:%02d:%02d', seconds / 3600, (seconds / 60) % 60, seconds % 60)
        end

        def print_eval_summary(all_rows, output_filename, start_time, end_time)
          elapsed_time = (end_time - start_time).to_f
          passing_rows = all_rows.select do |_bug_id, candidate_runs|
            candidate_runs.any? { |runs| runs.all? { _1.fetch(:result) == 'pass' } }
          end
          bug_count = all_rows.size
          submission_count = all_rows.values.flatten(1).size
          run_count = all_rows.values.flatten(2).size
          bugs_per_s = (bug_count / elapsed_time).round(2)
          submissions_per_s = (submission_count / elapsed_time).round(2)
          runs_per_s = (run_count / elapsed_time).round(2)

          # Write to stderr, as we normally output JSON to stdout
          # for consistency ?
          RunBugRun.logger.then do |l|
            l.info "#{passing_rows.size}/#{all_rows.size} passed (#{(passing_rows.size / all_rows.size.to_f * 100.0).round(2)}%)"
            l.info "Evaluated #{bug_count} bugs (#{bugs_per_s}/s), #{submission_count} submissions (#{submissions_per_s}/s), #{run_count} runs (#{runs_per_s}/s) in #{seconds_to_time_str elapsed_time} seconds"
            l.info "Evaluation results written to #{output_filename}"
            l.info "Use `rbugr analyze #{output_filename}` to analyze performance"
          end
        end
      end

      desc 'eval [FILENAME]', 'evaluate candidate fixes stored in FILENAME'
      method_option :checkpoint, desc: 'continue evaluation from previous (aborted) evaluation', type: :string,
                                 default: nil
      method_option :output_filename, desc: 'output filename', type: :string, required: true, aliases: %w[-o]
      method_option :version, desc: 'dataset version (defaults to most recent installed version)', type: :string
      method_option :languages, desc: 'languages to evaluate (defaults to all)', type: :array,
                                default: RunBugRun::Bugs::ALL_LANGUAGES.map(&:to_s)
      method_option :split, desc: 'split to evaluate (defaults to the test set)', type: :string,
                            enum: RunBugRun::Bugs::SPLITS.map(&:to_s)
      method_option :fixed, desc: 'evaluate the fixed version of the specified bug (as a sanity check)',
                            type: :boolean, default: false
      method_option :buggy, desc: 'evaluate the buggy version of the specified bug', type: :boolean, default: false
      method_option :abort_on_error, desc: 'stop execution on first error', type: :boolean, default: true
      method_option :abort_on_fail, desc: 'stop execution on first failing test', type: :boolean, default: false
      method_option :abort_on_timeout, desc: 'stop execution after specified number of seconds', type: :numeric,
                                       default: 1
      method_option :workers, desc: 'number of workers to use for evaluation', type: :numeric, default: 8
      method_option :limit, desc: 'only evaluate a limited number of bugs', type: :numeric, default: nil
      def eval(candidates_filename = nil)
        version = options.fetch(:version) { RunBugRun::Dataset.last_version }
        languages = options.fetch(:languages, RunBugRun::Bugs::ALL_LANGUAGES).map(&:to_sym)
        unless (languages - RunBugRun::Bugs::ALL_LANGUAGES).empty?
          raise ArgumentError, "invalid languages: must be subset of #{RunBugRun::Bugs::ALL_LANGUAGES}"
        end

        output_filename = options.fetch(:output_filename)
        dataset = RunBugRun::Dataset.new(version:)
        split = options.fetch(:split, :test).to_sym
        languages = languages.map(&:to_sym)
        bugs = dataset.load_bugs(split:, languages:)
        candidate_submissions = CandidateSubmissions.load(candidates_filename, bugs) if candidates_filename
        tests = dataset.load_tests

        limit = options[:limit]
        bugs = bugs.take(limit) if limit

        # We don't need accurate time. Time.now gives more human-friendly output
        start_time = Time.now # Process.clock_gettime(Process::CLOCK_MONOTONIC)

        results = bugs.evaluate! tests,
                                 candidates: candidate_submissions,
                                 checkpoint: options.fetch(:checkpoint, nil),
                                 fixed: options.fetch(:fixed),
                                 buggy: options.fetch(:buggy),
                                 abort_on_timeout: options.fetch(:abort_on_timeout),
                                 abort_on_fail: options.fetch(:abort_on_fail),
                                 abort_on_error: options.fetch(:abort_on_error)

        end_time = Time.now # Process.clock_gettime(Process::CLOCK_MONOTONIC)

        json = {
          split:,
          languages:,
          options:,
          version:,
          start_time:,
          end_time:,
          results:
        }

        print_eval_summary results, output_filename, start_time, end_time
        JSONUtils.write_json output_filename, json, compression: :gzip
      end

      desc 'junit BUG_IDS', 'generate JUnit tests for the specified bugs'
      method_option :o, desc: 'Output directory', type: :string, required: true
      method_option :version, desc: 'Bug version (prediction, buggy or fixed)', type: :string, required: true
      method_option :limit, desc: 'Only export the first n bugs', type: :numeric, default: nil
      def junit(*bug_ids)
        require 'run_bug_run/junit_generator'

        bugs = Bugs.load_internal :test, languages: :java

        bugs = bugs.values_at(*bug_ids.map(&:to_i)) if bug_ids.any?

        version = options.fetch(:version).to_sym
        output_dir = options.fetch(:o)

        tests = Tests.load_internal

        bugs = bugs.take(options[:limit]) if options[:limit]
        generator = JUnitGenerator.new(bugs, tests, output_dir:, version:)
        generator.generate!
      end

      desc 'analyze_cardumen OUTPUT_FILE', 'analyze output file'
      def analyze_cardumen(output_filename)
        output = JSONUtils.load_file(output_filename, symbolize_names: false)
        runs = output.fetch(:results)
        ids = runs.keys

        dataset = RunBugRun::Dataset.new(version: nil)
        bugs = dataset.load_bugs(split: :test, languages: %i[java])

        labels = []

        ids.each do |id|
          bug = bugs[id]
          if bug.nil?
            puts "Bug with id #{id} not found..."
            next
          end
          labels.concat(bug.labels) if bug.labels
        end

        result = runs.transform_values do |run|
          %("#{run.dig(0, 'patches', 0, 'PATCH_DIFF_ORIG')}").undump
        end

        puts JSON.pretty_generate result

        # pp labels.tally.sort_by { _2 }
        # pp ids.size
      end

      no_commands do
        def partition_runs(runs, options = {})
          if options[:only_passing]
            [runs, []]
          else
            runs.partition { |_bug_id, pred_runs| pred_runs.any? { |pr| pr.all? { _1.fetch('result') == 'pass' } } }
          end
        end
      end

      desc 'failing OUTPUT_FILE', 'show ids of failing bugs'
      def failing(output_filename)
        eval_output = JSONUtils.load_file output_filename
        results = eval_output[:results]

        failing = results.select do |_bug_id, candidate_runs|
          candidate_runs.any? { |runs| runs.any? { _1.fetch(:result) != 'pass' } }
        end

        puts JSON.pretty_generate(failing)
      end

      desc 'passing OUTPUT_FILE', 'show ids of passing bugs'
      def passing(output_filename)
        eval_output = JSONUtils.load_file output_filename
        results = eval_output[:results]

        passing = results.select do |_bug_id, candidate_runs|
          candidate_runs.any? { |runs| runs.all? { _1.fetch(:result) == 'pass' } }
        end

        puts JSON.pretty_generate(passing)
      end

      desc 'analyze OUTPUT_FILE', 'analyze evaluation results'
      method_option :by_language, desc: 'Analyze per language', type: :boolean, default: false
      method_option :by_change_count, desc: 'Analyze per language', type: :boolean, default: false
      method_option :by_label, desc: 'Analyze per label', type: :boolean, default: false
      method_option :only_passing, desc: 'The file to analyze contains passing bugs only', type: :boolean,
                                   default: false
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
          plausibility_rate: (valid_bugs.size / run_count).round(4)
        }

        if options.fetch(:by_label)
          all_labels = Hash.new { |h, k| h[k] = 0 }
          bugs.each do |bug|
            # bug = bugs[bug_id]
            bug&.labels&.each { all_labels[_1] += 1 }
            # if bug.nil?
            #   puts "Missing bug #{bug_id}"
            # end
          end

          # Remove low-frequency labels
          all_labels.delete_if { |_k, v| v < 30 }

          all_labels_abs = all_labels.dup
          all_labels_sum = all_labels.sum(0) { _2 }.to_f
          all_labels = all_labels.transform_values { [_1 / all_labels_sum, _1] }

          # label_dist = JSONUtils.load_internal('export', 'export_label_dist_test.json.gz', symbolize_names: false)
          valid_labels = Hash.new { |h, k| h[k] = 0 }

          valid_bugs.each do |bug_id, _pred_runs|
            bug = bugs[bug_id]
            bug&.labels&.each { valid_labels[_1] += 1 }
          end

          # only keep frequent labels
          valid_labels.delete_if { |k, _v| !all_labels.key? k }

          valid_labels_sum = valid_labels.sum(0) { _2 }.to_f
          valid_labels = valid_labels.map { |k, v| [k, [v / valid_labels_sum, v]] }.to_h

          scores = all_labels.map do |label, (rel_f, abs_f)|
            [
              label,
              [((valid_labels.dig(label, 0) || 0.0)) / rel_f, valid_labels.dig(label, 1) || 0, abs_f]
            ]
          end

          best_labels = scores.sort_by { [-_2[0], -_2[-1]] }.take(15).to_h
          worst_labels = scores.sort_by { [_2[0], -_2[-1]] }.take(15).to_h

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

          runs.group_by do |bug_id, _pred_runs|
            bugs[bug_id]&.line_hunks&.then do
              _1 || 'other'
            end
          end.each do |change_count, runs|
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
      desc 'dataset', 'download and manage dataset versions'
      subcommand 'dataset', CLI::Dataset

      require 'run_bug_run/cli/bugs'
      desc 'bugs', 'get information on bugs'
      subcommand 'bugs', CLI::Bugs
    end
  end
end

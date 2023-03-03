require 'run_bug_run/evaluation_results'

module RunBugRun
  module CLI
    class Analyzer
      attr_reader :options

      def initialize(output_filename, options)
        @output_filename = output_filename
        @options = options

        load
      end

      def analyze
        total_bugs = @options[:only_plausible] || @options[:ignore_missing] ? @bugs.size : @results.size

        plausible_count = @results.plausible_count

        report = {
          plausibility_rate: format_plausiblity_rate(plausible_count, total_bugs),
          plausible: plausible_count,
          total: total_bugs
        }

        analyze_by_label(report) if options.fetch(:by_label)
        analyze_by_language(report) if options.fetch(:by_language) && !options[:only_passing]
        analyze_by_exception(report) if options.fetch(:by_exception)
        analyze_by_change_count(report) if options.fetch(:by_change_count)

        report
      end

      private

      def load
        output = JSONUtils.load_file @output_filename, symbolize_names: false
        version = output.fetch('version')
        languages = output.fetch('languages').map(&:to_sym)
        split = output.fetch('split').to_sym

        dataset = RunBugRun::Dataset.new(version:)
        @bugs = dataset.load_bugs(split:, languages:)
        @tests = dataset.load_tests

        @results = EvaluationResults.new(output.fetch('results'), @bugs, @tests, only_plausible: @options.fetch(:only_plausible, false))
        @bugs = @bugs.select_bugs_with_results if options.fetch(:ignore_missing)
      end

      def format_plausiblity_rate(plausible, total)
        format = @options.fetch(:format, :rel)
        case format
        when 'abs'
          "#{plausible}/#{total}"
        when 'rel'
          (plausible / total.to_f).round(4)
        when 'verbose'
          "#{plausible}/#{total} #{(plausible / total.to_f).round(4)}"
        else
          raise "invalid plausibility rate format #{format}"
        end
      end

      def analyze_by_language(report)
        @results.group_by_language.each do |language, results|
          plausible_count = results.plausible_count
          report[:"plausibility_rate_#{language}"] = format_plausiblity_rate(plausible_count, results.size)
        end
      end

      def analyze_by_change_count(report)
        @results.group_by_change_count.each do |change_count, results|
          plausible_count = results.plausible_count
          report[:"plausibility_rate_change_count#{change_count}"] =
            format_plausiblity_rate(plausible_count, results.size)
        end
        # runs.group_by do |bug_id, _pred_runs|
        #   bugs[bug_id]&.line_hunks&.then do
        #     _1 || 'other'
        #   end
        # end.each do |change_count, runs|
        #   plausible_results, _failing_bugs = partition_runs(runs, options)
        #   z =
        #     if options[:only_passing]
        #       bugs.count { |bug| bug.change_count == change_count }.to_f
        #     else
        #       runs.size.to_f
        #     end
        #   result[:"plausibility_rate_line_hunks#{change_count}"] = (plausible_results.size / z).round(4)
        # end
      end

      def analyze_exceptions(report)
        @results.group_by_exceptions.each do |exceptions, results|
          name =
            if exceptions.nil? || exceptions.empty?
              'no_exceptions'
            else
              exceptions.join('_')
            end

          # plausible_results, _failing_bugs = runs.partition { |_bug_id, pred_runs|  pred_runs.any?{ |pr| pr.all? { _1['result'] == 'pass'}}}
          plausible_count = results.plausible_count
          report[:"plausibility_rate_#{name}"] = abs_rel(options, plausible_count, results.size)
        end
      end

      def analyze_by_label(report)
        label_counts = Hash.new { |h, k| h[k] = 0 }
        @bugs.each do |bug|
          labels = bug&.labels
          if labels.nil? || labels.empty?
            label_counts['no_label'] += 1
          else
            labels.each { label_counts[_1] += 1 }
          end
        end

        # Remove low-frequency labels
        label_counts.delete_if { |_label, count| count < 30 }

        label_counts_sum = label_counts.sum { |_label, count| count }.to_f
        # label_counts = all_labels.transform_values { [_1 / all_labels_sum, _1] }
        plausible_label_counts = Hash.new { |h, k| h[k] = 0 }

        plausible_results = @results.where_any_plausible_candidate
        plausible_results.each_bug do |bug|
          labels = bug&.labels
          if labels.nil? || labels.empty?
            plausible_label_counts['no_label'] += 1
          else
            labels.each { plausible_label_counts[_1] += 1 }
          end
        end

        # only keep frequent labels
        plausible_label_counts.delete_if { |label, _count| !label_counts.key? label }

        plausible_label_counts_sum = plausible_label_counts.sum { |_label, count| count }.to_f
        # plausible_label_counts = plausible_label_counts.map { |k, v| [k, [v / plausible_label_counts_sum, v]] }.to_h

        scores = label_counts.map do |label, count|
          rel_freq = count / label_counts_sum
          plausible_count = plausible_label_counts.fetch(label, 0)
          plausible_rel_freq = plausible_count / plausible_label_counts_sum

          r = plausible_rel_freq / rel_freq

          [label, [r, plausible_count, count]]
        end

        best_labels = scores.sort_by { |_label, freqs| [-freqs[0], -freqs[-1]] }.take(15).to_h
        worst_labels = scores.sort_by { |_label, freqs| [freqs[0], -freqs[-1]] }.take(15).to_h

        report[:best_labels] = best_labels
        report[:wort_labels] = worst_labels
        report[:no_labels] = scores.assoc('no_label')[1]
      end
    end
  end
end

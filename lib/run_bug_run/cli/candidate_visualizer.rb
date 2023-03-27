require 'erb'
require 'set'

module RunBugRun
  module CLI
    class CandidateVisualizer
      attr_reader :options

      COLORS = {
        'error' => 'black',
        'fail' => 'red',
        'pass' => 'green',
        'timeout' => 'yellow',
        'compilation_error' => 'gray'
      }.freeze

      def initialize(output, options)
        @options = options

        version = output.fetch('version')
        languages = output.fetch('languages').map(&:to_sym)
        split = output.fetch('split').to_sym

        dataset = RunBugRun::Dataset.new(version:)
        @bugs = dataset.load_bugs(split:, languages:)
        @tests = dataset.load_tests

        @results = EvaluationResults.new(
          output.fetch('results'),
          @bugs, @tests,
          only_plausible: @options.fetch(:only_plausible, false),
          candidate_limit: @options.fetch(:candidate_limit, nil)
        ).trim_to_bugs

        @height = @results.size
        @width = @results.candidates_per_bug
        @backgrounds = COLORS.transform_values { "background-color: #{_1};" }
        (2...COLORS.size).each do |n|
          COLORS.keys.combination(n).each do |c|
            @backgrounds[c.join('_')] = striped_background(COLORS.values_at(*c))
          end
        end
      end

      def striped_background(colors)
        f = 100.0 / (2 * colors.size)
        gradients = ["#{colors.first} #{f}%"]
        colors[1..].each_with_index do |color, index|
          gradients << "#{color} #{(index + 1) * f}%"
          gradients << "#{color} #{(index + 2) * f}%"
        end
        colors.each_with_index do |color, index|
          gradients << "#{color} #{(index * f) + 50}%"
          gradients << "#{color} #{((index + 1) * f) + 50}%"
        end
        "background-image: linear-gradient(45deg, #{gradients.join(', ')});"
      end

      def render!
        template = File.read(File.join(RunBugRun.gem_data_dir, 'templates', 'vis', 'candidates.html.erb'))

        labels = Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = Set.new } }
        labels_per_problem = Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = Set.new } }

        data = Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = {} } }
        @results.to_hash.each do |bug_id, candidates_results|
          bug = @bugs[bug_id]
          labels[bug.language][bug_id].merge(bug.labels) if bug.labels
          labels_per_problem[bug.language][bug.problem_id].merge(bug.labels) if bug.labels

          data[bug.language][bug.problem_id][bug_id] = candidates_results.map do |candidate_results|
            results = candidate_results.map { _1.fetch('result') }
            results.uniq!
            results.sort!
            results.join('_')
          end
        end

        data.each do |language, language_data|
          language_labels = labels[language]
          language_labels_per_problem = labels_per_problem[language]
          html = ERB.new(template).result(binding)
          filename = "/tmp/#{language}.html.gz"
          puts "Writing #{filename}"
          Zlib::GzipWriter.open(filename) do |gz|
            gz.write html
          end
        end
        # File.write('/tmp/test.html', html.string)
      end
    end
  end
end

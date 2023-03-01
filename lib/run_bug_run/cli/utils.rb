require 'run_bug_run/json_utils'
require 'csv'

module RunBugRun
  module CLI
    class Utils < SubCommand
      desc 'to_table', 'builds a table by grouping keys from multiple JSON output files'
      method_option :o, desc: 'Output filename', type: :string, required: true
      def to_table(*filenames)
        input_data = filenames.map { JSONUtils.load_file _1 }

        keys = input_data.flat_map(&:keys).uniq

        table = {}

        keys.each do |key|
          table[key] = input_data.map { _1.fetch(key, nil) }
        end

        CSV.open(options.fetch(:o), 'w') do |csv|
          csv << ['key', *filenames]
          table.each do |key, values|
            csv << [key, *values]
          end
        end
      end
    end
  end
end

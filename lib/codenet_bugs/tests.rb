module CodenetBugs
  class Tests
    def [](problem_id)
      @tests.fetch(problem_id)
    end

    def initialize(tests)
      @tests = tests
    end

    class << self
      def load_internal
        filename = File.join(CodenetBugs.data_dir, 'export_tests_all.jsonl.gz')
        load(filename)
      end

      def load(filename)
        tests = Hash.new { |h, k| h[k] = [] }
        JSONL.load_file(filename) do |hash|
          test = Test.new(
            id: hash.fetch(:id),
            input: hash.fetch(:input),
            output: hash.fetch(:output)
          )
          tests[hash[:problem_id].to_sym] << test
        end

        new tests
      end

      private :new
    end
  end
end
module RunBugRun
  class EvaluationResults
    attr_reader :bugs, :tests, :only_plausible

    def initialize(results_hash, bugs, tests, only_plausible: false)
      @only_plausible = only_plausible
      @results_hash = results_hash
      @bugs = bugs
      @tests = tests
    end

    def dup
      self.new(@results_hash.dup, @bugs, @tests, only_plausible:)
    end

    def size = @results_hash.size

    def empty?
      @results_hash.empty?
    end

    def group_by_language
      wrap_values(@results_hash.group_by { |bug_id, _candidate_results| @bugs[bug_id]&.language })
    end

    def group_by_exceptions
      wrap_values(@results_hash.group_by do |bug_id, _candidate_results|
        @bugs[bug_id]&.buggy_submission&.errors&.flat_map { _1[:exception]&.uniq&.compact }
      end)
    end

    def group_by_change_count
      wrap_values(@results_hash.group_by { |bug_id, _candidate_results| @bugs[bug_id]&.change_count })
    end

    def each_bug(&)
      @results_hash.each_key.lazy.map { |bug_id| @bugs[bug_id] }.each(&)
    end

    def any_for_bug?(bug_or_bug_id)
      key =
        case bug_or_bug_id
        when Integer
          bug_or_bug_id.to_s
        when RunBugRun::Bug
          bug_or_bug_id.id.to_s
        else
          raise ArgumentError, 'must pass bug or bug id'
        end

      @results_hash[key]&.any?
    end

    def plausible_count
      if @only_plausible
        size
      else
        @results_hash.count do |bug_id, candidate_results|
          bug = @bugs[bug_id]
          test_count = tests[bug.problem_id].size
          candidate_results.any? do |candidate_test_runs|
            passed_count = candidate_test_runs.count { _1.fetch('result') == 'pass' }
            passed_count == test_count
          end
        end
      end
    end

    def where_any_plausible_candidate
      if @only_plausible
        dup
      else
        filtered_results_hash = @results_hash.select do |bug_id, candidate_results|
          bug = @bugs[bug_id]
          test_count = tests[bug.problem_id].size
          candidate_results.any? do |candidate_test_runs|
            passed_count = candidate_test_runs.count { _1.fetch('result') == 'pass' }
            passed_count == test_count
          end
        end

        self.class.new(filtered_results_hash, @bugs, @tests, only_plausible: false)
      end
    end

    private

    def wrap_values(groups_hash)
      groups_hash.transform_values do |group_results_hash|
        self.class.new(group_results_hash, @bugs, @tests, only_plausible:)
      end
    end

    EMPTY = new({}, nil, nil, only_plausible: false)
  end
end

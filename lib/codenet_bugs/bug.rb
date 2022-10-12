module CodenetBugs
  class Bug
    attr_reader :id, :language, :problem_id, :user_id, :source_submission,
                :target_submission, :candidate_submissions, :labels
    attr_writer :candidate_submissions

    def initialize(id:, language:, problem_id:, user_id:, labels:, source_submission:, target_submission:)
      @id = id
      @language = language
      @problem_id = problem_id
      @user_id = user_id
      @labels = labels
      @source_submission = source_submission
      @target_submission = target_submission
    end

    def diff(before_name, after_name)
      require 'diffy'

      before = submission_by_name before_name
      after = submission_by_name after_name
      Diffy::Diff.new(before.content, after.content).to_s(:color)
    end

    private
    def submission_by_name(name)
      case name
      when :source
        source_submission
      when :target
        target_submission
      when Integer
        candidate_submissions[name]
      else
        nil
      end
    end
  end
end
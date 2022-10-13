module CodenetBugs
  class Submission

    FILENAME_EXTS = {
      c: 'c',
      cpp: 'cpp',
      javascript: 'js',
      java: 'java',
      ruby: 'rb',
      python: 'py',
      php: 'php',
      go: 'go'
    }.freeze

    attr_reader :id, :content, :problem_id, :language, :main_class, :accepted

    def initialize(id:, content:, problem_id:, language:, main_class:, accepted:)
      @id = id
      @content = content
      @problem_id = problem_id
      @language = language.to_sym
      @main_class = main_class
      @accepted = accepted
    end

    def self.from_hash(hash)
      new(**hash.transform_keys(&:to_sym))
    end

    def to_h
      {id:, content:, problem_id:, language:, main_class:, accepted:}
    end

    def accepted? = @accepted
    def filename_ext = FILENAME_EXTS.fetch language
  end
end
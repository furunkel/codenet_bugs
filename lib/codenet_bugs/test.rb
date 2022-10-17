module CodenetBugs
  class Test
    attr_reader :id, :input, :output

    def initialize(id:, input:, output:)
      @id = id
      @input = input
      @output = output
    end

    def self.from_hash(hash)
      new(**hash)
    end

    def to_h
      {id:, input:, output:}
    end
  end
end
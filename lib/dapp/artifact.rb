module Dapp
  # Artifact
  class Artifact < Dimg
    def stage_should_be_introspected?(name)
      project.cli_options[:introspect_artifact_stage] == name
    end

    def artifact?
      true
    end

    def should_be_built?
      false
    end

    protected

    def last_stage
      @last_stage ||= Build::Stage::BuildArtifact.new(self)
    end
  end # Artifact
end # Dapp

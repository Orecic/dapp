module Dapp
  module Dimg
    class Dapp
      module Command
        module Run
          def run(docker_options, command)
            one_dimg!
            Dimg.new(config: build_configs.first, dapp: self, ignore_git_fetch: true, should_be_built: true).run(docker_options, command)
          end
        end
      end
    end
  end # Dimg
end # Dapp

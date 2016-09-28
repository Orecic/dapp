module Dapp
  module Builder
    # Chef
    class Chef < Base
      CHEFDK_VERSION = '0.17.3-2'

      LOCAL_COOKBOOK_CHECKSUM_PATTERNS = %w(
        attributes/**/*
        recipes/**/*
        files/**/*
        templates/**/*
      ).freeze

      %i(before_install install before_setup setup build_artifact).each do |stage|
        define_method("#{stage}_checksum") do
          application.hashsum [stage_cookbooks_checksum(stage),
                               stage_attributes_raw(stage),
                               *stage_cookbooks_runlist(stage)]
        end

        define_method("#{stage}?") { !stage_empty?(stage) }

        define_method(stage.to_s) do |image|
          unless stage_empty?(stage)
            image.add_volumes_from(chefdk_container)
            image.add_volume "#{stage_build_path(stage)}:#{container_stage_build_path(stage)}:ro"
            image.add_command ['/.dapp/deps/chefdk/bin/chef-solo',
                               '--legacy-mode',
                               "--config #{container_stage_config_path(stage)}",
                               "--json-attributes #{container_stage_json_attributes_path(stage)}",
                               "--override-runlist #{stage_cookbooks_runlist(stage).join(',')}"].join(' ')
          end
        end
      end

      def chef_cookbooks_checksum
        stage_cookbooks_checksum(:chef_cookbooks)
      end

      def chef_cookbooks(image)
        image.add_volume "#{cookbooks_vendor_path(chef_cookbooks_stage: true)}:#{application.container_dapp_path('chef_cookbooks')}"
        image.add_command(
          "#{application.project.mkdir_path} -p /usr/share/dapp/chef_repo",
          ["#{application.project.cp_path} -a #{application.container_dapp_path('chef_cookbooks')} ",
           '/usr/share/dapp/chef_repo/cookbooks'].join
        )
      end

      def before_application_should_be_built_check
        super

        %i(before_install install before_setup setup build_artifact chef_cookbooks).each do |stage|
          raise ::Dapp::Error::Application, code: :cookbooks_stage_checksum_not_calculated,
                                            data: { stage: stage } unless stage_cookbooks_checksum_path(stage).exist?
        end
      end

      private

      def enabled_modules
        application.config._chef._modules
      end

      def enabled_recipes
        application.config._chef._recipes
      end

      def stage_attributes(stage)
        application.config._chef.send("_#{stage}_attributes")
      end

      def stage_attributes_raw(stage)
        JSON.dump stage_attributes(stage)
      end

      def project_name
        cookbook_metadata.name
      end

      def berksfile_path
        application.home_path('Berksfile')
      end

      def berksfile_lock_path
        application.home_path('Berksfile.lock')
      end

      def berksfile
        @berksfile ||= Berksfile.new(application.home_path, berksfile_path)
      end

      def cookbook_metadata_path
        application.home_path('metadata.rb')
      end

      def cookbook_metadata
        @cookbook_metadata ||= CookbookMetadata.new(cookbook_metadata_path).tap do |metadata|
          metadata.depends.each do |dependency|
            raise Error, code: :mdapp_dependency_in_metadata_forbidden,
                         data: { dependency: dependency } if dependency.start_with? 'mdapp-'
          end
        end
      end

      def berksfile_lock_checksum
        application.hashsum(berksfile_lock_path.read) if berksfile_lock_path.exist?
      end

      def stage_cookbooks_checksum_path(stage)
        application.build_path.join("#{cookbooks_checksum}.#{stage}.checksum")
      end

      def stage_cookbooks_checksum(stage)
        if stage_cookbooks_checksum_path(stage).exist?
          stage_cookbooks_checksum_path(stage).read.strip
        else
          checksum = if stage == :chef_cookbooks
                       paths = Dir[cookbooks_vendor_path('**/*', chef_cookbooks_stage: true)].map(&Pathname.method(:new))

                       application.hashsum [
                         application.paths_content_hashsum(paths),
                         *paths.map { |p| p.relative_path_from(cookbooks_vendor_path(chef_cookbooks_stage: true)).to_s }.sort
                       ]
                     else
                       paths = Dir[stage_cookbooks_path(stage, '**/*')].map(&Pathname.method(:new))

                       application.hashsum [
                         application.paths_content_hashsum(paths),
                         *paths.map { |p| p.relative_path_from(stage_cookbooks_path(stage)).to_s }.sort,
                         stage == :before_install ? chefdk_image : nil
                       ].compact
                     end

          stage_cookbooks_checksum_path(stage).tap do |path|
            path.parent.mkpath
            path.write "#{checksum}\n"
          end

          checksum
        end
      end

      def cookbooks_checksum
        @cookbooks_checksum ||= begin
          paths = berksfile
                  .local_cookbooks
                  .values
                  .map { |cookbook| cookbook[:path] }
                  .product(LOCAL_COOKBOOK_CHECKSUM_PATTERNS)
                  .map { |cb, dir| Dir[cb.join(dir)] }
                  .flatten
                  .map(&Pathname.method(:new))

          application.hashsum [
            application.paths_content_hashsum(paths),
            *paths.map { |p| p.relative_path_from(berksfile.home_path).to_s }.sort,
            (berksfile_lock_checksum unless application.project.cli_options[:dev]),
            *enabled_recipes,
            *enabled_modules
          ].compact
        end
      end

      def chefdk_image
        "dappdeps/chefdk:#{CHEFDK_VERSION}"
      end

      def chefdk_container_name # FIXME: hashsum(image) or dockersafe()
        "dappdeps_chefdk_#{CHEFDK_VERSION}"
      end

      def chefdk_container
        @chefdk_container ||= begin
          if application.project.shellout("docker inspect #{chefdk_container_name}").exitstatus.nonzero?
            application.project.log_secondary_process(application.project.t(code: 'process.chefdk_container_loading'), short: true) do
              application.project.shellout!(
                ['docker create',
                 "--name #{chefdk_container_name}",
                 "--volume /.dapp/deps/chefdk #{chefdk_image}"].join(' ')
              )
            end
          end

          chefdk_container_name
        end
      end

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def install_cookbooks(dest_path, chef_cookbooks_stage: false)
        volumes_from = [application.project.base_container, chefdk_container]
        process_code = [
          'process',
          chef_cookbooks_stage ? 'chef_cookbooks_stage_berks_vendor' : 'berks_vendor'
        ].compact.join('.')

        application.project.log_secondary_process(application.project.t(code: process_code)) do
          before_vendor_commands = [].tap do |commands|
            unless application.project.cli_options[:dev] || chef_cookbooks_stage
              commands.push(
                ['if [ ! -f Berksfile.lock ] ; then ',
                 "#{application.project.echo_path} \"Berksfile.lock not found\" 1>&2 ; ",
                 'exit 1 ; ',
                 'fi'].join
              )
            end
          end

          after_vendor_commands = [].tap do |commands|
            if application.project.cli_options[:dev]
              commands.push(
                ["#{application.project.install_path} -o #{Process.uid} -g #{Process.gid} ",
                 "--mode $(#{application.project.stat_path} -c %a Berksfile.lock) ",
                 "Berksfile.lock #{berksfile_lock_path}"].join
              )
            elsif !chef_cookbooks_stage
              commands.push(
                "export LOCKDIFF=$(#{application.project.diff_path} -u1 Berksfile.lock #{berksfile_lock_path})",
                ['if [ "$LOCKDIFF" != "" ] ; then ',
                 "#{application.project.echo_path} -e \"Bad Berksfile.lock\n$LOCKDIFF\" 1>&2 ; ",
                 'exit 1 ; ',
                 'fi'].join
              )
            end
          end

          vendor_commands = [
            "#{application.project.mkdir_path} -p ~/.ssh",
            "#{application.project.echo_path} \"Host *\" >> ~/.ssh/config",
            "#{application.project.echo_path} \"    StrictHostKeyChecking no\" >> ~/.ssh/config",
            *berksfile.local_cookbooks
                      .values
                      .map { |cookbook| "#{application.project.rsync_path} --archive --relative #{cookbook[:path]} /tmp/local_cookbooks" },
            "cd /tmp/local_cookbooks/#{berksfile_path.parent}",
            *before_vendor_commands,
            '/.dapp/deps/chefdk/bin/berks vendor /tmp/cookbooks',
            *after_vendor_commands,
            ["#{application.project.find_path} /tmp/cookbooks -type d -exec #{application.project.bash_path} -ec '",
             "#{application.project.install_path} -o #{Process.uid} -g #{Process.gid} --mode $(#{application.project.stat_path} -c %a {}) -d ",
             "#{dest_path}/$(#{application.project.echo_path} {} | #{application.project.sed_path} -e \"s/^\\/tmp\\/cookbooks//\")' \\;"].join,
            ["#{application.project.find_path} /tmp/cookbooks -type f -exec #{application.project.bash_path} -ec '",
             "#{application.project.install_path} -o #{Process.uid} -g #{Process.gid} --mode $(#{application.project.stat_path} -c %a {}) {} ",
             "#{dest_path}/$(#{application.project.echo_path} {} | #{application.project.sed_path} -e \"s/\\/tmp\\/cookbooks//\")' \\;"].join,
            "#{application.project.install_path} -o #{Process.uid} -g #{Process.gid} --mode 0644 <(#{application.project.date_path} +%s.%N) #{dest_path.join('.created_at')}"
          ]

          application.project.shellout!(
            ['docker run --rm',
             volumes_from.map { |container| "--volumes-from #{container}" }.join(' '),
             *berksfile.local_cookbooks
                       .values
                       .map { |cookbook| "--volume #{cookbook[:path]}:#{cookbook[:path]}" },
             ("--volume #{application.project.ssh_auth_sock}:#{application.project.ssh_auth_sock}" if application.project.ssh_auth_sock),
             "--volume #{dest_path.tap(&:mkpath)}:#{dest_path}",
             ("--env SSH_AUTH_SOCK=#{application.project.ssh_auth_sock}" if application.project.ssh_auth_sock),
             ('--env DAPP_CHEF_COOKBOOKS_VENDORING=1' if chef_cookbooks_stage),
             "dappdeps/berksdeps:0.1.0 #{application.project.bash_path} -ec '#{application.project.shellout_pack(vendor_commands.join(' && '))}'"].compact.join(' '),
             log_verbose: application.project.log_verbose?
          )
        end
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def _cookbooks_vendor_path(chef_cookbooks_stage: false)
        application.build_path.join(
          ['cookbooks', chef_cookbooks_stage ? 'chef_cookbooks_stage' : nil].compact.join('.'),
          cookbooks_checksum
        )
      end

      def cookbooks_vendor_path(*path, chef_cookbooks_stage: false)
        _cookbooks_vendor_path(chef_cookbooks_stage: chef_cookbooks_stage).tap do |_cookbooks_path|
          lock_name = [
            application.config._basename,
            'cookbooks',
            chef_cookbooks_stage ? 'chef_cookbooks_stage' : nil,
            cookbooks_checksum
          ].compact.join('.')

          application.project.lock(lock_name, default_timeout: 120) do
            @install_cookbooks ||= {}
            @install_cookbooks[chef_cookbooks_stage] ||= begin
              install_cookbooks(_cookbooks_path, chef_cookbooks_stage: chef_cookbooks_stage) unless _cookbooks_path.join('.created_at').exist? && !application.project.cli_options[:dev]
              true
            end
          end
        end.join(*path)
      end

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def install_stage_cookbooks(stage)
        select_existing_paths = proc do |cookbook_path, paths|
          paths.select { |from, _| cookbook_path.join(from).exist? }
        end

        common_paths = [['metadata.json', 'metadata.json']]

        install_paths = Dir[cookbooks_vendor_path('*')]
                        .map(&Pathname.method(:new))
                        .map do |cookbook_path|
          cookbook_name = File.basename cookbook_path
          is_project = (cookbook_name == project_name)
          is_mdapp = cookbook_name.start_with? 'mdapp-'
          mdapp_name = (is_mdapp ? cookbook_name.split('mdapp-')[1] : nil)
          mdapp_enabled = is_mdapp && enabled_modules.include?(mdapp_name)

          paths = if is_project
                    common_dapp_paths = select_existing_paths.call(cookbook_path, [
                                                                     *common_paths,
                                                                     ["files/#{stage}/common", 'files/default'],
                                                                     ["templates/#{stage}/common", 'templates/default'],
                                                                     *enabled_recipes.flat_map do |recipe|
                                                                       [["files/#{stage}/#{recipe}", 'files/default'],
                                                                        ["templates/#{stage}/#{recipe}", 'templates/default']]
                                                                     end
                                                                   ])

                    recipe_paths = enabled_recipes.map { |recipe| ["recipes/#{stage}/#{recipe}.rb", "recipes/#{recipe}.rb"] }
                                                  .select { |from, _| cookbook_path.join(from).exist? }
                    if recipe_paths.any?
                      [*recipe_paths, *common_dapp_paths]
                    else
                      [nil, *common_dapp_paths]
                    end
                  elsif is_mdapp && mdapp_enabled
                    common_mdapp_paths = select_existing_paths.call(cookbook_path, [
                                                                      *common_paths,
                                                                      ["files/#{stage}", 'files/default'],
                                                                      ['files/common', 'files/default'],
                                                                      ["templates/#{stage}", 'templates/default'],
                                                                      ['templates/common', 'templates/default']
                                                                    ])

                    recipe_path = "recipes/#{stage}.rb"
                    if cookbook_path.join(recipe_path).exist?
                      [[recipe_path, recipe_path], *common_mdapp_paths]
                    else
                      [nil, *common_mdapp_paths]
                    end
                  elsif !is_mdapp
                    [['.', '.']]
                  end

          [cookbook_path, paths] if paths && paths.any?
        end.compact

        _stage_cookbooks_path(stage).mkpath
        install_paths.each do |cookbook_path, paths|
          cookbook = cookbook_path.basename.to_s

          paths.each do |from, to|
            if from.nil?
              to_path = _stage_cookbooks_path(stage).join(cookbook, 'recipes/void.rb')
              to_path.parent.mkpath
              FileUtils.touch to_path
            else
              from_path = cookbook_path.join(from)
              to_path = _stage_cookbooks_path(stage).join(cookbook, to)
              if from_path.directory? && to_path.exist?
                Dir[from_path.join('**/*')]
                  .map(&Pathname.method(:new))
                  .each do |from_subpath|
                    to_subpath = to_path.join(from_subpath.relative_path_from(from_path))
                    raise Error, code: :stage_path_overlap,
                                 data: { stage: stage,
                                         cookbook: cookbook,
                                         from: from_subpath.relative_path_from(cookbook_path),
                                         to: to_subpath.relative_path_from(_stage_cookbooks_path(stage).join(cookbook)) } if to_subpath.exist?

                    to_subpath.parent.mkpath
                    FileUtils.cp_r from_subpath, to_subpath
                  end
              else
                to_path.parent.mkpath
                FileUtils.cp_r from_path, to_path
              end
            end
          end
        end
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      # rubocop:disable Metrics/AbcSize
      def stage_cookbooks_runlist(stage)
        @stage_cookbooks_runlist ||= {}
        @stage_cookbooks_runlist[stage] ||= begin
          res = []

          does_entry_exist = proc do |cookbook, entrypoint|
            stage_cookbooks_path(stage, cookbook, 'recipes', "#{entrypoint}.rb").exist?
          end

          format_entry = proc do |cookbook, entrypoint|
            entrypoint = 'void' if entrypoint.nil?
            "#{cookbook}::#{entrypoint}"
          end

          enabled_modules.map do |mod|
            cookbook = "mdapp-#{mod}"
            if does_entry_exist[cookbook, stage]
              [cookbook, stage]
            else
              [cookbook, nil]
            end
          end.tap { |entries| res.concat entries }

          enabled_recipes.map { |recipe| [project_name, recipe] }
                         .select { |entry| does_entry_exist[*entry] }
                         .tap do |entries|
            if entries.any?
              res.concat entries
            else
              res << [project_name, nil]
            end
          end

          if res.all? { |_, entrypoint| entrypoint.nil? }
            []
          else
            res.map(&format_entry)
          end
        end
      end
      # rubocop:enable Metrics/AbcSize

      def stage_empty?(stage)
        stage_cookbooks_runlist(stage).empty?
      end

      def _stage_cookbooks_path(stage)
        stage_build_path(stage, 'cookbooks')
      end

      def stage_cookbooks_path(stage, *path)
        _stage_cookbooks_path(stage).tap do |_cookbooks_path|
          @install_stage_cookbooks ||= {}
          @install_stage_cookbooks[stage] ||= true.tap { install_stage_cookbooks(stage) }
        end.join(*path)
      end

      def install_chef_solo_stage_config(stage)
        @install_chef_solo_stage_config ||= {}
        @install_chef_solo_stage_config[stage] ||= true.tap do
          stage_build_path(stage, 'config.rb').write [
            "file_cache_path \"/.dapp/chef/cache\"\n",
            "cookbook_path \"#{container_stage_build_path(stage, 'cookbooks')}\"\n"
          ].join
        end
      end

      def container_stage_config_path(stage, *path)
        install_chef_solo_stage_config(stage)
        container_stage_build_path(stage, 'config.rb', *path)
      end

      def install_json_attributes(stage)
        @install_json_attributes ||= {}
        @install_json_attributes[stage] ||= true.tap do
          stage_build_path(stage, 'attributes.json').write "#{stage_attributes_raw(stage)}\n"
        end
      end

      def container_stage_json_attributes_path(stage, *path)
        install_json_attributes(stage)
        container_stage_build_path(stage, 'attributes.json', *path)
      end

      def stage_build_path(stage, *path)
        application.tmp_path(application.config._name, stage).join(*path)
      end

      def container_stage_build_path(_stage, *path)
        path.compact.map(&:to_s).inject(Pathname.new('/.dapp/chef/build'), &:+)
      end
    end
  end
end

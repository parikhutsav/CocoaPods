module Pod
  class Installer
    class PodsProjectGenerator

      # Controller class responsible of creating and configuring the static
      # target target in Pods project. It also creates the support file needed
      # by the target.
      #
      class TargetInstaller

        # @return [Sandbox] sandbox the sandbox where the support files should
        #         be generated.
        #
        attr_reader :sandbox

        # @return [target] The target whose target needs to be generated.
        #
        attr_reader :target

        # @param  [Project] project @see project
        # @param  [target] target @see target
        #
        def initialize(sandbox, target)
          @sandbox = sandbox
          @target = target
        end


        private

        # @!group Installation steps
        #---------------------------------------------------------------------#

        # Adds the target for the target to the Pods project with the
        # appropriate build configurations.
        #
        # @note   The `PODS_HEADERS_SEARCH_PATHS` overrides the xcconfig.
        #
        # @return [void]
        #
        def add_target
          name = target.label
          platform = target.platform.name
          deployment_target = target.platform.deployment_target.to_s
          @native_target = project.new_target(:static_target, name, platform, deployment_target)

          settings = {}
          if target.platform.requires_legacy_ios_archs?
            settings['ARCHS'] = "armv6 armv7"
          end

          @native_target.build_settings('Debug').merge!(settings)
          @native_target.build_settings('Release').merge!(settings)

          target.user_build_configurations.each do |bc_name, type|
            @native_target.add_build_configuration(bc_name, type)
          end

          target.target = @native_target
        end



        # @return [PBXNativeTarget] the target generated by the installation
        #         process.
        #
        # @note   Generated by the {#add_target} step.
        #
        # TODO Remove
        #
        attr_reader :native_target


        private

        # @!group Private helpers.
        #---------------------------------------------------------------------#

        # @return [Project] the Pods project of the sandbox.
        #
        def project
          sandbox.project
        end

        #-----------------------------------------------------------------------#

      end
    end
  end
end


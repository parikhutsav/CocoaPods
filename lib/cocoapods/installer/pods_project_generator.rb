module Pod
  class Installer

    # Generates the Pods project according to the targets identified by the
    # analyzer.
    #
    class PodsProjectGenerator

      autoload :AggregateTargetInstaller, 'cocoapods/installer/pods_project_generator/target_installer/aggregate_target_installer'
      autoload :FileReferencesInstaller,  'cocoapods/installer/pods_project_generator/file_references_installer'
      autoload :PodTargetInstaller,       'cocoapods/installer/pods_project_generator/target_installer/pod_target_installer'
      autoload :SupportFilesGenerator,    'cocoapods/installer/pods_project_generator/support_files_generator'
      autoload :TargetInstaller,          'cocoapods/installer/pods_project_generator/target_installer'

      # @return [Sandbox] The sandbox of the installation.
      #
      attr_reader :sandbox

      # @return [Array<AggregateTarget>] The aggregate targets of the
      #         installation.
      #
      attr_reader :aggregate_targets

      # @param  [Sandbox] sandbox @see sandbox
      # @param  [Array<AggregateTarget>] aggregate_targets @see aggregate_targets
      #
      def initialize(sandbox, aggregate_targets)
        @sandbox = sandbox
        @aggregate_targets = aggregate_targets
        @user_build_configurations = []
      end

      # @return [Array] The path of the Podfile.
      #
      attr_accessor :podfile_path

      # @return [Hash] The name and the type of the build configurations of the
      #         user.
      #
      attr_accessor :user_build_configurations

      # Generates the Pods project.
      #
      # @return [void]
      #
      def install
        prepare_project
        sync_pod_targets
        sync_aggregate_targets
        sync_target_dependencies
        sync_aggregate_targets_libraries
      end

      # @return [Project] the generated Pods project.
      #
      attr_reader :project

      # Writes the Pods project to the disk.
      #
      # @return [void]
      #
      def write_project
        UI.message "- Writing Xcode project file" do
          project.prepare_for_serialization
          project.save
        end
      end


      private

      # @!group Installation steps
      #-----------------------------------------------------------------------#

      # Creates the Pods project from scratch.
      #
      # @return [void]
      #
      def prepare_project
        if should_create_new_project?
          UI.message"- Initializing new project" do
            @project = Pod::Project.new(sandbox.project_path)
            @new_project = true
          end
        else
          UI.message"- Opening existing project" do
            @project = Pod::Project.open(sandbox.project_path)
            detect_native_targets
          end
        end

        project.set_podfile(podfile_path)
        setup_build_configurations
        sandbox.project = project
      end

      # Matches the native targets of the Pods project with the targets
      # generated by the analyzer.
      #
      # @return [void]
      #
      def detect_native_targets
        UI.message"- Matching targets" do
          p native_targets_by_name = project.targets.group_by(&:name)
          p cp_targets = aggregate_targets + all_pod_targets
          cp_targets.each do |pod_target|
            native_targets = native_targets_by_name[pod_target.label]
            if native_targets
              pod_target.target = native_targets.first
            end
          end
        end
      end

      # @return [void]
      #
      def sync_pod_targets
        pods_to_remove.each do |name|
          remove_pod(name)
        end

        pods_to_install.each do |name|
          add_pod(name)
        end
      end

      # Adds and removes aggregate targets to the
      #
      # @return [void]
      #
      def sync_aggregate_targets
        targets_to_remove = []

        targets_to_install.each do |target|
          add_aggregate_target(target)
        end

        targets_to_remove.each do |target|
          remove_aggregate_target(target)
        end

        aggregate_targets.each do |target|
          # TODO: increment support files generation
          # support_group = project.support_files_group[target.name]
          # support_group.remove_from_project if support_group
          unless target.target_definition.empty?
            gen = SupportFilesGenerator.new(target, sandbox.project)
            gen.generate!
          end
        end

        # TODO: clean up dependencies and linking
        # TODO: clean removed targets and their support files
        # TODO: Fix sorting of targets
        # TODO: clean stray and unrecognized targets
        # TODO: skip empty aggregate targets
        # TODO: Install aggregate targets first
        # TODO: sort targets by name before serialization in the project
        # TODO: Add integration checks (adding an aggregate target, removing
        #       one, performing an installation without a project)
      end


      #
      #
      def add_aggregate_target(target)
        UI.message"- Installing `#{target.label}`" do
          # TODO: the support files should be created from scratch in any case
          AggregateTargetInstaller.new(sandbox, target).install!
        end
      end

      #
      #
      def remove_aggregate_target(target)
        UI.message"- Removing `#{target.label}`" do
          target.remove_from_project
          target.product_reference.remove_from_project
          project.support_files_group[target.name].remove_from_project
        end
      end

      #
      #
      def add_pod(name)
        UI.message"- Installing `#{name}`" do
          pod_targets = all_pod_targets.select { |target| target.pod_name == name }

          UI.message"- Installing file references" do
            path = sandbox.pod_dir(name)
            local = sandbox.local?(name)
            project.add_pod_group(name, path, local)

            FileReferencesInstaller.new(sandbox, pod_targets).install!
          end

          pod_targets.each do |pod_target|
            UI.message"- Installing targets" do
              PodTargetInstaller.new(sandbox, pod_target).install!
              gen = SupportFilesGenerator.new(pod_target, sandbox.project)
              gen.generate!
            end
          end
        end
      end

      #
      #
      def remove_pod(name)
        UI.message"- Removing `#{name}`" do
          products_group = project.group_for_spec(name, :products)

          UI.message"- Removing targets" do
          targets = project.targets.select { |target| products_group.children.include?(target.product_reference) }
          targets.each do |target|
            target.referrers.each do |ref|
              if ref.isa == 'PBXTargetDependency'
                ref.remove_from_project
              end
            end
            target.remove_from_project
          end
          end

          UI.message"- Removing file references" do
            group = project.pod_group(name)
            group.remove_from_project
          end
        end
      end

      # Sets the dependencies of the targets.
      #
      # @return [void]
      #
      def sync_target_dependencies
        UI.message"- Setting-up dependencies" do
          aggregate_targets.each do |aggregate_target|
            aggregate_target.pod_targets.each do |dep|
              if dep.target
                aggregate_target.target.add_dependency(dep.target)
              else
                puts "[BUG] #{dep}"
              end
            end
          end

          aggregate_targets.each do |aggregate_target|
            aggregate_target.pod_targets.each do |pod_target|
              dependencies = pod_target.dependencies.map { |dep_name| aggregate_target.pod_targets.find { |target| target.pod_name == dep_name } }
              dependencies.each do |dep|
                pod_target.target.add_dependency(dep.target)
              end
            end
          end
        end
      end

      # Links the aggregate targets with all the dependent pod targets.
      #
      # @return [void]
      #
      def sync_aggregate_targets_libraries
        UI.message"- Populating aggregate targets" do
          aggregate_targets.each do |aggregate_target|
            native_target = aggregate_target.target
            aggregate_target.pod_targets.each do |pod_target|
              product = pod_target.target.product_reference
              unless native_target.frameworks_build_phase.files_references.include?(product)
                native_target.frameworks_build_phase.add_file_reference(product)
              end
            end
          end
        end
      end


      private

      # @!group Private Helpers
      #-----------------------------------------------------------------------#

      #
      #
      def should_create_new_project?
        # TODO
        incompatible = false
        incompatible || !sandbox.project_path.exist?
      end

      #
      #
      attr_accessor :new_project
      alias_method  :new_project?, :new_project

      # @return [Array<PodTarget>] The pod targets generated by the installation
      #         process.
      #
      def all_pod_targets
        aggregate_targets.map(&:pod_targets).flatten
      end

      #
      #
      def pods_to_install
        if new_project
          all_pod_targets.map(&:pod_name).uniq.sort
        else
          # TODO: Add missing groups
          missing_target = all_pod_targets.select { |pod_target| pod_target.target.nil? }.map(&:pod_name).uniq
          @pods_to_install ||= (sandbox.state.added | sandbox.state.changed | missing_target).uniq.sort
        end
      end

      #
      #
      def pods_to_remove
        return [] if new_project
        # TODO: Superfluous groups
        @pods_to_remove ||= (sandbox.state.deleted | sandbox.state.changed).sort
      end

      def targets_to_install
        aggregate_targets.sort_by(&:name).select do |target|
          empty = target.target_definition.empty?
          if new_project
            !empty
          else
            missing = target.target.nil?
            missing && !empty
          end
        end
      end

      # Sets the build configuration of the Pods project according the build
      # configurations of the user as detected by the analyzer and other
      # default values.
      #
      # @return [void]
      #
      def setup_build_configurations
        user_build_configurations.each do |name, type|
          project.add_build_configuration(name, type)
        end

        platforms = aggregate_targets.map(&:platform)
        osx_deployment_target = platforms.select { |p| p.name == :osx }.map(&:deployment_target).min
        ios_deployment_target = platforms.select { |p| p.name == :ios }.map(&:deployment_target).min
        project.build_configurations.each do |build_configuration|
          build_configuration.build_settings['MACOSX_DEPLOYMENT_TARGET'] = osx_deployment_target.to_s if osx_deployment_target
          build_configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = ios_deployment_target.to_s if ios_deployment_target
          build_configuration.build_settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
        end
      end

      #-----------------------------------------------------------------------#

    end
  end
end

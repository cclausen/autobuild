module Autobuild
    def self.orogen(opts, &proc)
        Orogen.new(opts, &proc)
    end

    # This class represents packages generated by orogen. oroGen is a
    # specification and code generation tool for the Orocos/RTT integration
    # framework. See http://rock-robotics.org for more information.
    #
    # This class extends the CMake package class to handle the code generation
    # step. Moreover, it will load the orogen specification and automatically
    # add the relevant pkg-config dependencies as dependencies.
    #
    # This requires that the relevant packages define the pkg-config definitions
    # they install in the pkgconfig/ namespace. It means that a "driver/camera"
    # package (for instance) that installs a "camera.pc" file will have to
    # provide the "pkgconfig/camera" virtual package. This is done automatically
    # by the CMake package handler if the source contains a camera.pc.in file,
    # but can also be done manually with a call to Package#provides:
    #
    #   pkg.provides "pkgconfig/camera"
    #
    class Orogen < CMake
        class << self
            attr_accessor :corba

            # If set to true, all components are generated with the
            # --extended-states option
            #
            # The default is false
            attr_accessor :extended_states

            # See #always_regenerate?
            attr_writer :always_regenerate

            # If true (the default), the oroGen component will be regenerated
            # every time a dependency is newer than the package itself.
            #
            # Otherwise, autobuild tries to regenerate it only when needed
            #
            # This is still considered experimental. Use
            # Orogen.always_regenerate= to set it
            def always_regenerate?
                !!@always_regenerate
            end
        end

        @always_regenerate = true

        @orocos_target = nil

        # The target that should be used to generate and build orogen components
        def self.orocos_target
            user_target = ENV['OROCOS_TARGET']
            if @orocos_target
                @orocos_target.dup
            elsif user_target && !user_target.empty?
                user_target
            else
                'gnulinux'
            end
        end

        class << self
            attr_accessor :default_type_export_policy
            # The list of enabled transports as an array of strings (default: typelib, corba)
            attr_reader :transports

            attr_reader :orogen_options
        end
        @orogen_options = []
        @default_type_export_policy = :used
        @transports = %w{corba typelib mqueue}
        @rtt_scripting = true

        attr_reader :orogen_options

        # Path to the orogen tool
        def self.orogen_bin(full_path = false)
            if @orogen_bin
                @orogen_bin
            else
                program_name = Autobuild.tool('orogen')
                if orogen_path = ENV['PATH'].split(':').find { |p| File.file?(File.join(p, program_name)) }
                    @orogen_bin = File.join(orogen_path, program_name)
                elsif !full_path
                    program_name
                end
            end
        end

        # Path to the root of the orogen package
        def self.orogen_root
            if @orogen_root
                @orogen_root
            elsif orogen_bin = self.orogen_bin(true)
                @orogen_root = File.expand_path('../lib', File.dirname(@orogen_bin))
            end
        end

        # The version of orogen, given as a string
        #
        # It is used to enable/disable some configuration features based on the
        # orogen version string
        def self.orogen_version
            if !@orogen_version && root = orogen_root
                version_file = File.join(root, 'orogen', 'version.rb')
                version_line = File.readlines(version_file).grep(/VERSION\s*=\s*"/).first
                if version_line =~ /.*=\s+"(.+)"$/
                    @orogen_version = $1
                end
            end
            @orogen_version
        end

        # Overrides the global Orocos.orocos_target for this particular package
        attr_writer :orocos_target

        # The orocos target that should be used for this particular orogen
        # package
        #
        # By default, it is the same than Orogen.orocos_target. It can be set by
        # doing
        #
        #   package.orocos_target = 'target_name'
        def orocos_target
            if @orocos_target.nil?
                Orogen.orocos_target
            else
                @orocos_target
            end
        end

        attr_writer :corba
        def corba
            @corba || (@corba.nil? && Orogen.corba)
        end

        # Overrides the global Orocos.extended_states for this particular package
        attr_writer :extended_states
        def extended_states
            @extended_states || (@extended_states.nil? && Orogen.extended_states)
        end

        attr_writer :orogen_file

        # Path to the orogen file used for this package
        #
        # If not set, the class will look for a .orogen file in the package
        # source directory. It will return nil if the package is not checked out
        # yet, and raise ArgumentError if the package is indeed present but no
        # orogen file can be found
        #
        # It can be explicitely set with #orogen_file=
        def orogen_file
            if @orogen_file
                @orogen_file
            else
                return if !File.directory?(srcdir)
                    
                Dir.glob(File.join(srcdir, '*.orogen')) do |path|
                    return File.basename(path)
                end
                raise ArgumentError, "cannot find an oroGen specification file in #{srcdir}"
            end
        end

        def initialize(*args, &config)
            super

            @orocos_target = nil
            @orogen_options = []
        end

        def prepare_for_forced_build
            super
            FileUtils.rm_f genstamp 
        end

        def import(only_local=false)
            super
        end

        def update_environment
            super
            typelib_plugin = File.join(prefix, 'share', 'typelib', 'ruby')
            if File.directory?(typelib_plugin)
                Autobuild.env_add_path 'TYPELIB_RUBY_PLUGIN_PATH', typelib_plugin
            end
            roby_plugin = File.join(prefix, 'share', 'orocos', 'roby')
            if File.directory?(roby_plugin)
                Autobuild.env_add_path 'OROCOS_ROBY_PLUGIN_PATH',  roby_plugin
            end
        end

        def prepare
            # Check if someone provides the pkgconfig/orocos-rtt-TARGET package,
            # and if so add it into our dependency list
            if rtt = Autobuild::Package["pkgconfig/orocos-rtt-#{orocos_target}"]
                if Autobuild.verbose
                    message "orogen: found #{rtt.name} which provides the RTT"
                end
                depends_on rtt.name
            end

            # Find out where orogen is, and make sure the configurestamp depend
            # on it. Ignore if orogen is too old to have a --base-dir option
            if orogen_root = self.class.orogen_root
                orogen_tree = source_tree(orogen_root)
            end

            # Check if there is an orogen package registered. If it is the case,
            # simply depend on it. Otherwise, look out for orogen --base-dir
            if Autobuild::Package['orogen']
                depends_on "orogen"
            elsif orogen_tree
                file genstamp => orogen_tree
            end

            file configurestamp => genstamp

            # Cache the orogen file name
            @orogen_file ||= self.orogen_file

            file genstamp => source_tree(srcdir) do
                needs_regen = true
                if File.file?(genstamp)
                    genstamp_mtime = File.stat(genstamp).mtime
                    dependency_updated = dependencies.any? do |dep|
                        !File.file?(Package[dep].installstamp) ||
                            File.stat(Package[dep].installstamp).mtime > genstamp_mtime
                    end
                    needs_regen = dependency_updated || !generation_uptodate?
                end

                if needs_regen
                    isolate_errors { regen }
                end
            end

            with_doc

            super

            dependencies.each do |p|
                file genstamp => Package[p].installstamp
            end
        end
        def genstamp; File.join(srcdir, '.orogen', 'orogen-stamp') end

        def guess_ruby_name
            if Autobuild.programs['ruby']
                Autobuild.tool('ruby')
            else
                ruby_bin = RbConfig::CONFIG['RUBY_INSTALL_NAME']
                Autobuild.programs['ruby'] = ruby_bin
            end
        end

        def add_cmd_to_cmdline(cmd, cmdline)
            base = nil

            if cmd =~ /^([\w-]+)/
                cmd_filter = $1
            else
                raise ArgumentError, "cannot parse the provided command #{cmd}"
            end

            cmdline.delete_if { |str| str =~ /^#{cmd_filter}/ }
            if cmd_filter =~ /^--no-(.*)/
                cmd_filter = $1
                cmdline.delete_if { |str| str =~ /^--#{cmd_filter}/ }
            end
            cmdline << cmd
        end

        def regen
            cmdline = []
            cmdline << '--corba' if corba

            ext_states = extended_states
            if !ext_states.nil?
                cmdline.delete_if { |str| str =~ /extended-states/ }
                if ext_states
                    cmdline << '--extended-states'
                else
                    cmdline << '--no-extended-states'
                end
            end

            if (version = Orogen.orogen_version)
                if version >= "1.0"
                    cmdline << "--parallel-build=#{parallel_build_level}"
                end
                if version >= "1.1"
                    cmdline << "--type-export-policy=#{Orogen.default_type_export_policy}"
                    cmdline << "--transports=#{Orogen.transports.sort.uniq.join(",")}"
                end
            end

            # Now, add raw options
            #
            # The raw options take precedence
            Orogen.orogen_options.each do |cmd|
                add_cmd_to_cmdline(cmd, cmdline)
            end
            orogen_options.each do |cmd|
                add_cmd_to_cmdline(cmd, cmdline)
            end

            cmdline = cmdline.sort
            cmdline << orogen_file

            needs_regen = Autobuild::Orogen.always_regenerate?

            # Try to avoid unnecessary regeneration as generation can be pretty
            # long
            #
            # First, check if the command line changed
            needs_regen ||=
                if File.exist?(genstamp)
                    last_cmdline = File.read(genstamp).split("\n")
                    last_cmdline != cmdline
                else
                    true
                end

            # Then, if it has already been built, check what the check-uptodate
            # target says
            needs_regen ||= !generation_uptodate?

            # Finally, verify that orogen itself did not change
            needs_regen ||= (Rake::Task[Orogen.orogen_root].timestamp > Rake::Task[genstamp].timestamp)

            if needs_regen
                progress_start "generating oroGen %s", :done_message => 'generated oroGen %s' do
                    in_dir(srcdir) do
                        Subprocess.run self, 'orogen', guess_ruby_name, self.class.orogen_bin, *cmdline
                        File.open(genstamp, 'w') do |io|
                            io.print cmdline.join("\n")
                        end
                    end
                end
            else
                message "no need to regenerate the oroGen project %s"
                Autobuild.touch_stamp genstamp
            end
        end

	def generation_uptodate?
	    if !File.file?(genstamp)
		true
	    elsif File.file?(File.join(builddir, 'Makefile'))
                system("#{Autobuild.tool('make')} -C #{builddir} check-uptodate > /dev/null 2>&1")
	    else
	        true
	    end
        end
    end
end


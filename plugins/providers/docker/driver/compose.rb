require "json"
require "log4r"

module VagrantPlugins
  module DockerProvider
    class Driver
      class Compose < Driver

        # @return [Integer] Maximum number of seconds to wait for lock
        LOCK_TIMEOUT = 60
        # @return [String] Compose file format version
        COMPOSE_VERSION = "2".freeze

        # @return [Pathname] data directory to store composition
        attr_reader :data_directory
        # @return [Vagrant::Machine]
        attr_reader :machine

        # Create a new driver instance
        #
        # @param [Vagrant::Machine] machine Machine instance for this driver
        def initialize(machine)
          super()
          @machine = machine
          @data_directory = Pathname.new(machine.env.local_data_path).
            join("docker-compose")
          @data_directory.mkpath
          @logger = Log4r::Logger.new("vagrant::docker::driver::compose")
          @compose_lock = Mutex.new
          @logger.debug("Docker compose driver initialize for machine `#{@machine.name}` (`#{@machine.id}`)")
          @logger.debug("Data directory for composition file `#{@data_directory}`")
        end

        def build(dir, **opts, &block)
          name = machine.name.to_s
          @logger.debug("Applying build for `#{name}` using `#{dir}` directory.")
          begin
            update_composition(:apply) do |composition|
              services = composition["services"] ||= {}
              services[name] ||= {}
              services[name]["build"] = {"context" => dir}
              # Extract custom dockerfile location if set
              if opts[:extra_args] && opts[:extra_args].include?("--file")
                services[name]["build"]["dockerfile"] = opts[:extra_args][opts[:extra_args].index("--file") + 1]
              end
              # Extract any build args that can be found
              case opts[:build_args]
              when Array
                if opts[:build_args].include?("--build-arg")
                  idx = 0
                  build_args = {}
                  while(idx < opts[:build_args].size)
                    arg_value = opts[:build_args][idx]
                    idx += 1
                    if arg_value.start_with?("--build-arg")
                      if !arg_value.include?("=")
                        arg_value = opts[:build_args][idx]
                        idx += 1
                      end
                      key, val = arg_value.to_s.split("=", 2).to_s.split("=")
                      build_args[key] = val
                    end
                  end
                end
              when Hash
                services[name]["build"]["args"] = opts[:build_args]
              end
            end
          rescue => error
            @logger.error("Failed to apply build using `#{dir}` directory: #{error.class} - #{error}")
            update_composition do |composition|
              composition["services"].delete(name)
            end
            raise
          end
        end

        def create(params, **opts, &block)
          # NOTE: Use the direct machine name as we don't
          # need to worry about uniqueness with compose
          name    = machine.name.to_s
          image   = params.fetch(:image)
          links   = params.fetch(:links)
          ports   = Array(params[:ports])
          volumes = Array(params[:volumes])
          cmd     = Array(params.fetch(:cmd))
          env     = params.fetch(:env)
          expose  = Array(params[:expose])
          @logger.debug("Creating container `#{name}`")
          begin
            update_composition(:apply) do |composition|
              services = composition["services"] ||= {}
              services[name] ||= {}
              services[name].merge!(
                "image" => image,
                "environment" => env,
                "expose" => expose,
                "ports" => ports,
                "volumes" => volumes,
                "links" => links,
                "command" => cmd
              )
            end
          rescue => error
            @logger.error("Failed to create container `#{name}`: #{error.class} - #{error}")
            update_composition do |composition|
              composition["services"].delete(name)
            end
            raise
          end
          get_container_id(name)
        end

        def rm(cid)
          if created?(cid)
            destroy = false
            synchronized do
              compose_execute("rm", "-f", machine.name.to_s)
              update_composition do |composition|
                if composition["services"] && composition["services"].key?(machine.name.to_s)
                  @logger.info("Removing container `#{machine.name}`")
                  if composition["services"].size > 1
                    composition["services"].delete(machine.name.to_s)
                  else
                    destroy = true
                  end
                end
              end
              if destroy
                @logger.info("No containers remain. Destroying full environment.")
                compose_execute("down", "--volumes", "--rmi", "local")
                @logger.info("Deleting composition path `#{composition_path}`")
                composition_path.delete
              end
            end
          end
        end

        def rmi(*_)
          true
        end

        def created?(cid)
          result = super
          if !result
            composition = get_composition
            if composition["services"] && composition["services"].has_key?(machine.name.to_s)
              result = true
            end
          end
          result
        end

        private

        # Lookup the ID for the container with the given name
        #
        # @param [String] name Name of container
        # @return [String] Container ID
        def get_container_id(name)
          compose_execute("ps", "-q", name).chomp
        end

        # Execute a `docker-compose` command
        def compose_execute(*cmd, **opts)
          synchronized do
            execute("docker-compose", "-f", composition_path.to_s,
              "-p", machine.env.cwd.basename.to_s, *cmd, **opts)
          end
        end

        # Apply any changes made to the composition
        def apply_composition!
          machine.env.lock("compose", retry: true) do
            compose_execute("up", "-d", "--remove-orphans")
          end
        end

        # Update the composition and apply changes if requested
        #
        # @param [Boolean] apply Apply composition changes
        def update_composition(*args)
          synchronized do
            machine.env.lock("compose", retry: true) do
              composition = get_composition
              result = yield composition
              write_composition(composition)
              if args.include?(:apply) || (args.include?(:conditional) && result)
                apply_composition!
              end
            end
          end
        end

        # @return [Hash] current composition contents
        def get_composition
          composition = {"version" => COMPOSE_VERSION.dup}
          if composition_path.exist?
            composition.merge!(
              YAML.load(composition_path.read)
            )
          end
          composition.merge!(machine.provider_config.compose_configuration.dup)
          @logger.debug("Fetched composition with provider configuration applied: #{composition}")
          composition
        end

        # Save the composition
        #
        # @param [Hash] composition New composition
        def write_composition(composition)
          @logger.debug("Saving composition to `#{composition_path}`: #{composition}")
          tmp_file = Tempfile.new("vagrant-docker-compose")
          tmp_file.write(composition.to_yaml)
          tmp_file.close
          synchronized do
            FileUtils.mv(tmp_file.path, composition_path.to_s)
          end
        end

        # @return [Pathname] path to the docker-compose.yml file
        def composition_path
          data_directory.join("docker-compose.yml")
        end

        def synchronized
          if !@compose_lock.owned?
            timeout = LOCK_TIMEOUT.to_f
            until @compose_lock.owned?
              if @compose_lock.try_lock
                if timeout > 0
                  timeout -= sleep(1)
                else
                  raise Errors::ComposeLockTimeoutError
                end
              end
            end
            got_lock = true
          end
          begin
            result = yield
          ensure
            @compose_lock.unlock if got_lock
          end
          result
        end
      end
    end
  end
end

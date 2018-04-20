require 'log4r'
require 'shellwords'

require "vagrant/util/subprocess"

#require 'pry'

module Vagrant
  module Plugin
    module V2
      class Trigger
        # @return [Kernel_V2/Config/Trigger]
        attr_reader :config

        # This class is responsible for setting up basic triggers that were
        # defined inside a Vagrantfile.
        #
        # @param [Object] env Vagrant environment
        # @param [Object] config Trigger configuration
        # @param [Object] machine Active Machine
        def initialize(env, config, machine)
          @env        = env
          @config     = config
          @machine    = machine

          @logger = Log4r::Logger.new("vagrant::trigger::#{self.class.to_s.downcase}")
        end

        # Fires all triggers, if any are defined for the action and guest
        #
        # @param [Symbol] action Vagrant command to fire trigger on
        # @param [Symbol] stage :before or :after
        # @param [String] guest_name The guest that invoked firing the triggers
        def fire_triggers(action, stage, guest_name)
          # get all triggers matching action
          triggers = []
          if stage == :before
            triggers = config.before_triggers.select { |t| t.command == action }
          elsif stage == :after
            triggers = config.after_triggers.select { |t| t.command == action }
          else
            # raise error, stage was not given
            # This is an internal error
            # TODO: Make sure this error exist
            raise Errors::Triggers::NoStageGiven,
              action: action,
              stage: stage,
              guest_name: guest_name
          end

          triggers = filter_triggers(triggers, guest_name)

          unless triggers.empty?
            @logger.info("Firing trigger for action #{action} on guest #{guest_name}")
            # TODO I18N me
            @machine.ui.info("Running triggers #{stage} #{action}...")
            fire(triggers, guest_name)
          end
        end

        protected

        #-------------------------------------------------------------------
        # Internal methods, don't call these.
        #-------------------------------------------------------------------

        # Filters triggers to be fired based on configured restraints
        #
        # @param [Array] triggers An array of triggers to be filtered
        # @param [String] guest_name The name of the current guest
        # @return [Array] The filtered array of triggers
        def filter_triggers(triggers, guest_name)
          # look for only_on trigger constraint and if it doesn't match guest
          # name, throw it away also be sure to preserve order
          filter = triggers.dup

          filter.each do |trigger|
            index = nil
            if !trigger.only_on.nil?
              trigger.only_on.each do |o|
                if o.match?(guest_name)
                  index = triggers.index(trigger)
                end
              end
            end

            if !index.nil?
              @logger.debug("Trigger #{trigger.id} will be ignored for #{guest_name}")
              triggers.delete_at(index)
            end
          end

          return triggers
        end

        # Fires off all triggers in the given array
        #
        # @param [Array] triggers An array of triggers to be fired
        def fire(triggers, guest_name)
          # ensure on_error is respected by exiting or continuing

          triggers.each do |trigger|
            @logger.debug("Running trigger #{trigger.id}...")

            # TODO: I18n me
            if !trigger.name.nil?
              @machine.ui.info("Running trigger: #{trigger.name}...")
            else
              @machine.ui.info("Running trigger...")
            end

            if !trigger.info.nil?
              @logger.debug("Executing trigger info message...")
              self.info(trigger.info)
            end

            if !trigger.warn.nil?
              @logger.debug("Executing trigger warn message...")
              self.warn(trigger.info)
            end

            if !trigger.run.nil?
              @logger.debug("Executing trigger run script...")
              self.run(trigger.run, trigger.on_error)
            end

            if !trigger.run_remote.nil?
              @logger.debug("Executing trigger run_remote script on #{guest_name}...")
              self.run_remote(trigger.run, trigger.on_error, guest_name)
            end
          end
        end

        # Prints the given message at info level for a trigger
        #
        # @param [String] message The string to be printed
        def info(message)
          @machine.ui.info(message)
        end

        # Prints the given message at warn level for a trigger
        #
        # @param [String] message The string to be printed
        def warn(message)
          @machine.ui.warn(message)
        end

        # Runs a script on a guest
        #
        # @param [ShellProvisioner/Config] config A Shell provisioner config
        def run(config, on_error)
          if !config.inline.nil?
            cmd = Shellwords.split(config.inline)
            @machine.ui.info("Running local: Inline script")
          else
            @machine.ui.info("Running local: File script #{config.path}")
          end

          begin
            result = Vagrant::Util::Subprocess.execute(*cmd, :notify => [:stdout, :stderr]) do |type,data|
              case type
              when :stdout
                @machine.ui.info(data)
              when :stderr
                @machine.ui.warn(data)
              end
            end

          rescue Exception => e
            #binding.pry
            if on_error == :halt
              @logger.debug("Trigger run encountered an error. Halting on error...")
              raise e
            else
              @logger.debug("Trigger run encountered an error. Continuing on anyway...")
              @machine.ui.warn("Trigger run failed:")
              @machine.ui.warn(e.message)
            end
          end
        end

        # Runs a script on the host
        #
        # @param [ShellProvisioner/Config] config A Shell provisioner config
        def run_remote(config, on_error, guest_name)
          # make sure guest actually exists, if not, display a WARNING
          #
          # get machine, and run shell provisioner on it
          begin
          rescue Error
            if on_error == :halt
              raise Error
            end
            @logger.debug("Trigger run_remote encountered an error. Continuing on anyway...")
          end
        end
      end
    end
  end
end

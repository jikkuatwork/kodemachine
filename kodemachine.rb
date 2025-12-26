#!/usr/bin/ruby
# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'fileutils'
require 'optparse'

module Kodemachine
  VERSION      = "1.8.0"
  CONFIG_DIR   = File.expand_path("~/.config/kodemachine")
  CONFIG_FILE  = File.join(CONFIG_DIR, "config.json")
  UTM_DOCS     = File.expand_path("~/Library/Containers/com.utmapp.UTM/Data/Documents")

  DEFAULT_CONFIG = {
    'base_image' => 'kodeimage-v0.1.0',
    'ssh_user'   => 'kodeman',
    'prefix'     => 'km-',
    'headless'   => true
  }.freeze

  class VM
    attr_reader :name
    def initialize(name); @name = name; end

    def status
      `utmctl status #{@name} 2>/dev/null`.strip.downcase
    end

    def ip
      output = `utmctl ip-address #{@name} 2>/dev/null`
      output.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)&.[](1)
    end

    def exists?
      `utmctl list 2>/dev/null`.include?(@name)
    end
  end

  class Manager
    def initialize(config); @config = config; end

    def ensure_running(label, gui: false)
      # Prevent "start" or other commands being used as labels
      reserved = %w[list doctor delete attach status]
      abort "❌ '#{label}' is a reserved command." if reserved.include?(label)

      name = "#{@config['prefix']}#{label || SecureRandom.alphanumeric(5).downcase}"
      vm = VM.new(name)

      # 1. Clone if missing
      unless vm.exists?
        puts "🏗️  Cloning #{@config['base_image']} -> #{name}..."
        system("utmctl clone \"#{@config['base_image']}\" --name #{name}")
        sleep 1 # Cool down after disk I/O
      end

      # 2. Start if stopped
      if vm.status.include?('stopped')
        puts "🚀 Starting #{name}..."
        mode = (@config['headless'] && !gui) ? "--detach" : ""
        # Capture and ignore the -10004/-1712 noise
        `utmctl start #{name} #{mode} 2>/dev/null`
        
        # Guard: Verification loop to ensure it's actually moving
        5.times do
          break if vm.status.include?('started')
          sleep 1
        end
      end
      vm
    end
  end

  class CLI
    def self.run(args); new.execute(args); end

    def initialize
      @config  = load_config
      @manager = Manager.new(@config)
      @options = { gui: false }
    end

    def execute(args)
      parser = setup_parser
      parser.parse!(args)

      command = args.shift

      case command
      when "list"   then display_list
      when "doctor" then run_doctor
      when "delete" then @manager.delete(args.shift) # Implement delete logic
      when "status" then display_status(args.shift)
      when "attach" then system("utmctl attach #{@config['prefix']}#{args.shift}")
      when "start"  then spawn(args.shift) # Explicitly handle 'start'
      else
        spawn(command) # Treat as label
      end
    end

    private

    def setup_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: kodemachine [command|label] [options]"
        opts.on("--gui", "Run with window visible") { @options[:gui] = true }
        opts.on("-h", "--help") { puts opts; exit }
      end
    end

    def load_config
      FileUtils.mkdir_p(CONFIG_DIR)
      return DEFAULT_CONFIG unless File.exist?(CONFIG_FILE)
      JSON.parse(File.read(CONFIG_FILE)) rescue DEFAULT_CONFIG
    end

    def spawn(label)
      vm = @manager.ensure_running(label, gui: @options[:gui])
      
      puts "🔍 Negotiating IP (this can take 20-40s)..."
      ip = nil
      30.times do
        ip = vm.ip
        break if ip
        print "."
        $stdout.flush
        sleep 2
      end
      puts ""

      if ip
        puts "✅ Ready: #{ip}"
        # Inject personality
        system("utmctl exec #{vm.name} hostnamectl set-hostname #{vm.name} 2>/dev/null")
        # Final SSH
        exec "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null #{@config['ssh_user']}@#{ip}"
      else
        puts "❌ IP Timeout. Check VM state in UTM or try: kodemachine attach #{label || vm.name}"
      end
    end

    def display_list
      puts "Ephemeral Instances:"
      puts `utmctl list`.split("\n").select { |l| l.include?(@config['prefix']) }
    end
    
    def display_status(label)
      return puts "Provide a label" unless label
      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)
      puts "Name:   #{name}"
      puts "Status: #{vm.status}"
      puts "IP:     #{vm.ip || 'Unknown'}"
    end
  end
end

Kodemachine::CLI.run(ARGV)
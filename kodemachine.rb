#!/usr/bin/ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'optparse'

module Kodemachine
  VERSION      = "1.8.0"
  CONFIG_DIR   = File.expand_path("~/.config/kodemachine")
  CONFIG_FILE  = File.join(CONFIG_DIR, "config.json")
  UTM_DOCS     = File.expand_path("~/Library/Containers/com.utmapp.UTM/Data/Documents")

  DEFAULT_CONFIG = {
    'base_image'  => 'kodeimage-v0.1.0',
    'ssh_user'    => 'kodeman',
    'prefix'      => 'km-',
    'headless'    => true,
    'shared_disk' => 'Shared/projects-luks.qcow2'  # Relative to UTM_DOCS
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

    def generate_mac_address
      # Generate random MAC with locally administered bit set (x2:xx:xx:xx:xx:xx)
      # Using 02 prefix ensures it's a locally administered unicast address
      bytes = [0x02] + 5.times.map { rand(256) }
      bytes.map { |b| format('%02X', b) }.join(':')
    end

    def apfs_clone(name, attach_shared_disk: true, headless: true)
      base_path = "#{UTM_DOCS}/#{@config['base_image']}.utm"
      clone_path = "#{UTM_DOCS}/#{name}.utm"

      abort "❌ Base image not found: #{base_path}" unless File.exist?(base_path)

      # APFS Copy-on-Write clone (instant, zero extra space)
      system("cp", "-Rc", base_path, clone_path)

      # Update VM name and UUID in config
      plist = "#{clone_path}/config.plist"
      content = File.read(plist)
      content.gsub!(/<key>Name<\/key>\s*<string>[^<]+<\/string>/,
                    "<key>Name</key>\n\t\t<string>#{name}</string>")
      content.gsub!(/<key>UUID<\/key>\s*<string>[^<]+<\/string>/,
                    "<key>UUID</key>\n\t\t<string>#{`uuidgen`.strip}</string>")

      # Generate unique MAC address for each clone (required for unique DHCP IP)
      new_mac = generate_mac_address
      content.gsub!(/<key>MacAddress<\/key>\s*<string>[^<]+<\/string>/,
                    "<key>MacAddress</key>\n\t\t\t<string>#{new_mac}</string>")

      # Remove display for headless mode (allows multiple VMs)
      if headless
        puts "👻 Headless mode (no display)"
        content = strip_display(content)
      end

      # Attach shared disk if configured and requested
      if attach_shared_disk && @config['shared_disk']
        shared_path = "#{UTM_DOCS}/#{@config['shared_disk']}"
        if File.exist?(shared_path)
          puts "📎 Attaching shared disk: #{@config['shared_disk']}"
          # Create symlink inside VM bundle (UTM expects disks in Data folder)
          link_name = "shared-projects.qcow2"
          link_path = "#{clone_path}/Data/#{link_name}"
          FileUtils.ln_sf(shared_path, link_path)
          content = inject_shared_disk(content, link_name)  # Use relative name
        else
          puts "⚠️  Shared disk not found: #{shared_path}"
        end
      end

      File.write(plist, content)

      # Register with UTM
      system("open", "-a", "UTM", clone_path)
      sleep 1 # Let UTM register it
    end

    def strip_display(plist_content)
      # Replace Display array with empty array (removes GPU device)
      plist_content.sub(
        /<key>Display<\/key>\s*<array>.*?<\/array>/m,
        "<key>Display</key>\n\t<array>\n\t</array>"
      )
    end

    def gui_vm_running?
      # Check if any VM with display is currently running
      prefix = @config['prefix']
      running_vms = `utmctl list 2>/dev/null`.split("\n").select { |l| l.include?(prefix) && l.include?('started') }

      running_vms.any? do |line|
        vm_name = line.split(/\s+/)[2]
        plist_path = "#{UTM_DOCS}/#{vm_name}.utm/config.plist"
        next false unless File.exist?(plist_path)
        content = File.read(plist_path)
        # Check if Display array has content (not empty)
        content.match?(/<key>Display<\/key>\s*<array>\s*<dict>/)
      end
    end

    def shared_disk_in_use?
      # Check if any running VM has the shared disk attached
      prefix = @config['prefix']
      running_vms = `utmctl list 2>/dev/null`.split("\n").select { |l| l.include?(prefix) && l.include?('started') }

      running_vms.any? do |line|
        vm_name = line.split(/\s+/)[2]
        link_path = "#{UTM_DOCS}/#{vm_name}.utm/Data/shared-projects.qcow2"
        File.exist?(link_path) || File.symlink?(link_path)
      end
    end

    def inject_shared_disk(plist_content, disk_path)
      # Create disk entry XML (matching plist indentation with real tabs)
      disk_entry = "\t\t<dict>\n" \
                   "\t\t\t<key>Identifier</key>\n" \
                   "\t\t\t<string>#{`uuidgen`.strip}</string>\n" \
                   "\t\t\t<key>ImageName</key>\n" \
                   "\t\t\t<string>#{disk_path}</string>\n" \
                   "\t\t\t<key>ImageType</key>\n" \
                   "\t\t\t<string>Disk</string>\n" \
                   "\t\t\t<key>Interface</key>\n" \
                   "\t\t\t<string>VirtIO</string>\n" \
                   "\t\t\t<key>InterfaceVersion</key>\n" \
                   "\t\t\t<integer>1</integer>\n" \
                   "\t\t\t<key>ReadOnly</key>\n" \
                   "\t\t\t<false/>\n" \
                   "\t\t</dict>\n"

      # Insert new disk entry before closing </array> of Drive section
      plist_content.sub(/(\t<\/array>\n\t<key>Information)/, disk_entry + "\t</array>\n\t<key>Information")
    end

    def ensure_running(label, gui: false, attach_disk: true)
      abort "❌ Label required. Run 'kodemachine' for help." unless label

      # Prevent "start" or other commands being used as labels
      reserved = %w[list doctor delete attach status stop suspend]
      abort "❌ '#{label}' is a reserved command." if reserved.include?(label)

      # Check for existing GUI VM if requesting GUI mode
      if gui && gui_vm_running?
        abort "❌ Cannot start GUI VM: another GUI VM is already running.\n" \
              "   Stop it first or use headless mode (without --gui)."
      end

      # Auto-disable shared disk if another VM is using it
      if attach_disk && shared_disk_in_use?
        puts "⚠️  Shared disk in use by another VM - spawning without it"
        attach_disk = false
      end

      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)

      # 1. Clone if missing (using APFS CoW for instant, zero-space clones)
      unless vm.exists?
        puts "🏗️  Cloning #{@config['base_image']} -> #{name}..."
        apfs_clone(name, attach_shared_disk: attach_disk, headless: !gui)
      end

      # 2. Start if stopped
      if vm.status.include?('stopped')
        puts "🚀 Starting #{name}..."
        mode = (!gui) ? "--hide" : ""
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
      @options = { gui: false, no_disk: false }
    end

    # Strip prefix if user accidentally includes it
    def normalize_label(label)
      return nil unless label
      prefix = @config['prefix']
      label.start_with?(prefix) ? label.sub(prefix, '') : label
    end

    def execute(args)
      parser = setup_parser
      parser.parse!(args)

      command = args.shift

      case command
      when nil, ""   then show_help
      when "list"    then display_list
      when "doctor"  then run_doctor
      when "status"  then display_status(normalize_label(args.shift))
      when "attach"  then system("utmctl attach #{@config['prefix']}#{normalize_label(args.shift)}")
      when "start"   then spawn(normalize_label(args.shift))
      when "stop"    then vm_stop(normalize_label(args.shift))
      when "suspend" then vm_suspend(normalize_label(args.shift))
      when "delete"  then vm_delete(normalize_label(args.shift))
      else
        spawn(normalize_label(command)) # Treat as label
      end
    end

    private

    def setup_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: kodemachine [command|label] [options]"
        opts.on("--gui", "Run with window visible") { @options[:gui] = true }
        opts.on("--no-disk", "Don't attach shared projects disk") { @options[:no_disk] = true }
        opts.on("-h", "--help") { show_help; exit }
      end
    end

    def show_help
      puts <<~HELP
        Kodemachine v#{VERSION} - Ephemeral VM Manager

        Usage: kodemachine <label>           Spawn/SSH into VM
               kodemachine <command> [args]  Run a command

        Commands:
          status            Show system overview
          status <label>    Show specific VM status
          list              List all ephemeral VMs
          stop <label>      Shutdown VM
          suspend <label>   Pause VM to memory
          delete <label>    Remove VM entirely
          attach <label>    Serial console access
          doctor            Check system health

        Options:
          --gui             Start with display (only one GUI VM allowed)
          --no-disk         Don't attach shared projects disk
          -h, --help        Show this help

        Notes:
          - Default is headless (no display) - can run multiple VMs
          - Use --gui for browser testing (limited to one VM)

        Examples:
          kodemachine myproject       # Create/connect to km-myproject
          kodemachine stop myproject  # Shutdown km-myproject
      HELP
    end

    def load_config
      FileUtils.mkdir_p(CONFIG_DIR)
      return DEFAULT_CONFIG.dup unless File.exist?(CONFIG_FILE)
      # Merge user config with defaults (user values take precedence)
      DEFAULT_CONFIG.merge(JSON.parse(File.read(CONFIG_FILE))) rescue DEFAULT_CONFIG.dup
    end

    def spawn(label)
      vm = @manager.ensure_running(label, gui: @options[:gui], attach_disk: !@options[:no_disk])
      
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
      return display_system_status unless label
      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)
      return puts "❌ VM '#{name}' not found" unless vm.exists?
      puts "Name:    #{name}"
      puts "Status:  #{vm.status}"
      puts "IP:      #{vm.ip || 'Unknown'}"
      puts "CPU:     #{vm_resources(name).split('/').first}"
      puts "RAM:     #{vm_resources(name).split('/').last}"
      puts "Storage: #{vm_storage(name)}"
    end

    def display_system_status
      prefix = @config['prefix']
      lines = `utmctl list 2>/dev/null`.split("\n")
      vms = lines.select { |l| l.include?(prefix) }

      running = vms.count { |l| l.include?('started') }
      stopped = vms.count { |l| l.include?('stopped') }
      suspended = vms.count { |l| l.include?('suspended') }

      # Calculate total storage
      total_storage = vm_storage_total(prefix)

      puts "Kodemachine v#{VERSION}"
      puts "─" * 30
      puts "Base image: #{@config['base_image']}"
      puts "Prefix:     #{prefix}"
      puts "─" * 30
      puts "VMs:        #{vms.size} total"
      puts "  Running:  #{running}"
      puts "  Stopped:  #{stopped}"
      puts "  Suspended: #{suspended}"
      puts "Storage:    #{total_storage}"

      if running > 0
        puts "─" * 30
        puts "Active VMs:"
        vms.each do |line|
          next unless line.include?('started')
          name = line.split(/\s+/)[2]
          vm = VM.new(name)
          resources = vm_resources(name)
          puts "  #{name.sub(prefix, '')} → #{vm.ip || 'no IP'} (#{resources})"
        end
      end
    end

    def vm_storage_total(prefix)
      output = `du -sh #{UTM_DOCS}/#{prefix}*.utm 2>/dev/null`
      sizes = output.scan(/^\s*([\d.]+)([KMGT]?)/).map do |num, unit|
        num.to_f * { '' => 1, 'K' => 1024, 'M' => 1024**2, 'G' => 1024**3, 'T' => 1024**4 }[unit]
      end
      total_bytes = sizes.sum
      format_size(total_bytes)
    end

    def vm_storage(name)
      output = `du -sh "#{UTM_DOCS}/#{name}.utm" 2>/dev/null`.strip
      output.split("\t").first || "?"
    end

    def vm_resources(name)
      plist_path = "#{UTM_DOCS}/#{name}.utm/config.plist"
      return "?" unless File.exist?(plist_path)
      content = File.read(plist_path)

      cpu = content.match(/<key>CPUCount<\/key>\s*<integer>(\d+)<\/integer>/)&.[](1) || "?"
      mem_mb = content.match(/<key>MemorySize<\/key>\s*<integer>(\d+)<\/integer>/)&.[](1)
      mem = mem_mb ? "#{mem_mb.to_i / 1024}GB" : "?"

      "#{cpu}CPU/#{mem}"
    end

    def format_size(bytes)
      return "0B" if bytes == 0
      units = ['B', 'KB', 'MB', 'GB', 'TB']
      exp = (Math.log(bytes) / Math.log(1024)).to_i
      exp = units.size - 1 if exp >= units.size
      "%.1f%s" % [bytes / (1024.0 ** exp), units[exp]]
    end

    def vm_stop(label)
      return puts "Provide a label" unless label
      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)
      return puts "❌ VM '#{name}' not found" unless vm.exists?
      puts "🛑 Stopping #{name}..."
      system("utmctl stop #{name}")
      puts "✅ Stopped"
    end

    def vm_suspend(label)
      return puts "Provide a label" unless label
      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)
      return puts "❌ VM '#{name}' not found" unless vm.exists?
      puts "⏸️  Suspending #{name}..."
      system("utmctl suspend #{name}")
      puts "✅ Suspended"
    end

    def vm_delete(label)
      return puts "Provide a label" unless label
      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)
      return puts "❌ VM '#{name}' not found" unless vm.exists?
      puts "🗑️  Deleting #{name}..."
      system("utmctl delete #{name}")
      puts "✅ Deleted"
    end
  end
end

Kodemachine::CLI.run(ARGV)
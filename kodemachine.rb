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
  QEMU_IMG     = "/opt/homebrew/bin/qemu-img"

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

      # Strip prefix if accidentally included
      prefix = @config['prefix']
      label = label.sub(/^#{Regexp.escape(prefix)}/, '')

      # Prevent "start" or other commands being used as labels
      reserved = %w[list doctor delete attach status stop suspend]
      abort "❌ '#{label}' is a reserved command." if reserved.include?(label)

      name = "#{prefix}#{label}"
      vm = VM.new(name)

      # Check for existing GUI VM if requesting GUI mode
      if gui && gui_vm_running?
        abort "❌ Cannot start GUI VM: another GUI VM is already running.\n" \
              "   Stop it first or use headless mode (without --gui)."
      end

      # 1. Clone if missing (using APFS CoW for instant, zero-space clones)
      if vm.exists?
        # Existing VM - show disk status
        has_disk = File.symlink?("#{UTM_DOCS}/#{name}.utm/Data/shared-projects.qcow2")
        puts has_disk ? "📎 Has shared disk" : "💾 No shared disk attached"
      else
        # Only check shared disk conflict when creating a new VM
        if attach_disk && shared_disk_in_use?
          puts "⚠️  Shared disk in use by another VM - spawning without it"
          attach_disk = false
        end

        puts "🏗️  Cloning #{@config['base_image']} -> #{name}..."
        apfs_clone(name, attach_shared_disk: attach_disk, headless: !gui)
      end

      # 2. Start if stopped, or resume if paused/suspended
      status = vm.status
      if status.include?('stopped')
        puts "🚀 Starting #{name}..."
        mode = (!gui) ? "--hide" : ""
        `utmctl start #{name} #{mode} 2>/dev/null`

        # Wait for VM to start
        5.times do
          break if vm.status.include?('started')
          sleep 1
        end
      elsif status.include?('paused') || status.include?('suspended')
        puts "▶️  Resuming #{name}..."
        `utmctl start #{name} 2>/dev/null`

        # Wait for VM to resume (should be instant)
        3.times do
          break if vm.status.include?('started')
          sleep 0.5
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

      # Try instant IP first (works for resumed/already running VMs)
      ip = vm.ip

      unless ip
        puts "🔍 Waiting for IP..."
        30.times do
          ip = vm.ip
          break if ip
          print "."
          $stdout.flush
          sleep 2
        end
        puts ""
      end

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
      prefix = @config['prefix']
      lines = `utmctl list 2>/dev/null`.split("\n").select { |l| l.include?(prefix) }

      if lines.empty?
        puts "No ephemeral instances"
        return
      end

      # Collect VM data
      vms = lines.map do |line|
        parts = line.split(/\s+/)
        status = parts[1]
        name = parts[2]
        label = name.sub(prefix, '')
        vm_path = "#{UTM_DOCS}/#{name}.utm"

        # Created (time ago)
        created = File.exist?(vm_path) ? time_ago(File.birthtime(vm_path)) : "?"

        # Shared disk usage
        disk_link = "#{vm_path}/Data/shared-projects.qcow2"
        disk = if File.symlink?(disk_link)
          shared_disk_usage
        else
          "NA"
        end

        # RAM - live usage for running VMs, allocated for stopped
        ram = "?"
        plist_path = "#{vm_path}/config.plist"
        if File.exist?(plist_path)
          content = File.read(plist_path)
          mem_mb = content.match(/<key>MemorySize<\/key>\s*<integer>(\d+)<\/integer>/)&.[](1)
          allocated_gb = mem_mb ? mem_mb.to_i / 1024 : nil

          if status == 'started' && allocated_gb
            # Try live RAM via guest agent
            ram_out = `utmctl exec "#{name}" --cmd free -m 2>/dev/null`.strip
            ram_match = ram_out.match(/Mem:\s+(\d+)\s+(\d+)/)
            if ram_match
              total_mb = ram_match[1].to_i
              used_mb = ram_match[2].to_i
              percent = [(used_mb.to_f / total_mb * 100).round, 1].max
              ram = format("%02d%% of %dGB", percent, total_mb / 1024)
            else
              ram = "#{allocated_gb}GB"
            end
          elsif allocated_gb
            ram = "#{allocated_gb}GB"
          end
        end

        # Storage usage
        storage = vm_storage_percent(vm_path)

        # IP address (only for running VMs)
        ip = status == 'started' ? (VM.new(name).ip || "-") : "-"

        { label: label, status: status, ip: ip, created: created, disk: disk, ram: ram, storage: storage }
      end

      # Status emoji (emoji + status text)
      status_emoji = { 'started' => '🟢', 'stopped' => '⚫', 'suspended' => '🟡', 'paused' => '🟡' }
      vms.each { |v| v[:status_display] = "#{status_emoji[v[:status]] || '⚪'} #{v[:status]}" }

      # Dynamic column widths based on content
      cols = {
        label:   { header: "Label",   values: vms.map { |v| v[:label] } },
        status:  { header: "Status",  values: vms.map { |v| v[:status] } },  # Use raw status for width calc
        ip:      { header: "IP",      values: vms.map { |v| v[:ip] } },
        created: { header: "Created", values: vms.map { |v| v[:created] } },
        disk:    { header: "Disk",    values: vms.map { |v| v[:disk] } },
        ram:     { header: "RAM",     values: vms.map { |v| v[:ram] } },
        storage: { header: "Storage", values: vms.map { |v| v[:storage] } }
      }

      # Calculate widths (header or max content, whichever is larger)
      widths = cols.transform_values do |col|
        [col[:header].length, col[:values].map(&:length).max || 0].max
      end
      widths[:status] += 3  # Account for emoji (2 display chars) + space

      # Header (centered)
      indent = "  "
      puts
      headers = cols.keys.map { |k| cols[k][:header].center(widths[k]) }.join(" │ ")
      puts indent + headers
      puts indent + cols.keys.map { |k| "─" * widths[k] }.join("─┼─")

      # Rows (emoji takes 2 display chars, so pad status accordingly)
      vms.each do |v|
        status_padded = v[:status_display] + " " * (widths[:status] - v[:status].length - 3)
        row = [
          v[:label].ljust(widths[:label]),
          status_padded,
          v[:ip].ljust(widths[:ip]),
          v[:created].ljust(widths[:created]),
          v[:disk].ljust(widths[:disk]),
          v[:ram].ljust(widths[:ram]),
          v[:storage].ljust(widths[:storage])
        ].join(" │ ")
        puts indent + row
      end
      puts
    end

    def time_ago(time)
      seconds = (Time.now - time).to_i
      case seconds
      when 0..59       then "#{seconds}s ago"
      when 60..3599    then "#{seconds / 60}m ago"
      when 3600..86399 then "#{seconds / 3600}h ago"
      else                  "#{seconds / 86400}d ago"
      end
    end

    def shared_disk_usage
      shared_path = "#{UTM_DOCS}/#{@config['shared_disk']}"
      return "?" unless File.exist?(shared_path)

      # Actual size on disk
      actual = `du -sk "#{shared_path}" 2>/dev/null`.split("\t").first.to_i * 1024

      # Virtual size from qcow2
      info = `"#{QEMU_IMG}" info -U "#{shared_path}" 2>/dev/null`
      match = info.match(/virtual size:.*\((\d+) bytes\)/)
      return "?" unless match

      virtual = match[1].to_i
      percent = [(actual.to_f / virtual * 100).round, 1].max
      virtual_gb = (virtual.to_f / 1024**3).round
      format("%02d%% of %dGB", percent, virtual_gb)
    end

    def vm_storage_percent(vm_path)
      return "?" unless File.exist?(vm_path)

      # Get actual size on disk
      actual = `du -sk "#{vm_path}" 2>/dev/null`.split("\t").first.to_i * 1024

      # Get virtual size from qcow2 (main disk, excluding symlinks)
      qcow2_files = Dir.glob("#{vm_path}/Data/*.qcow2").reject { |f| File.symlink?(f) }
      virtual = 0
      qcow2_files.each do |f|
        info = `"#{QEMU_IMG}" info -U "#{f}" 2>/dev/null`
        if (match = info.match(/virtual size:.*\((\d+) bytes\)/))
          virtual += match[1].to_i
        end
      end

      return "?" if virtual == 0

      percent = [(actual.to_f / virtual * 100).round, 1].max
      virtual_gb = (virtual.to_f / 1024**3).round
      format("%02d%% of %dGB", percent, virtual_gb)
    end
    
    def display_status(label)
      return display_system_status unless label
      name = "#{@config['prefix']}#{label}"
      vm = VM.new(name)
      return puts "❌ VM '#{name}' not found" unless vm.exists?

      resources = vm_resources(name)
      status = vm.status

      puts "Name:    #{name}"
      puts "Status:  #{status}"
      puts "IP:      #{vm.ip || 'Unknown'}"
      puts "CPU:     #{resources.split('/').first}"
      puts "RAM:     #{resources.split('/').last}"
      puts "Storage: #{vm_storage(name)}"

      # Live stats if running (via QEMU guest agent)
      if status.include?('started')
        live = live_stats(name)
        if live
          puts "─" * 30
          puts "Live Usage:"
          puts "  RAM:   #{live[:ram]}"
          puts "  CPU:   #{live[:cpu]}"
          puts "  Load:  #{live[:load]}"
        end
      end
    end

    def live_stats(name)
      # RAM: free -m
      ram_out = `utmctl exec #{name} --cmd free -m 2>/dev/null`.strip
      return nil if ram_out.empty?

      ram_match = ram_out.match(/Mem:\s+(\d+)\s+(\d+)/)
      return nil unless ram_match

      total_mb = ram_match[1].to_i
      used_mb = ram_match[2].to_i
      ram_percent = [(used_mb.to_f / total_mb * 100).round, 1].max
      ram_str = format("%02d%% of %dGB", ram_percent, total_mb / 1024)

      # Load average and CPU count
      load_out = `utmctl exec #{name} --cmd cat /proc/loadavg 2>/dev/null`.strip
      cpu_count_out = `utmctl exec #{name} --cmd nproc 2>/dev/null`.strip

      load_parts = load_out.split
      load_str = load_parts[0..2]&.join(", ") || "?"

      # Derive CPU % from 1-min load average relative to CPU count
      cpu_str = "?"
      if load_parts[0] && !cpu_count_out.empty?
        load_1m = load_parts[0].to_f
        cpu_count = cpu_count_out.to_i
        cpu_percent = [(load_1m / cpu_count * 100).round, 1].max
        cpu_percent = [cpu_percent, 99].min  # Cap at 99%
        cpu_str = format("%02d%%", cpu_percent)
      end

      { ram: ram_str, cpu: cpu_str, load: load_str }
    end

    def display_system_status
      puts
      puts "  Kodemachine v#{VERSION}"
      puts "  Base: #{@config['base_image']} │ Shared: #{shared_disk_usage}"
      display_list
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
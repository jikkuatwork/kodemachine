#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'optparse'
require 'securerandom'
require 'tempfile'

module Kodemachine
  VERSION      = "2.0.0"
  CONFIG_DIR   = File.expand_path("~/.config/kodemachine")
  CONFIG_FILE  = File.join(CONFIG_DIR, "config.json")

  DEFAULT_CONFIG = {
    'base_image'  => 'kodeimage-v0.1.0',
    'ssh_user'    => 'kodeman',
    'prefix'      => 'km-',
    'headless'    => true,
    'shared_disk' => 'Shared/projects-luks.qcow2'
  }.freeze

  def self.detect_platform
    if RUBY_PLATFORM.include?('darwin')
      :macos
    elsif RUBY_PLATFORM.include?('linux')
      :linux
    else
      abort "❌ Unsupported platform: #{RUBY_PLATFORM}"
    end
  end

  def self.create_backend(config)
    case detect_platform
    when :macos then UtmBackend.new(config)
    when :linux then LibvirtBackend.new(config)
    end
  end

  # ── macOS Backend (UTM + APFS) ─────────────────────────────────────────────

  class UtmBackend
    UTM_DOCS = File.expand_path("~/Library/Containers/com.utmapp.UTM/Data/Documents")
    QEMU_IMG = "/opt/homebrew/bin/qemu-img"

    def initialize(config)
      @config = config
    end

    def images_dir;    UTM_DOCS; end
    def qemu_img_path; QEMU_IMG; end

    def list_vms
      `utmctl list 2>/dev/null`.split("\n").map do |line|
        parts = line.split(/\s+/)
        next unless parts.size >= 3
        { name: parts[2], status: parts[1] }
      end.compact
    end

    def vm_exists?(name)
      `utmctl list 2>/dev/null`.include?(name)
    end

    def vm_status(name)
      `utmctl status #{name} 2>/dev/null`.strip.downcase
    end

    def vm_ip(name)
      output = `utmctl ip-address #{name} 2>/dev/null`
      output.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)&.[](1)
    end

    def start_vm(name, headless: true)
      mode = headless ? "--hide" : ""
      `utmctl start #{name} #{mode} 2>/dev/null`
    end

    def resume_vm(name)
      `utmctl start #{name} 2>/dev/null`
    end

    def stop_vm(name)
      system("utmctl", "stop", name)
    end

    def suspend_vm(name)
      system("utmctl", "suspend", name)
    end

    def delete_vm(name)
      system("utmctl", "delete", name)
    end

    def attach_vm(name)
      system("utmctl", "attach", name)
    end

    def guest_exec(name, cmd)
      output = `utmctl exec "#{name}" --cmd #{cmd} 2>/dev/null`.strip
      output.empty? ? nil : output
    end

    def inject_hostname(name)
      system("utmctl exec #{name} hostnamectl set-hostname #{name} 2>/dev/null")
    end

    def vm_cpu_count(name)
      content = read_plist(name)
      return nil unless content
      match = content.match(/<key>CPUCount<\/key>\s*<integer>(\d+)<\/integer>/)
      match ? match[1].to_i : nil
    end

    def vm_memory_mb(name)
      content = read_plist(name)
      return nil unless content
      match = content.match(/<key>MemorySize<\/key>\s*<integer>(\d+)<\/integer>/)
      match ? match[1].to_i : nil
    end

    def vm_storage_path(name)
      "#{UTM_DOCS}/#{name}.utm"
    end

    def vm_disk_files(name)
      Dir.glob("#{vm_storage_path(name)}/Data/*.qcow2").reject { |f| File.symlink?(f) }
    end

    def has_display?(name)
      content = read_plist(name)
      return false unless content
      content.match?(/<key>Display<\/key>\s*<array>\s*<dict>/)
    end

    def has_shared_disk?(name)
      link_path = "#{vm_storage_path(name)}/Data/shared-projects.qcow2"
      File.exist?(link_path) || File.symlink?(link_path)
    end

    def shared_disk_path
      sd = @config['shared_disk']
      return nil unless sd
      return File.expand_path(sd) if sd.start_with?('/', '~')
      "#{UTM_DOCS}/#{sd}"
    end

    def is_bridged?(name)
      content = read_plist(name)
      return false unless content
      content.include?('<string>Bridged</string>')
    end

    def clone_base(base_name, clone_name, headless: true, isolated: false, attach_shared_disk: true)
      base_path = "#{UTM_DOCS}/#{base_name}.utm"
      clone_path = "#{UTM_DOCS}/#{clone_name}.utm"
      abort "❌ Base image not found: #{base_path}" unless File.exist?(base_path)

      # APFS Copy-on-Write clone (instant, zero extra space)
      system("cp", "-Rc", base_path, clone_path)

      plist = "#{clone_path}/config.plist"
      content = File.read(plist)

      content.gsub!(/<key>Name<\/key>\s*<string>[^<]+<\/string>/,
                    "<key>Name</key>\n\t\t<string>#{clone_name}</string>")
      content.gsub!(/<key>UUID<\/key>\s*<string>[^<]+<\/string>/,
                    "<key>UUID</key>\n\t\t<string>#{SecureRandom.uuid.upcase}</string>")
      content.gsub!(/<key>MacAddress<\/key>\s*<string>[^<]+<\/string>/,
                    "<key>MacAddress</key>\n\t\t\t<string>#{generate_mac_address}</string>")

      if headless
        puts "👻 Headless mode (no display)"
        content = strip_display(content)
      end

      if isolated
        puts "🔒 Isolated mode (NAT networking)"
      else
        puts "🌐 Bridged networking (accessible from local network)"
        content = apply_bridged_network(content)
      end

      if attach_shared_disk && @config['shared_disk']
        shared = shared_disk_path
        if shared && File.exist?(shared)
          puts "📎 Attaching shared disk: #{@config['shared_disk']}"
          link_name = "shared-projects.qcow2"
          FileUtils.ln_sf(shared, "#{clone_path}/Data/#{link_name}")
          content = inject_shared_disk_plist(content, link_name)
        else
          puts "⚠️  Shared disk not found: #{shared}"
        end
      end

      File.write(plist, content)

      # Register with UTM
      system("open", "-a", "UTM", clone_path)
      sleep 1
    end

    def set_bridged_network(name)
      plist_path = "#{vm_storage_path(name)}/config.plist"
      content = File.read(plist_path)
      content = apply_bridged_network(content)
      File.write(plist_path, content)
    end

    def set_nat_network(name)
      plist_path = "#{vm_storage_path(name)}/config.plist"
      content = File.read(plist_path)
      content = apply_nat_network(content)
      File.write(plist_path, content)
    end

    private

    def read_plist(name)
      path = "#{vm_storage_path(name)}/config.plist"
      File.exist?(path) ? File.read(path) : nil
    end

    def generate_mac_address
      bytes = [0x02] + 5.times.map { rand(256) }
      bytes.map { |b| format('%02X', b) }.join(':')
    end

    def strip_display(content)
      content.sub(/<key>Display<\/key>\s*<array>.*?<\/array>/m,
                  "<key>Display</key>\n\t<array>\n\t</array>")
    end

    def apply_bridged_network(content)
      content.gsub(/<key>Mode<\/key>\s*<string>Shared<\/string>/,
                   "<key>Mode</key>\n\t\t\t<string>Bridged</string>")
    end

    def apply_nat_network(content)
      content.gsub(/<key>Mode<\/key>\s*<string>Bridged<\/string>/,
                   "<key>Mode</key>\n\t\t\t<string>Shared</string>")
    end

    def inject_shared_disk_plist(content, disk_path)
      entry = "\t\t<dict>\n" \
              "\t\t\t<key>Identifier</key>\n" \
              "\t\t\t<string>#{SecureRandom.uuid.upcase}</string>\n" \
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
      content.sub(/(\t<\/array>\n\t<key>Information)/, entry + "\t</array>\n\t<key>Information")
    end
  end

  # ── Linux Backend (libvirt + qcow2) ────────────────────────────────────────

  class LibvirtBackend
    VIRSH_URI = "qemu:///system"

    def initialize(config)
      require 'rexml/document'
      @config = config
      @images_dir = File.expand_path(config['images_dir'] || "~/.local/share/kodemachine/images")
    end

    def images_dir;    @images_dir; end
    def qemu_img_path; @qemu_img ||= find_qemu_img; end

    def list_vms
      `virsh -c #{VIRSH_URI} list --all 2>/dev/null`.split("\n").map do |line|
        line = line.strip
        next if line.empty? || line.start_with?('Id') || line.match?(/\A-+\z/)
        parts = line.split(/\s+/, 3)
        next unless parts.size >= 3
        { name: parts[1], status: normalize_status(parts[2]) }
      end.compact
    end

    def vm_exists?(name)
      system("virsh", "-c", VIRSH_URI, "dominfo", name, out: File::NULL, err: File::NULL)
    end

    def vm_status(name)
      normalize_status(`virsh -c #{VIRSH_URI} domstate #{name} 2>/dev/null`.strip)
    end

    def vm_ip(name)
      # Try guest agent first, then DHCP leases. The guest agent output includes
      # loopback addresses, so never return 127.x.x.x.
      output = `virsh -c #{VIRSH_URI} domifaddr #{name} --source agent 2>/dev/null`
      ip = extract_ipv4(output)
      return ip if ip

      output = `virsh -c #{VIRSH_URI} domifaddr #{name} --source lease 2>/dev/null`
      extract_ipv4(output)
    end

    def start_vm(name, headless: true)
      # Linux VMs are always headless via libvirt (use virt-viewer separately for GUI)
      `virsh -c #{VIRSH_URI} start #{name} 2>/dev/null`
    end

    def resume_vm(name)
      `virsh -c #{VIRSH_URI} resume #{name} 2>/dev/null`
    end

    def stop_vm(name)
      system("virsh", "-c", VIRSH_URI, "shutdown", name)
    end

    def suspend_vm(name)
      system("virsh", "-c", VIRSH_URI, "suspend", name)
    end

    def delete_vm(name)
      disk = vm_main_disk(name)
      system("virsh", "-c", VIRSH_URI, "destroy", name, out: File::NULL, err: File::NULL)
      system("virsh", "-c", VIRSH_URI, "undefine", name)
      FileUtils.rm_f(disk) if disk
    end

    def attach_vm(name)
      system("virsh", "-c", VIRSH_URI, "console", name)
    end

    def guest_exec(name, cmd)
      ip = vm_ip(name)
      return nil unless ip
      output = `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o LogLevel=ERROR #{@config['ssh_user']}@#{ip} #{cmd} 2>/dev/null`.strip
      $?.success? && !output.empty? ? output : nil
    end

    def inject_hostname(name)
      guest_exec(name, "sudo hostnamectl set-hostname #{name}")
    end

    def vm_cpu_count(name)
      xml = dumpxml(name)
      return nil unless xml
      match = xml.match(/<vcpu[^>]*>(\d+)<\/vcpu>/)
      match ? match[1].to_i : nil
    end

    def vm_memory_mb(name)
      xml = dumpxml(name)
      return nil unless xml
      match = xml.match(/<memory unit='(\w+)'>(\d+)<\/memory>/)
      return nil unless match
      unit, value = match[1], match[2].to_i
      case unit
      when "KiB" then value / 1024
      when "MiB" then value
      when "GiB" then value * 1024
      else value / 1024
      end
    end

    def vm_storage_path(name)
      vm_main_disk(name)
    end

    def vm_disk_files(name)
      disk = vm_main_disk(name)
      disk ? [disk] : []
    end

    def has_display?(name)
      xml = dumpxml(name)
      return false unless xml
      xml.include?('<graphics')
    end

    def has_shared_disk?(name)
      xml = dumpxml(name)
      return false unless xml
      shared = shared_disk_path
      return false unless shared
      xml.include?(shared)
    end

    def shared_disk_path
      sd = @config['shared_disk']
      return nil unless sd
      return File.expand_path(sd) if sd.start_with?('/', '~')
      File.join(@images_dir, sd)
    end

    def is_bridged?(name)
      xml = dumpxml(name)
      return false unless xml
      xml.include?("type='bridge'")
    end

    def clone_base(base_name, clone_name, headless: true, isolated: false, attach_shared_disk: true)
      base_disk = vm_main_disk(base_name)
      abort "❌ Cannot find disk for base image: #{base_name}" unless base_disk
      abort "❌ Base disk not found: #{base_disk}" unless File.exist?(base_disk)

      # Create qcow2 backing file (instant CoW clone)
      FileUtils.mkdir_p(@images_dir)
      clone_disk = File.join(@images_dir, "#{clone_name}.qcow2")
      system(qemu_img_path, "create", "-f", "qcow2", "-b", base_disk, "-F", "qcow2", clone_disk)

      # Clone base XML and modify
      xml = dumpxml(base_name)
      abort "❌ Cannot read base VM configuration" unless xml
      doc = REXML::Document.new(xml)

      # Identity
      doc.elements['domain/name'].text = clone_name
      doc.elements['domain/uuid'].text = SecureRandom.uuid

      # MAC address
      mac_el = doc.elements['//interface/mac']
      mac_el.attributes['address'] = generate_mac_address if mac_el

      # Replace main disk, remove extras (CD-ROM, old shared disk, etc.)
      disks_to_remove = []
      doc.elements.each('domain/devices/disk') do |disk|
        target = disk.elements['target']
        if target && target.attributes['dev'] == 'vda'
          source = disk.elements['source']
          source.attributes['file'] = clone_disk if source
          remove_child_elements(disk, 'backingStore')
          backing = disk.add_element('backingStore', 'type' => 'file')
          backing.add_element('format', 'type' => 'qcow2')
          backing.add_element('source', 'file' => base_disk)
          backing.add_element('backingStore')
        else
          disks_to_remove << disk
        end
      end
      disks_to_remove.each { |d| d.parent.delete_element(d) }

      # Network
      if isolated
        puts "🔒 Isolated mode (NAT networking)"
      else
        puts "🌐 NAT networking (default)"
      end

      # Headless
      if headless
        puts "👻 Headless mode (no display)"
        remove_xml_elements(doc, '//graphics')
        remove_xml_elements(doc, '//video')
      end

      # Shared disk
      if attach_shared_disk && @config['shared_disk']
        shared = shared_disk_path
        if shared && File.exist?(shared)
          puts "📎 Attaching shared disk: #{@config['shared_disk']}"
          devices = doc.elements['domain/devices']
          add_shared_disk_xml(devices, shared)
        else
          puts "⚠️  Shared disk not found: #{shared}"
        end
      end

      define_domain(doc)
    end

    def set_bridged_network(name)
      xml = dumpxml(name)
      return unless xml
      doc = REXML::Document.new(xml)
      iface = doc.elements['//interface']
      return unless iface

      bridge = detect_host_bridge
      abort "❌ No bridge device found. Create one first (e.g., br0 via netplan)." unless bridge

      iface.attributes['type'] = 'bridge'
      source = iface.elements['source']
      source.attributes.delete('network')
      source.add_attribute('bridge', bridge)
      define_domain(doc)
    end

    def set_nat_network(name)
      xml = dumpxml(name)
      return unless xml
      doc = REXML::Document.new(xml)
      iface = doc.elements['//interface']
      return unless iface

      iface.attributes['type'] = 'network'
      source = iface.elements['source']
      source.attributes.delete('bridge')
      source.add_attribute('network', 'default')
      define_domain(doc)
    end

    private

    def extract_ipv4(output)
      output.scan(/\b(?:\d{1,3}\.){3}\d{1,3}\b/).find do |ip|
        !ip.start_with?('127.') && ip != '0.0.0.0'
      end
    end

    def normalize_status(status)
      case status
      when "running"  then "started"
      when "shut off" then "stopped"
      when "paused"   then "paused"
      else status
      end
    end

    def dumpxml(name)
      output = `virsh -c #{VIRSH_URI} dumpxml #{name} 2>/dev/null`
      output.empty? ? nil : output
    end

    def vm_main_disk(name)
      xml = dumpxml(name)
      return nil unless xml
      doc = REXML::Document.new(xml)
      doc.elements.each('domain/devices/disk') do |disk|
        target = disk.elements['target']
        next unless target && target.attributes['dev'] == 'vda'
        source = disk.elements['source']
        return source.attributes['file'] if source
      end
      nil
    end

    def generate_mac_address
      bytes = [0x52, 0x54, 0x00] + 3.times.map { rand(256) }
      bytes.map { |b| format('%02x', b) }.join(':')
    end

    def find_qemu_img
      ["/usr/bin/qemu-img", "/usr/local/bin/qemu-img"].find { |p| File.exist?(p) } || "qemu-img"
    end

    def detect_host_bridge
      bridges = `ip -br link show type bridge 2>/dev/null`.split("\n")
      return nil if bridges.empty?
      bridges.first.split(/\s+/).first
    end

    def remove_child_elements(parent, name)
      while (el = parent.elements[name])
        parent.delete_element(el)
      end
    end

    def add_shared_disk_xml(devices, path)
      disk = devices.add_element('disk', 'type' => 'file', 'device' => 'disk')
      disk.add_element('driver', 'name' => 'qemu', 'type' => 'qcow2')
      disk.add_element('source', 'file' => path)
      disk.add_element('target', 'dev' => 'vdb', 'bus' => 'virtio')
    end

    def remove_xml_elements(doc, xpath)
      while (el = doc.elements[xpath])
        el.parent.delete_element(el)
      end
    end

    def define_domain(doc)
      tmp = Tempfile.new(['km-', '.xml'])
      doc.write(tmp)
      tmp.close
      ok = system("virsh", "-c", VIRSH_URI, "define", tmp.path)
      tmp.unlink
      abort "❌ Failed to define libvirt domain" unless ok
      true
    end
  end

  # ── VM State Object ────────────────────────────────────────────────────────

  class VM
    attr_reader :name

    def initialize(name, backend)
      @name = name
      @backend = backend
    end

    def status;  @backend.vm_status(@name); end
    def ip;      @backend.vm_ip(@name); end
    def exists?; @backend.vm_exists?(@name); end
  end

  # ── Manager ────────────────────────────────────────────────────────────────

  class Manager
    def initialize(config, backend)
      @config = config
      @backend = backend
    end

    def ensure_running(label, gui: false, attach_disk: true, isolated: false)
      abort "❌ Label required. Run 'kodemachine' for help." unless label

      prefix = @config['prefix']
      label = label.sub(/^#{Regexp.escape(prefix)}/, '')

      reserved = %w[list doctor delete attach status stop suspend bridge unbridge isolate]
      abort "❌ '#{label}' is a reserved command." if reserved.include?(label)

      is_base = label == 'base'
      name = is_base ? @config['base_image'] : "#{prefix}#{label}"
      vm = VM.new(name, @backend)

      if is_base
        puts "📦 Starting base image directly (changes will affect future clones)"
        abort "❌ Base image not found: #{name}" unless vm.exists?

        running_clones = @backend.list_vms
          .select { |v| v[:name].include?(prefix) && v[:status] == 'started' }
          .map { |v| v[:name] }
        unless running_clones.empty?
          puts "⚠️  Warning: Running clones may conflict with base image network"
          puts "   Running: #{running_clones.join(', ')}"
          puts "   Consider stopping them first: kodemachine stop <label>"
        end
      else
        if gui && gui_vm_running?
          abort "❌ Cannot start GUI VM: another GUI VM is already running.\n" \
                "   Stop it first or use headless mode (without --gui)."
        end

        if vm.exists?
          puts @backend.has_shared_disk?(name) ? "📎 Has shared disk" : "💾 No shared disk attached"
        else
          if attach_disk && shared_disk_in_use?
            puts "⚠️  Shared disk in use by another VM - spawning without it"
            attach_disk = false
          end
          puts "🏗️  Cloning #{@config['base_image']} -> #{name}..."
          @backend.clone_base(@config['base_image'], name,
                              headless: !gui, isolated: isolated, attach_shared_disk: attach_disk)
        end
      end

      status = vm.status
      if status.include?('stopped')
        puts "🚀 Starting #{name}..."
        @backend.start_vm(name, headless: !gui)
        5.times { break if vm.status.include?('started'); sleep 1 }
      elsif status.include?('paused') || status.include?('suspended')
        puts "▶️  Resuming #{name}..."
        @backend.resume_vm(name)
        3.times { break if vm.status.include?('started'); sleep 0.5 }
      end

      vm
    end

    private

    def gui_vm_running?
      prefix = @config['prefix']
      @backend.list_vms
        .select { |v| v[:name].include?(prefix) && v[:status] == 'started' }
        .any? { |v| @backend.has_display?(v[:name]) }
    end

    def shared_disk_in_use?
      prefix = @config['prefix']
      @backend.list_vms
        .select { |v| v[:name].include?(prefix) && v[:status] == 'started' }
        .any? { |v| @backend.has_shared_disk?(v[:name]) }
    end
  end

  # ── CLI ────────────────────────────────────────────────────────────────────

  class CLI
    def self.run(args); new.execute(args); end

    def initialize
      @config  = load_config
      @backend = Kodemachine.create_backend(@config)
      @manager = Manager.new(@config, @backend)
      @options = { gui: false, no_disk: false, isolated: false }
    end

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
      when "attach"  then vm_attach(normalize_label(args.shift))
      when "start", "resume" then spawn(normalize_label(args.shift))
      when "stop"    then vm_stop(normalize_label(args.shift))
      when "suspend" then vm_suspend(normalize_label(args.shift))
      when "delete"  then vm_delete(normalize_label(args.shift))
      when "bridge"  then vm_bridge(normalize_label(args.shift))
      when "unbridge", "isolate" then vm_unbridge(normalize_label(args.shift))
      else
        puts "❌ Unknown command: #{command}"
        puts "   Run 'kodemachine' for help."
      end
    end

    private

    def setup_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: kodemachine [command|label] [options]"
        opts.on("--gui", "Run with window visible") { @options[:gui] = true }
        opts.on("--no-disk", "Don't attach shared projects disk") { @options[:no_disk] = true }
        opts.on("--isolated", "Use NAT networking (default: bridged)") { @options[:isolated] = true }
        opts.on("-h", "--help") { show_help; exit }
      end
    end

    def show_help
      puts <<~HELP
        Kodemachine v#{VERSION} - Ephemeral VM Manager

        Usage: kodemachine <command> [label] [options]

        Commands:
          start <label>     Create/start VM and SSH into it (alias: resume)
          start base        Start the base image directly (for modifications)
          stop <label>      Shutdown VM
          suspend <label>   Pause VM to memory (fast resume)
          delete <label>    Remove VM entirely
          bridge <label>    Switch VM to bridged networking
          isolate <label>   Switch VM to NAT networking (alias: unbridge)
          status            Show system overview
          status <label>    Show specific VM status
          list              List all VMs (including base image)
          attach <label>    Serial console access
          doctor            Check system health

        Options:
          --gui             Start with display (only one GUI VM allowed)
          --no-disk         Don't attach shared projects disk
          --isolated        Use NAT networking (default: bridged)
          -h, --help        Show this help

        Examples:
          kodemachine start myproject   # Create/connect to km-myproject
          kodemachine start base        # Modify the base image
          kodemachine suspend myproject # Pause (instant resume later)
          kodemachine stop myproject    # Shutdown km-myproject
      HELP
    end

    def load_config
      FileUtils.mkdir_p(CONFIG_DIR)
      return DEFAULT_CONFIG.dup unless File.exist?(CONFIG_FILE)
      DEFAULT_CONFIG.merge(JSON.parse(File.read(CONFIG_FILE))) rescue DEFAULT_CONFIG.dup
    end

    def spawn(label)
      vm = @manager.ensure_running(label, gui: @options[:gui], attach_disk: !@options[:no_disk], isolated: @options[:isolated])

      ip = wait_for_ip_and_ssh(vm.name)

      if ip
        puts ""
        puts "✅ Ready: #{ip}"
        @backend.inject_hostname(vm.name)
        exec "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null #{@config['ssh_user']}@#{ip}"
      else
        puts ""
        puts "❌ IP/SSH Timeout. Check VM state or try: kodemachine attach #{label || vm.name}"
      end
    end

    def wait_for_ip_and_ssh(name)
      last_ip = nil
      print "🔍 Waiting for IP/SSH"

      60.times do
        ip = @backend.vm_ip(name)
        if ip
          if ip != last_ip
            print " #{ip}"
            last_ip = ip
          end
          return ip if ssh_port_open?(ip)
        end

        print "."
        $stdout.flush
        sleep 2
      end

      nil
    end

    def ssh_port_open?(ip)
      system("nc", "-z", "-w", "1", ip, "22", out: File::NULL, err: File::NULL)
    end

    def display_list
      prefix = @config['prefix']
      all_vms = @backend.list_vms
      clone_vms = all_vms.select { |v| v[:name].start_with?(prefix) }
      base_vm = all_vms.find { |v| v[:name] == @config['base_image'] }

      if clone_vms.empty? && !base_vm
        puts "No VMs found"
        return
      end

      vms = clone_vms.map do |vm_data|
        name = vm_data[:name]
        status = vm_data[:status]
        label = name.sub(prefix, '')
        vm_path = @backend.vm_storage_path(name)

        created = if vm_path && File.exist?(vm_path)
          time_ago(file_created_time(vm_path))
        else
          "?"
        end

        disk = @backend.has_shared_disk?(name) ? shared_disk_usage : "NA"

        mem_mb = @backend.vm_memory_mb(name)
        allocated_gb = mem_mb ? mem_mb / 1024 : nil
        ram = "?"

        if status == 'started' && allocated_gb
          ram_out = @backend.guest_exec(name, "free -m")
          ram_match = ram_out&.match(/Mem:\s+(\d+)\s+(\d+)/)
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

        storage = vm_storage_percent(name)
        ip = status == 'started' ? (@backend.vm_ip(name) || "-") : "-"

        { label: label, status: status, ip: ip, created: created, disk: disk, ram: ram, storage: storage }
      end

      if base_vm
        name = @config['base_image']
        status = base_vm[:status]
        mem_mb = @backend.vm_memory_mb(name)
        ram = mem_mb ? "#{mem_mb / 1024}GB" : "?"
        ip = status == 'started' ? (@backend.vm_ip(name) || "-") : "-"

        vms.unshift({
          label: "base",
          status: status,
          ip: ip,
          created: "-",
          disk: "NA",
          ram: ram,
          storage: vm_storage_percent(name)
        })
      end

      # Table formatting
      status_emoji = { 'started' => '🟢', 'stopped' => '⚫', 'suspended' => '🟡', 'paused' => '🟡' }
      vms.each { |v| v[:status_display] = "#{status_emoji[v[:status]] || '⚪'} #{v[:status]}" }

      cols = {
        label:   { header: "Label",   values: vms.map { |v| v[:label] } },
        status:  { header: "Status",  values: vms.map { |v| v[:status] } },
        ip:      { header: "IP",      values: vms.map { |v| v[:ip] } },
        created: { header: "Created", values: vms.map { |v| v[:created] } },
        disk:    { header: "Disk",    values: vms.map { |v| v[:disk] } },
        ram:     { header: "RAM",     values: vms.map { |v| v[:ram] } },
        storage: { header: "Storage", values: vms.map { |v| v[:storage] } }
      }

      widths = cols.transform_values do |col|
        [col[:header].length, col[:values].map(&:length).max || 0].max
      end
      widths[:status] += 3  # Account for emoji width

      indent = "  "
      puts
      headers = cols.keys.map { |k| cols[k][:header].center(widths[k]) }.join(" │ ")
      puts indent + headers
      puts indent + cols.keys.map { |k| "─" * widths[k] }.join("─┼─")

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

    def display_status(label)
      return display_system_status unless label
      name = label == 'base' ? @config['base_image'] : "#{@config['prefix']}#{label}"
      return puts "❌ VM '#{name}' not found" unless @backend.vm_exists?(name)

      status = @backend.vm_status(name)
      cpu = @backend.vm_cpu_count(name)
      mem_mb = @backend.vm_memory_mb(name)

      puts "Name:    #{name}"
      puts "Status:  #{status}"
      puts "IP:      #{@backend.vm_ip(name) || 'Unknown'}"
      puts "CPU:     #{cpu || '?'}"
      puts "RAM:     #{mem_mb ? "#{mem_mb / 1024}GB" : '?'}"
      puts "Storage: #{vm_storage(name)}"

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

    def display_system_status
      puts
      puts "  Kodemachine v#{VERSION}"
      puts "  Base: #{@config['base_image']} │ Shared: #{shared_disk_usage}"
      display_list
    end

    def live_stats(name)
      ram_out = @backend.guest_exec(name, "free -m")
      return nil unless ram_out

      ram_match = ram_out.match(/Mem:\s+(\d+)\s+(\d+)/)
      return nil unless ram_match

      total_mb = ram_match[1].to_i
      used_mb = ram_match[2].to_i
      ram_percent = [(used_mb.to_f / total_mb * 100).round, 1].max
      ram_str = format("%02d%% of %dGB", ram_percent, total_mb / 1024)

      load_out = @backend.guest_exec(name, "cat /proc/loadavg")
      cpu_count_out = @backend.guest_exec(name, "nproc")

      load_parts = load_out&.split || []
      load_str = load_parts[0..2]&.join(", ") || "?"

      cpu_str = "?"
      if load_parts[0] && cpu_count_out && !cpu_count_out.empty?
        load_1m = load_parts[0].to_f
        cpu_count = cpu_count_out.to_i
        cpu_percent = [(load_1m / cpu_count * 100).round, 1].max
        cpu_percent = [cpu_percent, 99].min
        cpu_str = format("%02d%%", cpu_percent)
      end

      { ram: ram_str, cpu: cpu_str, load: load_str }
    end

    def run_doctor
      platform = Kodemachine.detect_platform
      puts
      puts "  Kodemachine v#{VERSION} — Doctor"
      puts "  Platform: #{platform}"
      puts

      if platform == :macos
        check("UTM installed", File.exist?("/Applications/UTM.app"))
        check("utmctl available", system("which utmctl > /dev/null 2>&1"))
      else
        check("KVM available", File.exist?("/dev/kvm"))
        check("virsh available", system("which virsh > /dev/null 2>&1"))
        check("libvirt group", `groups 2>/dev/null`.include?('libvirt'))
        net = `virsh -c qemu:///system net-list 2>/dev/null`
        check("Default network active", net.include?('default') && net.include?('active'))
        pools = `virsh -c qemu:///system pool-list --all 2>/dev/null`
        check("kodemachine storage pool active", pools.include?('kodemachine') && pools.include?('active'))
      end

      check("qemu-img available", system("which qemu-img > /dev/null 2>&1"))
      check("Config exists", File.exist?(CONFIG_FILE))
      check("Base image (#{@config['base_image']})", @backend.vm_exists?(@config['base_image']))

      shared = @backend.shared_disk_path
      check("Shared disk", shared && File.exist?(shared))
      puts
    end

    def check(label, ok)
      puts "  #{ok ? '✅' : '❌'} #{label}"
    end

    def shared_disk_usage
      shared_path = @backend.shared_disk_path
      return "?" unless shared_path && File.exist?(shared_path)

      actual = `du -sk "#{shared_path}" 2>/dev/null`.split("\t").first.to_i * 1024
      info = `"#{@backend.qemu_img_path}" info -U "#{shared_path}" 2>/dev/null`
      match = info.match(/virtual size:.*\((\d+) bytes\)/)
      return "?" unless match

      virtual = match[1].to_i
      percent = [(actual.to_f / virtual * 100).round, 1].max
      virtual_gb = (virtual.to_f / 1024**3).round
      format("%02d%% of %dGB", percent, virtual_gb)
    end

    def vm_storage_percent(name)
      vm_path = @backend.vm_storage_path(name)
      return "?" unless vm_path && File.exist?(vm_path)

      actual = `du -sk "#{vm_path}" 2>/dev/null`.split("\t").first.to_i * 1024

      disk_files = @backend.vm_disk_files(name)
      virtual = 0
      disk_files.each do |f|
        info = `"#{@backend.qemu_img_path}" info -U "#{f}" 2>/dev/null`
        if (match = info.match(/virtual size:.*\((\d+) bytes\)/))
          virtual += match[1].to_i
        end
      end

      return "?" if virtual == 0

      percent = [(actual.to_f / virtual * 100).round, 1].max
      virtual_gb = (virtual.to_f / 1024**3).round
      format("%02d%% of %dGB", percent, virtual_gb)
    end

    def vm_storage(name)
      vm_path = @backend.vm_storage_path(name)
      return "?" unless vm_path
      output = `du -sh "#{vm_path}" 2>/dev/null`.strip
      output.split("\t").first || "?"
    end

    def vm_stop(label)
      return puts "Provide a label" unless label
      name = label == 'base' ? @config['base_image'] : "#{@config['prefix']}#{label}"
      return puts "❌ VM '#{name}' not found" unless @backend.vm_exists?(name)
      puts "🛑 Stopping #{name}..."
      @backend.stop_vm(name)
      puts "✅ Stopped"
    end

    def vm_suspend(label)
      return puts "Provide a label" unless label
      name = label == 'base' ? @config['base_image'] : "#{@config['prefix']}#{label}"
      return puts "❌ VM '#{name}' not found" unless @backend.vm_exists?(name)
      puts "⏸️  Suspending #{name}..."
      @backend.suspend_vm(name)
      puts "✅ Suspended"
    end

    def vm_delete(label)
      return puts "Provide a label" unless label
      if label == 'base'
        abort "❌ Cannot delete base image. Use your hypervisor directly if you really want to remove it."
      end
      name = "#{@config['prefix']}#{label}"
      return puts "❌ VM '#{name}' not found" unless @backend.vm_exists?(name)
      puts "🗑️  Deleting #{name}..."
      @backend.delete_vm(name)
      puts "✅ Deleted"
    end

    def vm_attach(label)
      return puts "Provide a label" unless label
      name = label == 'base' ? @config['base_image'] : "#{@config['prefix']}#{label}"
      @backend.attach_vm(name)
    end

    def vm_bridge(label)
      return puts "Provide a label" unless label
      name = label == 'base' ? @config['base_image'] : "#{@config['prefix']}#{label}"
      return puts "❌ VM '#{name}' not found" unless @backend.vm_exists?(name)

      unless @backend.vm_status(name).include?('stopped')
        puts "❌ VM must be stopped first. Run: kodemachine stop #{label}"
        return
      end

      if @backend.is_bridged?(name)
        puts "✅ Already using bridged networking"
        return
      end

      @backend.set_bridged_network(name)
      puts "🌐 Switched to bridged networking"
      puts "   Start with: kodemachine start #{label}"
    end

    def vm_unbridge(label)
      return puts "Provide a label" unless label
      name = label == 'base' ? @config['base_image'] : "#{@config['prefix']}#{label}"
      return puts "❌ VM '#{name}' not found" unless @backend.vm_exists?(name)

      unless @backend.vm_status(name).include?('stopped')
        puts "❌ VM must be stopped first. Run: kodemachine stop #{label}"
        return
      end

      unless @backend.is_bridged?(name)
        puts "✅ Already using NAT networking"
        return
      end

      @backend.set_nat_network(name)
      puts "🔒 Switched to NAT networking (isolated)"
      puts "   Start with: kodemachine start #{label}"
    end

    def file_created_time(path)
      File.birthtime(path)
    rescue NotImplementedError
      File.mtime(path)
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
  end
end

Kodemachine::CLI.run(ARGV)

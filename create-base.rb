#!/usr/bin/env ruby
# frozen_string_literal: true

# Kodemachine Base Image Builder
# Creates a golden VM image for ephemeral cloning
# Works on macOS (UTM) and Linux (libvirt/KVM)

require 'json'
require 'fileutils'
require 'open3'
require 'optparse'
require 'securerandom'
require 'shellwords'

module KodemachineBase
  VERSION = "1.0.0"

  CONFIG_DIR   = File.expand_path("~/.config/kodemachine")
  CONFIG_FILE  = File.join(CONFIG_DIR, "config.json")

  DEFAULT_BASE_NAME = "kodeimage"
  DEFAULT_SSH_USER  = "kodeman"

  PACKAGES = {
    core: %w[
      qemu-guest-agent
      openssh-server
      curl
      wget
      git
      build-essential
    ],
    gui: %w[
      xfce4
      xfce4-goodies
      xfce4-terminal
      dbus-x11
    ],
    browsers: %w[
      firefox
      chromium-browser
    ],
    fonts: %w[
      fonts-noto
      fonts-liberation
      fontconfig
    ],
    tools: %w[
      htop
      btop
      tree
      jq
      unzip
      xclip
    ],
    containers: %w[
      podman
      uidmap
      fuse-overlayfs
      slirp4netns
    ]
  }.freeze

  COLORS = {
    red:    "\e[31m",
    green:  "\e[32m",
    yellow: "\e[33m",
    blue:   "\e[34m",
    gray:   "\e[90m",
    reset:  "\e[0m"
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

  # ── Shared builder logic ───────────────────────────────────────────────────

  class Builder
    def initialize(options = {})
      @platform = KodemachineBase.detect_platform
      @options = {
        name: nil,
        ssh_user: DEFAULT_SSH_USER,
        host_ssh_key: nil,
        dotfiles_repo: nil,
        skip_gui: false,
        skip_browsers: false,
        ip: nil,
        verbose: false
      }.merge(options)

      @version = Time.now.strftime("%Y.%m")
      @base_name = @options[:name] || "#{DEFAULT_BASE_NAME}-v#{@version}"

      @options[:host_ssh_key] ||= detect_host_ssh_key
      unless @options[:host_ssh_key]
        puts "#{COLORS[:red]}✗ No SSH key found#{COLORS[:reset]}"
        puts
        puts "  kodemachine needs your public key to enable SSH access to VMs."
        puts
        puts "  Create one with:"
        puts "    ssh-keygen -t ed25519"
        puts
        puts "  Then run this script again."
        exit 1
      end
    end

    def detect_host_ssh_key
      candidates = [
        File.expand_path("~/.ssh/id_ed25519.pub"),
        File.expand_path("~/.ssh/id_rsa.pub")
      ]
      candidates.find { |path| File.exist?(path) }
    end

    def run
      puts banner
      puts

      check_prerequisites
      get_vm_info
      wait_for_ssh
      provision_vm
      install_dotfiles if @options[:dotfiles_repo]
      inject_ssh_key if @options[:host_ssh_key]
      if @platform == :linux
        enable_serial_console
        configure_linux_guest
      end
      prepare_for_cloning
      finalize

      puts
      puts "#{COLORS[:green]}╔════════════════════════════════════════╗#{COLORS[:reset]}"
      puts "#{COLORS[:green]}║       Base Image Ready!                ║#{COLORS[:reset]}"
      puts "#{COLORS[:green]}╚════════════════════════════════════════╝#{COLORS[:reset]}"
      puts
      puts "Image: #{@base_name}"
      puts
      puts "Next steps:"
      puts "  1. Update ~/.config/kodemachine/config.json:"
      puts "     { \"base_image\": \"#{@base_name}\" }"
      puts "  2. Start using: kodemachine start myproject"
      puts
    end

    private

    def banner
      <<~BANNER
        #{COLORS[:blue]}╔════════════════════════════════════════╗
        ║   Kodemachine Base Builder v#{VERSION}      ║
        ╚════════════════════════════════════════╝#{COLORS[:reset]}
      BANNER
    end

    def step(msg);    puts "#{COLORS[:blue]}==>#{COLORS[:reset]} #{msg}"; end
    def substep(msg); puts "    #{msg}"; end
    def success(msg); puts "#{COLORS[:green]}✓#{COLORS[:reset]} #{msg}"; end
    def warn(msg);    puts "#{COLORS[:yellow]}!#{COLORS[:reset]} #{msg}"; end
    def error(msg);   puts "#{COLORS[:red]}✗#{COLORS[:reset]} #{msg}"; end

    def verbose(msg)
      puts "#{COLORS[:gray]}  #{msg}#{COLORS[:reset]}" if @options[:verbose]
    end

    # ── Prerequisites ──

    def check_prerequisites
      step "Checking prerequisites..."

      if @platform == :macos
        check_macos_prerequisites
      else
        check_linux_prerequisites
      end
    end

    def check_macos_prerequisites
      unless File.exist?("/Applications/UTM.app")
        error "UTM not installed"
        puts "  Run: ./setup-host.rb"
        exit 1
      end
      success "UTM installed"

      unless system("which utmctl > /dev/null 2>&1")
        error "utmctl not found"
        puts "  Ensure UTM.app includes utmctl or install separately"
        exit 1
      end
      success "utmctl available"
    end

    def check_linux_prerequisites
      unless File.exist?("/dev/kvm")
        error "KVM not available"
        puts "  Run: ./setup-host.rb"
        exit 1
      end
      success "KVM available"

      unless system("which virsh > /dev/null 2>&1")
        error "virsh not found"
        puts "  Run: ./setup-host.rb"
        exit 1
      end
      success "virsh available"

      unless `groups`.include?('libvirt')
        error "User not in libvirt group"
        puts "  Run: ./setup-host.rb"
        exit 1
      end
      success "libvirt group OK"
    end

    # ── VM Discovery ──

    def get_vm_info
      step "Looking for VM to provision..."

      if @platform == :macos
        get_vm_info_macos
      else
        get_vm_info_linux
      end
    end

    def get_vm_info_macos
      existing = `utmctl list 2>/dev/null`.split("\n").find { |l| l.include?(@base_name) }

      if existing
        status = existing.split(/\s+/)[1]
        if status == 'started'
          success "Found running: #{@base_name}"
        else
          warn "Found stopped: #{@base_name}. Starting..."
          system("utmctl start #{@base_name}")
          sleep 3
        end
      else
        ubuntu_vms = `utmctl list 2>/dev/null`.split("\n")
          .select { |l| l.downcase.include?('ubuntu') && !l.include?('kodeimage') }

        if ubuntu_vms.empty?
          no_vm_found_message("UTM")
          exit 1
        end

        vm_name = ubuntu_vms.first.split(/\s+/)[2]
        confirm_provision(vm_name)

        @source_vm = vm_name
        status = ubuntu_vms.first.split(/\s+/)[1]
        unless status == 'started'
          step "Starting #{vm_name}..."
          system("utmctl start #{vm_name}")
          sleep 3
        end
      end

      @vm_name = @source_vm || @base_name
    end

    def get_vm_info_linux
      virsh_uri = "qemu:///system"
      all_vms = `virsh -c #{virsh_uri} list --all 2>/dev/null`

      existing = all_vms.split("\n").find { |l| l.include?(@base_name) }

      if existing
        state = existing.strip.split(/\s+/, 3)[2]
        if state == 'running'
          success "Found running: #{@base_name}"
        else
          warn "Found stopped: #{@base_name}. Starting..."
          system("virsh", "-c", virsh_uri, "start", @base_name)
          sleep 3
        end
      else
        ubuntu_vms = all_vms.split("\n").select do |l|
          stripped = l.strip
          next false if stripped.empty? || stripped.start_with?('Id') || stripped.match?(/\A-+\z/)
          stripped.downcase.include?('ubuntu') && !stripped.include?('kodeimage')
        end

        if ubuntu_vms.empty?
          no_vm_found_message("virt-manager or virt-install")
          exit 1
        end

        vm_name = ubuntu_vms.first.strip.split(/\s+/, 3)[1]
        confirm_provision(vm_name)

        @source_vm = vm_name
        state = ubuntu_vms.first.strip.split(/\s+/, 3)[2]
        unless state == 'running'
          step "Starting #{vm_name}..."
          system("virsh", "-c", virsh_uri, "start", vm_name)
          sleep 3
        end
      end

      @vm_name = @source_vm || @base_name
    end

    def no_vm_found_message(tool)
      puts
      error "No suitable VM found"
      puts
      puts "Please create a fresh Ubuntu VM first:"
      puts
      if @platform == :macos
        puts "  1. Download Ubuntu 24.04 ARM64:"
        puts "     https://ubuntu.com/download/server/arm"
        puts
        puts "  2. Create VM in UTM:"
      else
        puts "  1. Download Ubuntu 24.04 (x86_64):"
        puts "     https://ubuntu.com/download/server"
        puts
        puts "  2. Create VM in virt-manager (or virt-install):"
      end
      puts "     - Name: ubuntu-base (or similar)"
      puts "     - RAM: 4-8GB"
      puts "     - Disk: 32-64GB"
      puts
      puts "  3. Install Ubuntu, then run this script again"
      puts
    end

    def confirm_provision(vm_name)
      puts
      puts "Found: #{vm_name}"
      puts "This VM will be provisioned and renamed to: #{@base_name}"
      puts
      print "Continue? [y/N] "
      response = $stdin.gets.strip.downcase
      exit 0 unless response == 'y'
    end

    # ── SSH ──

    def wait_for_ssh
      step "Waiting for SSH..."
      @ip = @options[:ip]

      unless @ip
        30.times do
          @ip = detect_ip
          break if @ip
          print "."
          $stdout.flush
          sleep 2
        end
        puts
      end

      unless @ip
        error "Could not get IP address"
        if @platform == :macos
          puts "  Try: utmctl attach #{@vm_name}"
        else
          puts "  Try: virsh -c qemu:///system console #{@vm_name}"
        end
        puts "  Then run: ip addr show"
        puts "  And re-run with: --ip <address>"
        exit 1
      end

      success "IP: #{@ip}"

      step "Waiting for SSH to accept connections..."
      ssh_ready = false
      20.times do
        if system("nc -z -w1 #{@ip} 22 2>/dev/null")
          ssh_ready = true
          break
        end
        print "."
        $stdout.flush
        sleep 2
      end
      puts

      unless ssh_ready
        error "SSH not responding on #{@ip}:22"
        exit 1
      end

      success "SSH ready"
    end

    def detect_ip
      if @platform == :macos
        output = `utmctl ip-address #{@vm_name} 2>/dev/null`
        extract_ipv4(output)
      else
        output = `virsh -c qemu:///system domifaddr #{@vm_name} --source agent 2>/dev/null`
        ip = extract_ipv4(output)
        return ip if ip

        output = `virsh -c qemu:///system domifaddr #{@vm_name} --source lease 2>/dev/null`
        extract_ipv4(output)
      end
    end

    def extract_ipv4(output)
      output.scan(/\b(?:\d{1,3}\.){3}\d{1,3}\b/).find do |ip|
        !ip.start_with?('127.') && ip != '0.0.0.0'
      end
    end

    def ssh_exec(cmd, sudo: false)
      full_cmd = sudo ? "sudo sh -c #{Shellwords.escape(cmd)}" : cmd
      verbose "SSH: #{full_cmd}"

      ssh_cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "#{@options[:ssh_user]}@#{@ip}",
        full_cmd
      ]

      stdout, stderr, status = Open3.capture3(*ssh_cmd)

      unless status.success?
        error "Command failed: #{full_cmd}"
        puts stderr unless stderr.empty?
        return false
      end

      verbose stdout unless stdout.empty?
      true
    end

    # ── Provisioning ──

    def provision_vm
      step "Provisioning VM..."

      substep "Updating package lists..."
      ssh_exec("apt update", sudo: true)

      substep "Upgrading packages..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt upgrade -y", sudo: true)

      substep "Installing core packages..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:core].join(' ')}", sudo: true)

      ssh_exec("systemctl enable --now qemu-guest-agent", sudo: true)

      unless @options[:skip_gui]
        substep "Installing GUI (XFCE)..."
        ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:gui].join(' ')}", sudo: true)
      end

      unless @options[:skip_browsers]
        substep "Installing browsers..."
        ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:browsers].join(' ')}", sudo: true)
      end

      substep "Installing fonts..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:fonts].join(' ')}", sudo: true)

      substep "Installing Nerd Font (CaskaydiaCove)..."
      nerd_font_cmd = [
        "mkdir -p ~/.local/share/fonts",
        "cd /tmp",
        "curl -fsSL -o nerd-font.zip https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip",
        "unzip -o nerd-font.zip -d ~/.local/share/fonts '*.ttf'",
        "fc-cache -fv",
        "rm nerd-font.zip"
      ].join(" && ")
      ssh_exec(nerd_font_cmd)

      substep "Installing tools..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:tools].join(' ')}", sudo: true)

      substep "Installing container runtime (Podman, no Docker daemon)..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:containers].join(' ')}", sudo: true)
      ssh_exec("grep -q '^#{@options[:ssh_user]}:' /etc/subuid || usermod --add-subuids 100000-165535 #{@options[:ssh_user]}", sudo: true)
      ssh_exec("grep -q '^#{@options[:ssh_user]}:' /etc/subgid || usermod --add-subgids 100000-165535 #{@options[:ssh_user]}", sudo: true)

      substep "Setting zsh as default shell..."
      ssh_exec("apt install -y zsh", sudo: true)
      ssh_exec("chsh -s /bin/zsh #{@options[:ssh_user]}", sudo: true)

      substep "Cleaning up..."
      ssh_exec("apt autoremove -y && apt clean", sudo: true)

      success "Base provisioning complete"
    end

    def install_dotfiles
      step "Installing dotfiles..."
      repo = @options[:dotfiles_repo]

      substep "Cloning #{repo}..."
      ssh_exec("git clone #{repo} ~/dotfiles")

      substep "Looking for bootstrap.sh..."
      ssh_exec("cd ~/dotfiles && test -f bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh start || echo 'No bootstrap.sh found, skipping'")

      success "Dotfiles installed"
    end

    def inject_ssh_key
      step "Injecting host SSH key..."
      key_path = @options[:host_ssh_key]
      unless File.exist?(key_path)
        error "SSH key not found: #{key_path}"
        return
      end

      substep "Using: #{key_path}"
      key = File.read(key_path).strip

      ssh_exec("mkdir -p ~/.ssh && chmod 700 ~/.ssh")
      ssh_exec("echo '#{key}' >> ~/.ssh/authorized_keys")
      ssh_exec("chmod 600 ~/.ssh/authorized_keys")

      success "Host SSH key injected"
    end

    def enable_serial_console
      step "Enabling serial console (for virsh console access)..."

      substep "Configuring GRUB for serial output..."
      ssh_exec("sed -i 's/^GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"console=tty0 console=ttyS0,115200\"/' /etc/default/grub", sudo: true)
      ssh_exec("update-grub", sudo: true)

      substep "Enabling serial getty..."
      ssh_exec("systemctl enable serial-getty@ttyS0.service", sudo: true)

      success "Serial console enabled"
    end

    def configure_linux_guest
      step "Configuring Linux guest for cloning..."

      substep "Configuring MAC-independent DHCP..."
      netplan_cmd = <<~CMD
        rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/50-curtin-networking.yaml
        cat > /etc/netplan/01-kodemachine.yaml <<'EOF'
        network:
          version: 2
          ethernets:
            default:
              match:
                name: "en*"
              dhcp4: true
              dhcp-identifier: mac
              dhcp6: true
        EOF
        chmod 600 /etc/netplan/01-kodemachine.yaml
        netplan generate
      CMD
      ssh_exec(netplan_cmd, sudo: true)

      substep "Ensuring SSH host keys regenerate on clone boot..."
      hostkeys_cmd = <<~CMD
        mkdir -p /etc/systemd/system/ssh.service.d
        cat > /etc/systemd/system/ssh.service.d/10-kodemachine-hostkeys.conf <<'EOF'
        [Service]
        ExecStartPre=
        ExecStartPre=/usr/bin/ssh-keygen -A
        ExecStartPre=/usr/sbin/sshd -t
        EOF
        systemctl daemon-reload
        systemctl enable ssh
      CMD
      ssh_exec(hostkeys_cmd, sudo: true)

      success "Linux guest clone settings applied"
    end

    def prepare_for_cloning
      step "Preparing for cloning..."

      substep "Truncating machine-id..."
      ssh_exec("truncate -s 0 /etc/machine-id", sudo: true)

      substep "Clearing history..."
      ssh_exec("cat /dev/null > ~/.bash_history")
      ssh_exec("cat /dev/null > ~/.zsh_history 2>/dev/null || true")

      success "Ready for cloning"
    end

    # ── Finalize ──

    def finalize
      step "Finalizing..."

      substep "Clearing SSH host keys and shutting down VM..."
      ssh_exec("rm -f /etc/ssh/ssh_host_* && shutdown -h now", sudo: true)

      # Wait for shutdown
      10.times do
        if @platform == :macos
          status = `utmctl status #{@vm_name} 2>/dev/null`.strip.downcase
          break if status.include?('stopped')
        else
          status = `virsh -c qemu:///system domstate #{@vm_name} 2>/dev/null`.strip
          break if status == 'shut off'
        end
        sleep 2
      end

      # Rename if source VM differs from target name
      if @source_vm && @source_vm != @base_name
        if @platform == :macos
          finalize_rename_macos
        else
          finalize_rename_linux
        end
      end

      update_config
      success "Base image ready: #{@base_name}"
    end

    def finalize_rename_macos
      utm_docs = File.expand_path("~/Library/Containers/com.utmapp.UTM/Data/Documents")
      source_path = "#{utm_docs}/#{@source_vm}.utm"
      target_path = "#{utm_docs}/#{@base_name}.utm"

      substep "Renaming #{@source_vm} -> #{@base_name}..."

      if File.exist?(source_path)
        system("utmctl delete #{@source_vm} 2>/dev/null")
        sleep 1

        FileUtils.mv(source_path, target_path)

        plist = "#{target_path}/config.plist"
        if File.exist?(plist)
          content = File.read(plist)
          content.gsub!(/<key>Name<\/key>\s*<string>[^<]+<\/string>/,
                        "<key>Name</key>\n\t\t<string>#{@base_name}</string>")
          File.write(plist, content)
        end

        system("open -a UTM '#{target_path}'")
        sleep 2
      end
    end

    def finalize_rename_linux
      require 'rexml/document'
      require 'tempfile'

      virsh_uri = "qemu:///system"

      substep "Renaming #{@source_vm} -> #{@base_name}..."

      # Dump current XML
      xml = `virsh -c #{virsh_uri} dumpxml #{@source_vm} 2>/dev/null`
      return if xml.empty?

      doc = REXML::Document.new(xml)

      # Get disk path for renaming and remove install/cloud-init media.
      old_disk = nil
      disks_to_remove = []
      doc.elements.each('domain/devices/disk') do |disk|
        target = disk.elements['target']
        if target && target.attributes['dev'] == 'vda'
          source = disk.elements['source']
          old_disk = source.attributes['file'] if source
        else
          disks_to_remove << disk
        end
      end
      disks_to_remove.each { |disk| disk.parent.delete_element(disk) }

      # Undefine old domain
      system("virsh", "-c", virsh_uri, "undefine", @source_vm)

      # Rename disk file if it contains the old name
      if old_disk && File.exist?(old_disk)
        new_disk = old_disk.sub(@source_vm, @base_name)
        if new_disk != old_disk
          FileUtils.mv(old_disk, new_disk)
          # Update disk path in XML
          doc.elements.each('domain/devices/disk') do |disk|
            source = disk.elements['source']
            source.attributes['file'] = new_disk if source && source.attributes['file'] == old_disk
          end
        end
      end

      # Update name and UUID
      doc.elements['domain/name'].text = @base_name
      doc.elements['domain/uuid'].text = SecureRandom.uuid

      # Redefine with new name
      tmp = Tempfile.new(['km-base-', '.xml'])
      doc.write(tmp)
      tmp.close
      system("virsh", "-c", virsh_uri, "define", tmp.path)
      tmp.unlink
    end

    def update_config
      FileUtils.mkdir_p(CONFIG_DIR)

      config = if File.exist?(CONFIG_FILE)
        JSON.parse(File.read(CONFIG_FILE)) rescue {}
      else
        {}
      end

      config['base_image'] = @base_name
      config['ssh_user'] ||= @options[:ssh_user]
      config['prefix'] ||= 'km-'
      config['headless'] = true if config['headless'].nil?
      config['shared_disk'] ||= 'Shared/projects-luks.qcow2'
      config['images_dir'] ||= '~/.local/share/kodemachine/images' if @platform == :linux

      File.write(CONFIG_FILE, JSON.pretty_generate(config))
      success "Updated config: #{CONFIG_FILE}"
    end
  end

  # ── CLI ────────────────────────────────────────────────────────────────────

  class CLI
    def self.run(args)
      options = {}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: create-base.rb [options]"
        opts.separator ""
        opts.separator "Creates a golden VM image for kodemachine cloning."
        opts.separator ""
        opts.separator "Options:"

        opts.on("-n", "--name NAME", "Base image name (default: kodeimage-vYYYY.MM)") do |v|
          options[:name] = v
        end

        opts.on("-u", "--user USER", "SSH username (default: kodeman)") do |v|
          options[:ssh_user] = v
        end

        opts.on("-k", "--host-ssh-key PATH", "Host's SSH public key (default: ~/.ssh/id_ed25519.pub)") do |v|
          options[:host_ssh_key] = v
        end

        opts.on("-d", "--dotfiles REPO", "Git repo URL for dotfiles") do |v|
          options[:dotfiles_repo] = v
        end

        opts.on("--ip ADDRESS", "Manual IP address (skip auto-detection)") do |v|
          options[:ip] = v
        end

        opts.on("--skip-gui", "Skip GUI installation (XFCE)") do
          options[:skip_gui] = true
        end

        opts.on("--skip-browsers", "Skip browser installation") do
          options[:skip_browsers] = true
        end

        opts.on("-v", "--verbose", "Verbose output") do
          options[:verbose] = true
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)

      Builder.new(options).run
    end
  end
end

# Run if executed directly
if __FILE__ == $0
  KodemachineBase::CLI.run(ARGV)
end

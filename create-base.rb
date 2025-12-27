#!/usr/bin/ruby
# frozen_string_literal: true

# Kodemachine Base Image Builder
# Creates a golden VM image for ephemeral cloning

require 'json'
require 'fileutils'
require 'open3'
require 'optparse'

module KodemachineBase
  VERSION = "1.0.0"

  # Configuration
  UTM_DOCS     = File.expand_path("~/Library/Containers/com.utmapp.UTM/Data/Documents")
  CONFIG_DIR   = File.expand_path("~/.config/kodemachine")
  CONFIG_FILE  = File.join(CONFIG_DIR, "config.json")

  # Default base image settings
  DEFAULT_BASE_NAME = "kodeimage"
  DEFAULT_SSH_USER  = "kodeman"

  # Packages to install
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
    ],
    tools: %w[
      htop
      btop
      tree
      jq
      unzip
      xclip
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

  class Builder
    def initialize(options = {})
      @options = {
        name: nil,           # Base image name (auto-versioned)
        ssh_user: DEFAULT_SSH_USER,
        host_ssh_key: nil,   # Path to host's public key (auto-detected if not provided)
        dotfiles_repo: nil,  # Git repo URL
        skip_gui: false,
        skip_browsers: false,
        ip: nil,             # Manual IP if needed
        verbose: false
      }.merge(options)

      @version = Time.now.strftime("%Y.%m")
      @base_name = @options[:name] || "#{DEFAULT_BASE_NAME}-v#{@version}"

      # Auto-detect host SSH key if not provided
      @options[:host_ssh_key] ||= detect_host_ssh_key
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

    def step(msg)
      puts "#{COLORS[:blue]}==>#{COLORS[:reset]} #{msg}"
    end

    def substep(msg)
      puts "    #{msg}"
    end

    def success(msg)
      puts "#{COLORS[:green]}✓#{COLORS[:reset]} #{msg}"
    end

    def warn(msg)
      puts "#{COLORS[:yellow]}!#{COLORS[:reset]} #{msg}"
    end

    def error(msg)
      puts "#{COLORS[:red]}✗#{COLORS[:reset]} #{msg}"
    end

    def verbose(msg)
      puts "#{COLORS[:gray]}  #{msg}#{COLORS[:reset]}" if @options[:verbose]
    end

    def check_prerequisites
      step "Checking prerequisites..."

      # UTM installed?
      unless File.exist?("/Applications/UTM.app")
        error "UTM not installed"
        puts "  Run: ./setup-host.rb"
        exit 1
      end
      success "UTM installed"

      # utmctl available?
      unless system("which utmctl > /dev/null 2>&1")
        error "utmctl not found"
        puts "  Ensure UTM.app includes utmctl or install separately"
        exit 1
      end
      success "utmctl available"
    end

    def get_vm_info
      step "Looking for VM to provision..."

      # Check if base image already exists
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
        # Look for any VM with 'ubuntu' in the name that's not already a kodeimage
        ubuntu_vms = `utmctl list 2>/dev/null`.split("\n")
          .select { |l| l.downcase.include?('ubuntu') && !l.include?('kodeimage') }

        if ubuntu_vms.empty?
          puts
          error "No suitable VM found"
          puts
          puts "Please create a fresh Ubuntu VM first:"
          puts
          puts "  1. Download Ubuntu 24.04 ARM64:"
          puts "     https://ubuntu.com/download/server/arm"
          puts
          puts "  2. Create VM in UTM:"
          puts "     - Name: ubuntu-base (or similar)"
          puts "     - RAM: 4-8GB"
          puts "     - Disk: 32-64GB"
          puts
          puts "  3. Install Ubuntu, then run this script again"
          puts
          exit 1
        end

        vm_name = ubuntu_vms.first.split(/\s+/)[2]
        puts
        puts "Found: #{vm_name}"
        puts "This VM will be provisioned and renamed to: #{@base_name}"
        puts
        print "Continue? [y/N] "
        response = $stdin.gets.strip.downcase
        exit 0 unless response == 'y'

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

    def wait_for_ssh
      step "Waiting for SSH..."

      @ip = @options[:ip]

      unless @ip
        30.times do |i|
          output = `utmctl ip-address #{@vm_name} 2>/dev/null`
          @ip = output.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)&.[](1)
          break if @ip
          print "."
          $stdout.flush
          sleep 2
        end
        puts
      end

      unless @ip
        error "Could not get IP address"
        puts "  Try: utmctl attach #{@vm_name}"
        puts "  Then run: ip addr show"
        puts "  And re-run with: --ip <address>"
        exit 1
      end

      success "IP: #{@ip}"

      # Wait for SSH to be ready
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

    def ssh_exec(cmd, sudo: false)
      full_cmd = sudo ? "sudo #{cmd}" : cmd
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

    def provision_vm
      step "Provisioning VM..."

      # Update package lists
      substep "Updating package lists..."
      ssh_exec("apt update", sudo: true)

      # Upgrade existing packages
      substep "Upgrading packages..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt upgrade -y", sudo: true)

      # Install core packages
      substep "Installing core packages..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:core].join(' ')}", sudo: true)

      # Enable qemu-guest-agent
      ssh_exec("systemctl enable --now qemu-guest-agent", sudo: true)

      # Install GUI unless skipped
      unless @options[:skip_gui]
        substep "Installing GUI (XFCE)..."
        ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:gui].join(' ')}", sudo: true)
      end

      # Install browsers unless skipped
      unless @options[:skip_browsers]
        substep "Installing browsers..."
        ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:browsers].join(' ')}", sudo: true)
      end

      # Install fonts
      substep "Installing fonts..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:fonts].join(' ')}", sudo: true)

      # Install Nerd Font
      substep "Installing Nerd Font (CaskaydiaCove)..."
      nerd_font_cmd = <<~CMD.gsub("\n", " && ")
        mkdir -p ~/.local/share/fonts
        cd /tmp
        curl -fsSL -o nerd-font.zip https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip
        unzip -o nerd-font.zip -d ~/.local/share/fonts '*.ttf'
        fc-cache -fv
        rm nerd-font.zip
      CMD
      ssh_exec(nerd_font_cmd)

      # Install tools
      substep "Installing tools..."
      ssh_exec("DEBIAN_FRONTEND=noninteractive apt install -y #{PACKAGES[:tools].join(' ')}", sudo: true)

      # Set zsh as default shell
      substep "Setting zsh as default shell..."
      ssh_exec("apt install -y zsh", sudo: true)
      ssh_exec("chsh -s /bin/zsh #{@options[:ssh_user]}", sudo: true)

      # Clean up
      substep "Cleaning up..."
      ssh_exec("apt autoremove -y && apt clean", sudo: true)

      success "Base provisioning complete"
    end

    def install_dotfiles
      step "Installing dotfiles..."

      repo = @options[:dotfiles_repo]

      # Clone dotfiles
      substep "Cloning #{repo}..."
      ssh_exec("git clone #{repo} ~/dotfiles")

      # Run bootstrap.sh if it exists
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

    def prepare_for_cloning
      step "Preparing for cloning..."

      # Truncate machine-id so each clone gets unique ID
      substep "Truncating machine-id..."
      ssh_exec("truncate -s 0 /etc/machine-id", sudo: true)

      # Clear SSH host keys (regenerate on first boot of each clone)
      substep "Clearing SSH host keys..."
      ssh_exec("rm -f /etc/ssh/ssh_host_*", sudo: true)

      # Clear bash history
      substep "Clearing history..."
      ssh_exec("cat /dev/null > ~/.bash_history")
      ssh_exec("cat /dev/null > ~/.zsh_history 2>/dev/null || true")

      success "Ready for cloning"
    end

    def finalize
      step "Finalizing..."

      # Shutdown the VM
      substep "Shutting down VM..."
      ssh_exec("shutdown -h now", sudo: true)

      # Wait for shutdown
      10.times do
        status = `utmctl status #{@vm_name} 2>/dev/null`.strip.downcase
        break if status.include?('stopped')
        sleep 2
      end

      # Rename VM if it was a source VM
      if @source_vm && @source_vm != @base_name
        substep "Renaming #{@source_vm} -> #{@base_name}..."

        source_path = "#{UTM_DOCS}/#{@source_vm}.utm"
        target_path = "#{UTM_DOCS}/#{@base_name}.utm"

        if File.exist?(source_path)
          # Delete from UTM first
          system("utmctl delete #{@source_vm} 2>/dev/null")
          sleep 1

          # Rename on disk
          FileUtils.mv(source_path, target_path)

          # Update plist
          plist = "#{target_path}/config.plist"
          if File.exist?(plist)
            content = File.read(plist)
            content.gsub!(/<key>Name<\/key>\s*<string>[^<]+<\/string>/,
                          "<key>Name</key>\n\t\t<string>#{@base_name}</string>")
            File.write(plist, content)
          end

          # Re-register with UTM
          system("open -a UTM '#{target_path}'")
          sleep 2
        end
      end

      # Update config file
      update_config

      success "Base image ready: #{@base_name}"
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

      File.write(CONFIG_FILE, JSON.pretty_generate(config))
      success "Updated config: #{CONFIG_FILE}"
    end
  end

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

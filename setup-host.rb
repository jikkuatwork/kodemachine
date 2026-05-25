#!/usr/bin/env ruby
# frozen_string_literal: true

# Kodemachine Host Setup
# Installs dependencies on macOS (UTM) or Linux (libvirt/KVM)

require 'fileutils'

module KodemachineSetup
  VERSION = "1.0.0"

  COLORS = {
    red:    "\e[31m",
    green:  "\e[32m",
    yellow: "\e[33m",
    blue:   "\e[34m",
    reset:  "\e[0m"
  }.freeze

  class << self
    def run
      puts banner

      if RUBY_PLATFORM.include?('darwin')
        MacosSetup.new.run
      elsif RUBY_PLATFORM.include?('linux')
        LinuxSetup.new.run
      else
        error "Unsupported platform: #{RUBY_PLATFORM}"
        exit 1
      end
    end

    def banner
      <<~BANNER
        #{COLORS[:blue]}╔════════════════════════════════════════╗
        ║     Kodemachine Host Setup v#{VERSION}      ║
        ╚════════════════════════════════════════╝#{COLORS[:reset]}
      BANNER
    end
  end

  # Shared helpers
  module Helpers
    def step(msg)
      puts "#{COLORS[:blue]}==>#{COLORS[:reset]} #{msg}"
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

    def create_config_dir
      step "Creating config directory..."
      config_dir = File.expand_path("~/.config/kodemachine")

      if File.exist?(config_dir)
        success "Config directory exists: #{config_dir}"
      else
        FileUtils.mkdir_p(config_dir)
        success "Created: #{config_dir}"
      end
    end

    def setup_symlink
      step "Setting up kodemachine command..."

      script_dir = File.dirname(File.expand_path(__FILE__))
      kodemachine_rb = File.join(script_dir, "kodemachine.rb")
      target = "/usr/local/bin/kodemachine"

      unless File.exist?(kodemachine_rb)
        warn "kodemachine.rb not found in #{script_dir}"
        return
      end

      File.chmod(0755, kodemachine_rb)

      if File.symlink?(target)
        current = File.readlink(target)
        if current == kodemachine_rb
          success "Symlink already correct: #{target}"
          return
        else
          warn "Updating symlink (was: #{current})"
          if File.writable?(File.dirname(target))
            FileUtils.rm(target)
          elsif $stdin.tty?
            system("sudo", "rm", "-f", target)
          end
        end
      elsif File.exist?(target)
        warn "#{target} exists but is not a symlink. Skipping."
        puts "  Remove it manually if you want to use the symlink."
        return
      end

      bin_dir = File.dirname(target)
      unless File.exist?(bin_dir)
        system("sudo", "mkdir", "-p", bin_dir)
      end

      system_link_created = if File.writable?(bin_dir)
        system("ln", "-sf", kodemachine_rb, target)
      elsif $stdin.tty?
        system("sudo", "ln", "-sf", kodemachine_rb, target)
      else
        false
      end

      if system_link_created
        success "Created symlink: #{target} -> #{kodemachine_rb}"
      else
        user_target = File.expand_path("~/.local/bin/kodemachine")
        FileUtils.mkdir_p(File.dirname(user_target))
        FileUtils.ln_sf(kodemachine_rb, user_target)
        success "Created user symlink: #{user_target} -> #{kodemachine_rb}"

        unless ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).include?(File.dirname(user_target))
          warn "#{File.dirname(user_target)} is not on PATH"
          puts "  Add this to your shell config: export PATH=\"$HOME/.local/bin:$PATH\""
        end
      end
    end
  end

  # ── macOS Setup ────────────────────────────────────────────────────────────

  class MacosSetup
    include Helpers

    def run
      puts

      check_macos
      check_homebrew
      install_utm
      install_qemu_img
      create_config_dir
      setup_symlink

      puts
      puts "#{COLORS[:green]}✅ Host setup complete!#{COLORS[:reset]}"
      puts
      puts "Next steps:"
      puts "  1. Run: ./create-base.rb"
      puts "  2. Or manually create a base image (see README)"
      puts
    end

    private

    def check_macos
      step "Checking macOS..."
      unless RUBY_PLATFORM.include?('darwin')
        error "This setup path only runs on macOS"
        exit 1
      end
      success "Running on macOS"
    end

    def check_homebrew
      step "Checking Homebrew..."
      if system("which brew > /dev/null 2>&1")
        success "Homebrew installed"
      else
        warn "Homebrew not found. Installing..."
        system('/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"')

        if File.exist?("/opt/homebrew/bin/brew")
          ENV['PATH'] = "/opt/homebrew/bin:#{ENV['PATH']}"
        elsif File.exist?("/usr/local/bin/brew")
          ENV['PATH'] = "/usr/local/bin:#{ENV['PATH']}"
        end

        success "Homebrew installed"
      end
    end

    def install_utm
      step "Checking UTM..."
      utm_app = "/Applications/UTM.app"

      if File.exist?(utm_app)
        success "UTM already installed"
        return
      end

      warn "UTM not found. Installing via Homebrew..."
      system("brew install --cask utm")

      if File.exist?(utm_app)
        success "UTM installed"
      else
        error "UTM installation failed"
        puts "  Try manually: brew install --cask utm"
        puts "  Or download from: https://mac.getutm.app/"
        exit 1
      end
    end

    def install_qemu_img
      step "Checking qemu-img..."
      qemu_img = "/opt/homebrew/bin/qemu-img"
      qemu_img = "/usr/local/bin/qemu-img" unless File.exist?(qemu_img)

      if File.exist?(qemu_img)
        success "qemu-img already installed"
        return
      end

      warn "qemu-img not found. Installing via Homebrew..."
      system("brew install qemu")

      if system("which qemu-img > /dev/null 2>&1")
        success "qemu-img installed"
      else
        error "qemu-img installation failed"
        exit 1
      end
    end
  end

  # ── Linux Setup ────────────────────────────────────────────────────────────

  class LinuxSetup
    include Helpers

    def run
      puts

      check_kvm
      check_libvirt
      check_virsh
      check_qemu_img
      check_acl_tools
      check_libvirt_group
      ensure_default_network
      create_storage_pool
      create_shared_disk
      ensure_storage_permissions
      create_config_dir
      setup_symlink

      puts
      puts "#{COLORS[:green]}✅ Host setup complete!#{COLORS[:reset]}"
      puts
      puts "Next steps:"
      puts "  1. Create a base Ubuntu VM in virt-manager (or via virt-install)"
      puts "  2. Run: ./create-base.rb"
      puts "  3. Start using: kodemachine start myproject"
      puts
    end

    private

    def check_kvm
      step "Checking KVM..."
      if File.exist?("/dev/kvm")
        success "KVM available"
      else
        error "KVM not available"
        puts "  Check BIOS: enable AMD-V / Intel VT-x"
        puts "  Verify: egrep -c '(vmx|svm)' /proc/cpuinfo"
        exit 1
      end
    end

    def check_libvirt
      step "Checking libvirt..."
      if libvirt_service_active?
        success "libvirt running"
      elsif system("dpkg -l libvirt-daemon-system > /dev/null 2>&1")
        warn "libvirt installed but not running. Starting..."
        unless start_libvirt_service
          error "Could not start libvirt"
          puts "  Try: sudo systemctl enable --now libvirtd"
          exit 1
        end
        success "libvirt started"
      else
        error "libvirt not installed"
        puts "  Install: sudo apt install -y libvirt-daemon-system libvirt-clients"
        exit 1
      end
    end

    def libvirt_service_active?
      %w[libvirtd virtqemud].any? do |service|
        system("systemctl is-active --quiet #{service} 2>/dev/null")
      end
    end

    def start_libvirt_service
      %w[libvirtd virtqemud].any? do |service|
        system("sudo", "systemctl", "enable", "--now", service)
      end
    end

    def check_virsh
      step "Checking virsh..."
      if system("which virsh > /dev/null 2>&1")
        success "virsh available"
      else
        error "virsh not found"
        puts "  Install: sudo apt install -y libvirt-clients"
        exit 1
      end
    end

    def check_qemu_img
      step "Checking qemu-img..."
      if system("which qemu-img > /dev/null 2>&1")
        success "qemu-img available"
      else
        warn "qemu-img not found. Installing..."
        system("sudo", "apt", "install", "-y", "qemu-utils")
        if system("which qemu-img > /dev/null 2>&1")
          success "qemu-img installed"
        else
          error "qemu-img installation failed"
          exit 1
        end
      end
    end

    def check_acl_tools
      step "Checking ACL tools..."
      if system("which setfacl > /dev/null 2>&1")
        success "setfacl available"
      else
        warn "setfacl not found. Installing acl..."
        system("sudo", "apt", "install", "-y", "acl")
        if system("which setfacl > /dev/null 2>&1")
          success "setfacl installed"
        else
          error "acl installation failed"
          exit 1
        end
      end
    end

    def check_libvirt_group
      step "Checking libvirt group membership..."
      if `groups`.include?('libvirt')
        success "User in libvirt group"
      else
        warn "Adding #{ENV['USER']} to libvirt group..."
        system("sudo", "usermod", "-aG", "libvirt", ENV['USER'])
        puts
        error "Group membership updated — you must log out and back in."
        puts "  Then run this script again."
        exit 1
      end
    end

    def ensure_default_network
      step "Checking default network..."
      output = `virsh -c qemu:///system net-list --all 2>/dev/null`

      if output.include?('default') && output.include?('active')
        success "Default network active"
      elsif output.include?('default')
        warn "Default network inactive. Starting..."
        system("virsh", "-c", "qemu:///system", "net-start", "default")
        system("virsh", "-c", "qemu:///system", "net-autostart", "default")
        success "Default network started"
      else
        error "No default network found"
        puts "  Try: sudo virsh net-define /etc/libvirt/qemu/networks/default.xml"
        puts "       sudo virsh net-start default"
        puts "       sudo virsh net-autostart default"
        exit 1
      end
    end

    def create_storage_pool
      step "Creating kodemachine storage pool..."
      images_dir = storage_images_dir
      FileUtils.mkdir_p(images_dir)

      pool_list = `virsh -c qemu:///system pool-list --all 2>/dev/null`
      if pool_list.include?('kodemachine')
        success "Storage pool exists: #{images_dir}"

        # Ensure pool is active and persistent across reboots.
        unless pool_list.match?(/kodemachine\s+active/)
          system("virsh", "-c", "qemu:///system", "pool-start", "kodemachine")
        end
        system("virsh", "-c", "qemu:///system", "pool-autostart", "kodemachine")
      else
        system("virsh", "-c", "qemu:///system", "pool-define-as",
               "kodemachine", "dir", "--target", images_dir)
        system("virsh", "-c", "qemu:///system", "pool-build", "kodemachine")
        system("virsh", "-c", "qemu:///system", "pool-start", "kodemachine")
        system("virsh", "-c", "qemu:///system", "pool-autostart", "kodemachine")
        success "Storage pool created: #{images_dir}"
      end
    end

    def create_shared_disk
      step "Checking shared disk..."
      shared = File.join(storage_images_dir, "Shared", "projects-luks.qcow2")

      if File.exist?(shared)
        success "Shared disk exists: #{shared}"
        return
      end

      FileUtils.mkdir_p(File.dirname(shared))
      if system("qemu-img", "create", "-f", "qcow2", shared, "64G")
        File.chmod(0660, shared)
        success "Created shared disk: #{shared}"
        puts "  Format it with LUKS from inside a VM before storing projects on it."
      else
        warn "Could not create shared disk: #{shared}"
      end
    end

    def storage_images_dir
      File.expand_path("~/.local/share/kodemachine/images")
    end

    def ensure_storage_permissions
      step "Checking libvirt storage permissions..."
      qemu_user = detect_qemu_user

      unless qemu_user
        warn "Could not detect libvirt QEMU user; skipping ACL setup"
        puts "  If VMs fail to boot with disk permission errors, allow the QEMU user"
        puts "  to traverse #{File.expand_path('~')} and access #{storage_images_dir}."
        return
      end

      home_paths = [
        File.expand_path("~"),
        File.expand_path("~/.local"),
        File.expand_path("~/.local/share"),
        File.expand_path("~/.local/share/kodemachine")
      ].select { |path| File.exist?(path) }

      ok = true
      home_paths.each do |path|
        ok &&= system("setfacl", "-m", "u:#{qemu_user}:x", path)
      end
      ok &&= system("find", storage_images_dir, "-type", "d", "-user", ENV['USER'],
                     "-exec", "setfacl", "-m", "u:#{qemu_user}:rwx", "{}", "+")
      ok &&= system("find", storage_images_dir, "-type", "f", "-user", ENV['USER'],
                     "-exec", "setfacl", "-m", "u:#{qemu_user}:rw", "{}", "+")
      ok &&= system("find", storage_images_dir, "-type", "d", "-user", ENV['USER'],
                     "-exec", "setfacl", "-d", "-m", "u:#{qemu_user}:rwx", "{}", "+")

      if ok
        success "Storage ACLs allow #{qemu_user} to access #{storage_images_dir}"
      else
        warn "Could not fully apply storage ACLs"
        puts "  You may need to run: sudo setfacl -m u:#{qemu_user}:x #{File.expand_path('~')}"
        puts "                    setfacl -R -m u:#{qemu_user}:rwx #{storage_images_dir}"
      end
    end

    def detect_qemu_user
      %w[libvirt-qemu qemu].find do |user|
        system("getent", "passwd", user, out: File::NULL, err: File::NULL)
      end
    end
  end
end

# Run if executed directly
if __FILE__ == $0
  KodemachineSetup.run
end

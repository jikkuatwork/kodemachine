#!/usr/bin/ruby
# frozen_string_literal: true

# Kodemachine Host Setup
# Installs UTM and other host-side dependencies on macOS

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
      puts "  1. Run: kodemachine create-base"
      puts "  2. Or manually create a base image (see README)"
      puts
    end

    private

    def banner
      <<~BANNER
        #{COLORS[:blue]}╔════════════════════════════════════════╗
        ║     Kodemachine Host Setup v#{VERSION}      ║
        ╚════════════════════════════════════════╝#{COLORS[:reset]}
      BANNER
    end

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

    def check_macos
      step "Checking macOS..."
      unless RUBY_PLATFORM.include?('darwin')
        error "This script only runs on macOS"
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

        # Add to PATH for this session
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

      # Make executable
      File.chmod(0755, kodemachine_rb)

      if File.symlink?(target)
        current = File.readlink(target)
        if current == kodemachine_rb
          success "Symlink already correct: #{target}"
          return
        else
          warn "Updating symlink (was: #{current})"
          FileUtils.rm(target)
        end
      elsif File.exist?(target)
        warn "#{target} exists but is not a symlink. Skipping."
        puts "  Remove it manually if you want to use the symlink."
        return
      end

      # Create /usr/local/bin if needed
      bin_dir = File.dirname(target)
      unless File.exist?(bin_dir)
        system("sudo", "mkdir", "-p", bin_dir)
      end

      # Create symlink (may need sudo)
      if system("ln", "-sf", kodemachine_rb, target)
        success "Created symlink: #{target} -> #{kodemachine_rb}"
      else
        warn "Could not create symlink. Try with sudo:"
        puts "  sudo ln -sf #{kodemachine_rb} #{target}"
      end
    end
  end
end

# Run if executed directly
if __FILE__ == $0
  KodemachineSetup.run
end

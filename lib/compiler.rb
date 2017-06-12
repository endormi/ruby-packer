# Copyright (c) 2017 Minqi Pan <pmq2001@gmail.com>
# 
# This file is part of Ruby Compiler, distributed under the MIT License
# For full terms see the included LICENSE file

require "compiler/constants"
require "compiler/error"
require "compiler/utils"
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'pathname'

class Compiler
  def self.ruby_api_version
    @ruby_api_version ||= peek_ruby_api_version
  end
  
  def self.ruby_version
    @ruby_version ||= peek_ruby_version
  end
  
  def self.peek_ruby_version
    version_info = File.read(File.join(PRJ_ROOT, 'ruby/version.h'))
    if version_info =~ /RUBY_VERSION\s+"([^"]+)"\s*$/
      return $1.dup
    else
      raise 'Cannot peek RUBY_VERSION'
    end
  end
  
  def self.peek_ruby_api_version
    version_info = File.read(File.join(PRJ_ROOT, 'ruby/include/ruby/version.h'))
    versions = []
    if version_info =~ /RUBY_API_VERSION_MAJOR\s+(\d+)/
      versions << $1.dup
    else
      raise 'Cannot peek RUBY_API_VERSION_MAJOR'
    end
    if version_info =~ /RUBY_API_VERSION_MINOR\s+(\d+)/
      versions << $1.dup
    else
      raise 'Cannot peek RUBY_API_VERSION_MINOR'
    end
    if version_info =~ /RUBY_API_VERSION_TEENY\s+(\d+)/
      versions << $1.dup
    else
      raise 'Cannot peek RUBY_API_VERSION_TEENY'
    end
    versions.join('.')
  end
  
  def prepare_flags
    @ldflags = ''
    @cflags = ''

    if Gem.win_platform?
      if @options[:debug]
        @cflags += ' /DEBUG:FULL /Od -Zi '
      else
        @cflags += ' /Ox '
      end
    else
      if @options[:debug]
        @cflags += ' -g -O0 -pipe '
      else
        @cflags += ' -O3 -fno-fast-math -ggdb3 -Os -fdata-sections -ffunction-sections -pipe '
      end
    end

    if Gem.win_platform?
      @ldflags += " -libpath:#{Utils.escape File.join(@options[:tmpdir], 'zlib').gsub('/', '\\')} #{Utils.escape File.join(@options[:tmpdir], 'zlib', 'zlib.lib')} "
      @cflags += " -I#{Utils.escape File.join(@options[:tmpdir], 'zlib')} "
    else
      @ldflags += " -L#{Utils.escape File.join(@options[:tmpdir], 'zlib')} #{Utils.escape File.join(@options[:tmpdir], 'zlib', 'libz.a')} "
      @cflags += " -I#{Utils.escape File.join(@options[:tmpdir], 'zlib')} "
      @ldflags += " -L#{Utils.escape File.join(@options[:tmpdir], 'openssl')}  #{Utils.escape File.join(@options[:tmpdir], 'openssl', 'libcrypto.a')} #{Utils.escape File.join(@options[:tmpdir], 'openssl', 'libssl.a')} "
      @cflags += " -I#{Utils.escape File.join(@options[:tmpdir], 'openssl', 'include')} "
      @ldflags += " -L#{Utils.escape File.join(@options[:tmpdir], 'gdbm', 'build', 'lib')} #{Utils.escape File.join(@options[:tmpdir], 'gdbm', 'build', 'lib', 'libgdbm.a')} "
      @cflags += " -I#{Utils.escape File.join(@options[:tmpdir], 'gdbm', 'build', 'include')} "
    end
  end
  
  def initialize(entrance, options = {})
    @entrance = File.expand_path(entrance) if entrance
    @options = options

    check_base_ruby_version!

    init_options
    init_entrance if entrance
    init_tmpdir

    if entrance
      STDERR.puts "Entrance: #{@entrance}"
    else
      STDERR.puts "ENTRANCE was not provided, a single Ruby interpreter executable will be produced."
    end
    STDERR.puts "Options: #{@options}"
    STDERR.puts

    prepare_flags
    stuff_tmpdir
  end

  def init_options
    @options[:make_args] ||= '-j4'
    if Gem.win_platform?
      @options[:output] ||= 'a.exe'
    else
      @options[:output] ||= 'a.out'
    end
    @options[:output] = File.expand_path(@options[:output])
  end

  def init_entrance
    if @options[:root]
      @root = File.expand_path(@options[:root])
    else
      @root = @entrance.dup
      while true
        @root = File.expand_path('..', @root)
        if File.expand_path('..', @root) == @root
          @root = Dir.pwd
          break
        end
        if File.exist?(File.join(@root, 'Gemfile')) || Dir.exist?(File.join(@root, '.git'))
          break 
        end
      end
      STDERR.puts "-> Project root not supplied, #{@root} assumed."
    end
  end

  def init_tmpdir
    @options[:tmpdir] ||= File.expand_path("rubyc", Dir.tmpdir)
    @options[:tmpdir] = File.expand_path(@options[:tmpdir])
    if @root && @options[:tmpdir].include?(@root)
      raise Error, "Tempdir #{@options[:tmpdir]} cannot reside inside #{@root}."
    end
  end
  
  def stuff_zlib
    target = File.join(@options[:tmpdir], 'zlib')
    unless Dir.exist?(target)
      Utils.cp_r(File.join(PRJ_ROOT, 'vendor', 'zlib'), target, preserve: true)
      Utils.chdir(target) do
        if Gem.win_platform?
          Utils.run('nmake /f win32\\Makefile.msc')
        else
          Utils.run('./configure --static')
          Utils.run("make #{@options[:make_args]}")
        end
        Dir['*.{dylib,so,dll}'].each do |thisdl|
          Utils.rm_f(thisdl)
        end
      end
    end
  end

  def stuff_openssl
    target = File.join(@options[:tmpdir], 'openssl')
    unless Dir.exist?(target)
      Utils.cp_r(File.join(PRJ_ROOT, 'vendor', 'openssl'), target, preserve: true)
      Utils.chdir(target) do
        if Gem.win_platform?
          # TODO
        else
          Utils.run('./config')
          Utils.run("make #{@options[:make_args]}")
        end
        Dir['*.{dylib,so,dll}'].each do |thisdl|
          Utils.rm_f(thisdl)
        end
      end
    end
  end
  
  def stuff_gdbm
    target = File.join(@options[:tmpdir], 'gdbm')
    unless Dir.exist?(target)
      Utils.cp_r(File.join(PRJ_ROOT, 'vendor', 'gdbm'), target, preserve: true)
      Utils.chdir(target) do
        if Gem.win_platform?
          # TODO
        else
          Utils.run("./configure --enable-libgdbm-compat --disable-shared --enable-static --without-readline --prefix=#{Utils.escape File.join(@options[:tmpdir], 'gdbm', 'build')}")
          Utils.run("make #{@options[:make_args]}")
          Utils.run("make install")
        end
      end
    end
  end
  
  def stuff_tmpdir
    Utils.rm_rf(@options[:tmpdir]) if @options[:clean]
    Utils.mkdir_p(@options[:tmpdir])

    stuff_zlib
    stuff_openssl
    stuff_gdbm

    target = File.join(@options[:tmpdir], 'ruby')
    unless Dir.exist?(target)
      Utils.cp_r(File.join(PRJ_ROOT, 'ruby'), target, preserve: true)

      # PATCH common.mk
      target = File.join(@options[:tmpdir], 'ruby', 'common.mk')
      target_content = File.read(target)
      found = false
      File.open(target, 'w') do |f|
        target_content.each_line do |line|
          if !found && (line =~ /^INCFLAGS = (.*)$/)
            found = true
            f.puts "INCFLAGS = #{$1} #{@cflags}"
          else
            f.print line
          end
        end
      end
      raise 'Failed to patch INCFLAGS of #{target}' unless found
      
      # PATCH win32\Makefile.sub
      if Gem.win_platform?
        target = File.join(@options[:tmpdir], 'ruby', 'win32', 'Makefile.sub')
        target_content = File.read(target)
        found = false
        File.open(target, 'w') do |f|
          target_content.each_line do |line|
            if !found && (line =~ /^LDFLAGS = (.*)$/)
              found = true
              f.puts "LDFLAGS = #{$1} #{@ldflags}"
            else
              f.print line
            end
          end
        end
        raise 'Failed to patch LDFLAGS of #{target}' unless found
      end
    end

    @vendor_ruby = File.join(@options[:tmpdir], 'ruby')
    if Gem.win_platform?
      # TODO make those win32 ext work
      Utils.chdir(@vendor_ruby) do
        Utils.chdir('ext') do
          Utils.rm_rf('dbm')
          Utils.rm_rf('digest')
          Utils.rm_rf('etc')
          Utils.rm_rf('fiddle')
          Utils.rm_rf('gdbm')
          Utils.rm_rf('mathn')
          Utils.rm_rf('openssl')
          Utils.rm_rf('pty')
          Utils.rm_rf('readline')
          Utils.rm_rf('ripper')
          Utils.rm_rf('socket')
          Utils.rm_rf('win32')
          Utils.rm_rf('win32ole')
        end
      end
    end
  end
  
  def check_base_ruby_version!
    expectation = "ruby #{self.class.ruby_version}"
    got = `ruby -v`
    unless got.include?(expectation)
      msg  = "Please make sure to have installed the correct version of ruby in your environment\n"
      msg += "Expecting #{expectation}; yet got #{got}"
      raise Error, msg
    end
  end
  
  def nmake!
    STDERR.puts "-> Running nmake #{@options[:nmake_args]}"
    pid = spawn("nmake #{@options[:nmake_args]}")
    pid, status = Process.wait2(pid)
    Utils.run(@compile_env, %Q{nmake #{@options[:nmake_args]} -f enc.mk V="0" UNICODE_HDR_DIR="./enc/unicode/9.0.0"  RUBY=".\\miniruby.exe -I./lib -I. " MINIRUBY=".\\miniruby.exe -I./lib -I. " -l libenc})
    Utils.run(@compile_env, %Q{nmake #{@options[:nmake_args]} -f enc.mk V="0" UNICODE_HDR_DIR="./enc/unicode/9.0.0"  RUBY=".\\miniruby.exe -I./lib -I. " MINIRUBY=".\\miniruby.exe -I./lib -I. " -l libtrans})
    Utils.run(@compile_env, "nmake #{@options[:nmake_args]}")
    Utils.run(@compile_env, "nmake install")
  end

  def run!
    Utils.chdir(@vendor_ruby) do
      sep = Gem.win_platform? ? ';' : ':'
      @compile_env = { 'ENCLOSE_IO_USE_ORIGINAL_RUBY' => '1' }
      # enclose_io_memfs.o - 1st pass
      Utils.rm_f('include/enclose_io.h')
      Utils.rm_f('enclose_io_memfs.c')
      Utils.cp(File.join(PRJ_ROOT, 'ruby', 'include', 'enclose_io.h'), File.join(@vendor_ruby, 'include'))
      Utils.cp(File.join(PRJ_ROOT, 'ruby', 'enclose_io_memfs.c'), @vendor_ruby)
      if Gem.win_platform?
        Utils.run(@compile_env, "call win32\\configure.bat \
                                --prefix=#{Utils.escape File.join(@options[:tmpdir], 'ruby', 'build')} \
                                --enable-bundled-libyaml \
                                --enable-debug-env \
                                --disable-install-doc \
                                --with-static-linked-ext")
        nmake!
        # enclose_io_memfs.o - 2nd pass
        Utils.rm('dir.obj')
        Utils.rm('file.obj')
        Utils.rm('io.obj')
        Utils.rm('main.obj')
        Utils.rm('win32/file.obj')
        Utils.rm('win32/win32.obj')
        Utils.rm('ruby.exe')
        Utils.rm('include/enclose_io.h')
        Utils.rm('enclose_io_memfs.c')
        bundle_deploy if @entrance
        make_enclose_io_memfs
        make_enclose_io_vars
        Utils.run(@compile_env, "nmake #{@options[:nmake_args]}")
        Utils.cp('ruby.exe', @options[:output])
      else
        Utils.run(@compile_env.merge({'CFLAGS' => @cflags, 'LDFLAGS' => @ldflags}),
                              "./configure  \
                               --prefix=#{Utils.escape File.join(@options[:tmpdir], 'ruby', 'build')} \
                               --enable-bundled-libyaml \
                               --without-gmp \
                               --disable-dtrace \
                               --enable-debug-env \
                               --with-sitearchdir=no \
                               --with-vendordir=no \
                               --disable-install-rdoc \
                               --with-static-linked-ext")
        Utils.run(@compile_env, "make #{@options[:make_args]}")
        Utils.run(@compile_env, "make install")
        # enclose_io_memfs.o - 2nd pass
        Utils.rm('dir.o')
        Utils.rm('file.o')
        Utils.rm('io.o')
        Utils.rm('main.o')
        Utils.rm('ruby')
        Utils.rm('include/enclose_io.h')
        Utils.rm('enclose_io_memfs.c')
        bundle_deploy if @entrance
        make_enclose_io_memfs
        make_enclose_io_vars
        Utils.run(@compile_env, "make #{@options[:make_args]}")
        Utils.cp('ruby', @options[:output])
      end
    end
  end

  def bundle_deploy
    @work_dir = File.join(@options[:tmpdir], '__work_dir__')
    Utils.rm_rf(@work_dir)
    Utils.mkdir_p(@work_dir)
    
    @work_dir_inner = File.join(@work_dir, '__enclose_io_memfs__')
    Utils.mkdir_p(@work_dir_inner)

    Utils.chdir(@root) do
      gemspecs = Dir['./*.gemspec']
      gemfiles = Dir['./Gemfile']
      if gemspecs.size > 0
        raise 'Multiple gemspecs detected' unless 1 == gemspecs.size
        @pre_prepare_dir = File.join(@options[:tmpdir], '__pre_prepare__')
        Utils.rm_rf(@pre_prepare_dir)
        Utils.cp_r(@root, @pre_prepare_dir)
        Utils.chdir(@pre_prepare_dir) do
          STDERR.puts "-> Detected a gemspec, trying to build the gem"
          Utils.rm_f('./*.gem')
          Utils.run("bundle")
          Utils.run("bundle exec gem build #{Utils.escape gemspecs.first}")
          gems = Dir['./*.gem']
          raise 'gem building failed' unless 1 == gems.size
          the_gem = gems.first
          Utils.run("gem install #{Utils.escape the_gem} --force --local --no-rdoc --no-ri --install-dir #{Utils.escape @gems_dir}")
          if File.exist?(File.join(@gems_dir, "bin/#{@entrance}"))
            @memfs_entrance = "#{MEMFS}/_gems_/bin/#{@entrance}"
          else
            Utils.chdir(File.join(@gems_dir, "bin")) do
              raise Error, "Cannot find entrance #{@entrance}, available entrances are #{ Dir['*'].join(', ') }."
            end
          end
        end
      elsif gemfiles.size > 0
        raise 'Multiple Gemfiles detected' unless 1 == gemfiles.size
        @work_dir_local = File.join(@work_dir_inner, '_local_')
        @chdir_at_startup = '/__enclose_io_memfs__/_local_'
        Utils.cp_r(@root, @work_dir_local)
        Utils.chdir(@work_dir_local) do
          Utils.run('bundle install --deployment')
          if File.exist?(@entrance)
            @memfs_entrance = mempath(@entrance)
          else
            if File.exist?("bin/#{@entrance}")
              @memfs_entrance = "#{MEMFS}/_local_/bin/#{@entrance}"
            else
              Utils.run('bundle install --deployment --binstubs')
              if File.exist?("bin/#{@entrance}")
                @memfs_entrance = "#{MEMFS}/_local_/bin/#{@entrance}"
              else
                Utils.chdir('bin') do
                  raise Error, "Cannot find entrance #{@entrance}, available entrances are #{ Dir['*'].join(', ') }."
                end
              end
            end
          end
        end
      else
        @work_dir_local = File.join(@work_dir_inner, '_local_')
        Utils.cp_r(@root, @work_dir_local)
        Utils.chdir(@work_dir_local) do
          x = Pathname.new @entrance
          y = Pathname.new @root
          if x.absolute?
            raise "Entrance #{@entrance} is not in the project root #{@root}" unless @entrance.include?(@root)
            @entrance = x.relative_path_from y
          end
          if File.exist?("#{@entrance}")
            @memfs_entrance = "#{MEMFS}/_local_/#{@entrance}"
          else
            Utils.chdir('bin') do
              raise Error, "Cannot find entrance #{@entrance}"
            end
          end
        end
      end
      
      if @work_dir_local
        Utils.chdir(@work_dir_local) do
          if Dir.exist?('.git')
            STDERR.puts `git status`
            Utils.rm_rf('.git')
          end
        end
      end
      
      Utils.rm_rf(File.join(@gems_dir, 'cache'))
    end
  end

  def make_enclose_io_memfs
    Utils.chdir(@vendor_ruby) do
      Utils.rm_f('enclose_io_memfs.squashfs')
      Utils.rm_f('enclose_io_memfs.c')
      Utils.run("mksquashfs -version")
      Utils.run("mksquashfs #{Utils.escape @work_dir} enclose_io_memfs.squashfs")
      bytes = IO.binread('enclose_io_memfs.squashfs').bytes
      # TODO slow operation
      # remember to change libsquash's sample/enclose_io_memfs.c as well
      File.open("enclose_io_memfs.c", "w") do |f|
        f.puts '#include <stdint.h>'
        f.puts '#include <stddef.h>'
        f.puts ''
        f.puts "const uint8_t enclose_io_memfs[#{bytes.size}] = { #{bytes[0]}"
        i = 1
        while i < bytes.size
          f.print ','
          f.puts bytes[(i)..(i + 100)].join(',')
          i += 101
        end
        f.puts '};'
        f.puts ''
      end
    end
  end

  def make_enclose_io_vars
    Utils.chdir(@vendor_ruby) do
      File.open("include/enclose_io.h", "w") do |f|
        # remember to change libsquash's sample/enclose_io.h as well
        # might need to remove some object files at the 2nd pass  
        f.puts '#ifndef ENCLOSE_IO_H_999BC1DA'
        f.puts '#define ENCLOSE_IO_H_999BC1DA'
        f.puts ''
        f.puts '#include "enclose_io_prelude.h"'
        f.puts '#include "enclose_io_common.h"'
        f.puts '#include "enclose_io_win32.h"'
        f.puts '#include "enclose_io_unix.h"'
        f.puts ''
        f.puts "#define ENCLOSE_IO_CHDIR_AT_STARTUP #{@chdir_at_startup.inspect}" if @chdir_at_startup
        f.puts "#define ENCLOSE_IO_ENTRANCE #{@memfs_entrance.inspect}" if @entrance
        f.puts '#endif'
        f.puts ''
      end
    end
  end

  def mempath(path)
    path = File.expand_path(path)
    raise "path #{path} should start with #{@root}" unless @root == path[0...(@root.size)]
    "#{MEMFS}/_local_#{path[(@root.size)..-1]}"
  end
end

require "file_utils"

DIR = "#{ENV["HOME"]}/.augment"

class Augment::Builder
  def initialize(@input : IO = STDIN, @output : IO = STDOUT, @error : IO = STDERR)
  end

  # Builds the `augment` binary and the scripts for each command.
  #
  # `build` will attempt to perform the following tasks:
  # 1. Delete the existing `bin` directory
  # 2. Generate the `run.cr` file
  # 3. Build the `augment` binary
  # 4. Clean up extra files (e.g. `augment.dwarf`, `run.cr`)
  # 5. Generate scripts for each command
  #
  # If an error occurs during any of these tasks, a `BuildError` will be
  # raised and the rest of the tasks will not be executed. However, no
  # rollback is performed, which means that some files might already be
  # updated while others are not.
  #
  # Fortunately, the presence of outdated files does not affect any of the
  # tasks above, so a simple rebuild (without errors) should update all the
  # the files appropriately.
  def build(development : Bool = false)
    delete_bin()
    generate_run()
    build_bin(development)
    clean_files(development)
    generate_scripts()
  end

  # Deletes the existing `bin` directory
  #
  # Raises a `BuildError` if the bin directory cannot be deleted.
  private def delete_bin
    begin
      FileUtils.rm_r("#{DIR}/bin")
    rescue exception : Errno
      raise BuildError.new("Failed to delete bin", exception)
    end
  end

  # Generates the `run.cr` file.
  #
  # Raises a `BuildError` if the config file cannot be found or parsed.
  private def generate_run
    begin
      content = File.read("#{DIR}/config")

      content = content.split('\n').map do |line|
        "    #{line}"
      end.join('\n')

      content = "# Generated by Augment

ARGV.insert(0, \"augment\")

begin
  Augment::RootCommand.new.run do
#{content}
  end
rescue exception : Augment::Exception
  STDERR.puts \"Error: \#{exception}\"
end
"

      File.write("#{DIR}/src/augment/run.cr", content)
    rescue exception : Errno
      raise BuildError.new("Failed to generate run.cr", exception)
    end
  end

  # Builds the `augment` binary.
  #
  # Raised a `BuildError` if the build process exits with an error.
  private def build_bin(development : Bool)
    args = ["build"]
    unless development
      args << "--production"
    end

    if development
      output = @output
    else
      output = Process::Redirect::Close
    end

    status = Process.run("shards", args, input: @input, output: output, error: @error, chdir: DIR)
    unless status.normal_exit? && status.exit_code == 0
      raise BuildError.new("Failed to build binary")
    end
  end

  # Cleans up extra files.
  #
  # Raises a `BuildError` if any deletion fails.
  private def clean_files(development : Bool)
    begin
      unless development
        File.delete("#{DIR}/bin/augment.dwarf")
        File.delete("#{DIR}/src/augment/run.cr")
      end
    rescue exception : Errno
      raise BuildError.new("Failed to clean files", exception)
    end
  end

  # Generates scripts for each command.
  #
  # Raises a `BuildError` if any of the generations fail.
  private def generate_scripts
    commands = IO::Memory.new

    status = Process.run("augment", ["list"], input: @input, output: commands, error: @error, chdir: DIR)
    unless status.normal_exit? && status.exit_code == 0
      raise BuildError.new("Failed to list commands")
    end

    begin
      commands.to_s.split('\n').each do |command|
        if command.empty?
          return
        end

        content = "#! /bin/sh

exec augment #{command} \"$@\"
"

        File.write("#{DIR}/bin/#{command}", content)
        File.chmod("#{DIR}/bin/#{command}", 0o755)
      end
    rescue exception : Errno
      raise BuildError.new("Failed to generate scripts", exception)
    end
  end
end

#!/usr/bin/env ruby

require "rexml/document"

module ClaudeEasy
  class InvalidConfigError < StandardError; end unless const_defined?(:InvalidConfigError, false)

  module_function

  def saved_usage_profile(path: nil)
    path ||= usage_profile_state_path
    expanded = File.expand_path(path)
    return nil unless File.exist?(expanded) || File.symlink?(expanded)

    directory = File.dirname(expanded)
    stat = File.lstat(expanded)
    directory_stat = File.lstat(directory)
    raise InvalidConfigError, "用途档位状态无效" unless
      stat.file? && !stat.symlink? && stat.nlink == 1 && (stat.mode & 0o077).zero? &&
      directory_stat.directory? && !directory_stat.symlink?

    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    bytes = File.open(expanded, flags) do |file|
      opened = file.stat
      current = File.lstat(expanded)
      raise InvalidConfigError, "用途档位状态无效" unless
        opened.file? && !current.symlink? && opened.nlink == 1 &&
        (opened.mode & 0o077).zero? &&
        [opened.dev, opened.ino] == [stat.dev, stat.ino] &&
        [current.dev, current.ino] == [stat.dev, stat.ino]

      content = file.read.b
      after = file.stat
      raise InvalidConfigError, "用途档位状态无效" unless
        [after.dev, after.ino, after.size] == [stat.dev, stat.ino, content.bytesize]

      content
    end
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "用途档位状态无效" unless text.valid_encoding?

    document = REXML::Document.new(text)
    doctype = document.doctype
    standard_doctype = doctype.nil? || (
      doctype.name == "plist" &&
      doctype.public == "-//Apple//DTD PLIST 1.0//EN" &&
      doctype.system == "http://www.apple.com/DTDs/PropertyList-1.0.dtd" &&
      doctype.children.empty?
    )
    root = document.root
    root_elements = root&.elements&.to_a || []
    raise InvalidConfigError, "用途档位状态无效" unless
      standard_doctype &&
      root&.name == "plist" && root.attributes.length == 1 &&
      root.attributes["version"] == "1.0" &&
      root_elements.length == 1 && root_elements.first.name == "dict" &&
      root_elements.first.attributes.empty?

    fields = {}
    elements = root_elements.first.elements.to_a
    raise InvalidConfigError, "用途档位状态无效" unless elements.length == 4

    elements.each_slice(2) do |key_element, value_element|
      key = key_element.text.to_s
      value = value_element.text.to_s.strip
      raise InvalidConfigError, "用途档位状态无效" unless
        key_element.name == "key" && value_element.name == "integer" &&
        key_element.attributes.empty? && value_element.attributes.empty? &&
        key_element.elements.to_a.empty? && value_element.elements.to_a.empty? &&
        key_element.children.length == 1 && value_element.children.length == 1 &&
        key_element.children.first.is_a?(REXML::Text) &&
        value_element.children.first.is_a?(REXML::Text) &&
        %w[Version Profile].include?(key) && !fields.key?(key) &&
        value.match?(/\A(?:0|[1-9][0-9]*)\z/)

      fields[key] = value
    end
    raise InvalidConfigError, "用途档位状态无效" unless
      fields == { "Version" => "1", "Profile" => fields["Profile"] } &&
      %w[1 2 3].include?(fields["Profile"])

    fields.fetch("Profile").to_i
  rescue SystemCallError, IOError, REXML::ParseException
    raise InvalidConfigError, "用途档位状态无效"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    profile = ClaudeEasy.saved_usage_profile(path: ARGV.fetch(0))
    exit 1 unless profile

    puts profile
  rescue ClaudeEasy::InvalidConfigError, IndexError
    exit 2
  end
end

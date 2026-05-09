require 'English'
require 'test_helper'
require 'bundler'

class Workhorse::YjitTest < ActiveSupport::TestCase
  YJIT_CHECK_SCRIPT = <<~RUBY.freeze
    require 'bundler/setup'
    require 'workhorse'
    RubyVM::YJIT.enable
    print RubyVM::YJIT.enabled?
  RUBY

  def test_yjit_not_enabled_when_ruby_yjit_enable_is_zero
    skip 'RubyVM::YJIT.enable not available' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)

    # Sanity check: YJIT can actually be enabled in this environment
    without_env = run_ruby_script(YJIT_CHECK_SCRIPT, 'RUBY_YJIT_ENABLE' => nil)
    skip 'YJIT cannot be enabled in this environment' unless without_env == 'true'

    # With RUBY_YJIT_ENABLE=0, RubyVM::YJIT.enable should be a no-op
    with_env = run_ruby_script(YJIT_CHECK_SCRIPT, 'RUBY_YJIT_ENABLE' => '0')
    assert_equal 'false', with_env, 'YJIT should not be enabled when RUBY_YJIT_ENABLE=0'
  end

  private

  def run_ruby_script(script, env = {})
    output = nil
    Bundler.with_unbundled_env do
      IO.popen(env, %w[bundle exec ruby -e] + [script], chdir: Rails.root.to_s, err: %i[child out]) do |io|
        output = io.read.strip
      end
    end
    assert $CHILD_STATUS.success?, "Ruby subprocess failed (exit #{$CHILD_STATUS.exitstatus}): #{output}"
    output
  end
end

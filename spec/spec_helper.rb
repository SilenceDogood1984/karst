# frozen_string_literal: true

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.raise_errors_for_deprecations!
  config.order = :random
  Kernel.srand config.seed
end

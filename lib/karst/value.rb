# frozen_string_literal: true

module Karst
  # Small immutable value-object helper standing in for Ruby 3.2's
  # Data.define, which Karst cannot rely on while supporting Ruby 2.7. Built
  # on Struct(keyword_init: true), which already provides structural
  # equality, keyword construction, and #members; the one thing Struct does
  # not give for free is immutability, so .define freezes every instance its
  # class produces. This matches Data's own contract exactly: the instance
  # itself is frozen, but a member holding a mutable object (an Array, say)
  # is not deep-frozen -- Data.define does not do that either, and Karst does
  # not need it to.
  module Value
    # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- anonymous
    # block forwarding (`&`) needs Ruby 3.1; this file runs on Ruby 2.7.
    def self.define(*members, &block)
      klass = Struct.new(*members, keyword_init: true, &block)
      # rubocop:enable Naming/BlockForwarding, Style/ArgumentsForwarding

      # Struct.new itself is a heavily overloaded class method (it doubles as
      # the anonymous-subclass factory), so overriding it and calling super
      # would climb straight past Struct's own keyword-init handling into
      # that factory instead of a plain constructor. Overriding the ordinary
      # instance method #initialize has no such trap.
      klass.class_eval do
        def initialize(...)
          super
          freeze
        end
      end

      klass
    end
  end
end

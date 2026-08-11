# frozen_string_literal: true

require "ripper"
require_relative "../value"

module Karst
  module Access
    # Finds zero-argument Rails scope declarations by parsing model source.
    # Ripper is part of Ruby's standard library (including Ruby 2.7), so this
    # does not raise Karst's minimum Ruby version or add a parser dependency.
    # Discovery never calls a scope or any other model method.
    class PopulationDiscovery
      FRAMEWORK_NAMESPACES = %w[ActiveRecord ActiveStorage ActionText ActionMailbox].freeze

      Candidate = Value.define(:model_name, :method_name, :principal_source)

      ModelGroup = Value.define(:model_name, :candidate_names, :principal_source) do
        def candidates
          candidate_names.map do |method_name|
            Candidate.new(model_name: model_name, method_name: method_name, principal_source: principal_source)
          end
        end
      end

      Result = Value.define(:model_groups, :load_warning) do
        def candidates
          model_groups.flat_map(&:candidates)
        end
      end

      def call
        Result.new(model_groups: model_groups, load_warning: @load_warning)
      end

      private

      def model_groups
        candidate_models.filter_map do |klass|
          names = scope_names(klass)
          next if names.empty?

          ModelGroup.new(model_name: klass.name, candidate_names: names,
                         principal_source: principal_source_for(klass))
        end.sort_by(&:model_name)
      end

      def eager_load_application!
        return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        Rails.application.eager_load!
      rescue StandardError => e
        @load_warning = "The application could not be fully loaded (#{e.class}: #{e.message}); " \
                        "discovery may be missing some models."
      end

      def candidate_models
        @candidate_models ||= begin
          eager_load_application!
          if defined?(ActiveRecord::Base)
            ActiveRecord::Base.descendants.select { |klass| application_model?(klass) }.uniq
          else
            []
          end
        end
      end

      def application_model?(klass)
        klass.name && !klass.abstract_class? && !framework_model?(klass)
      end

      def framework_model?(klass)
        FRAMEWORK_NAMESPACES.any? { |namespace| klass.name == namespace || klass.name.start_with?("#{namespace}::") }
      end

      def scope_names(klass)
        file, = Object.const_source_location(klass.name)
        return [] unless file && File.file?(file)

        SourceScopes.new(File.read(file), klass.name).call
      rescue StandardError
        []
      end

      def principal_source_for(klass)
        principal_source_klasses.each { |name, source_klass| return name if source_klass == klass }
        nil
      end

      def principal_source_klasses
        sources = Karst.config.principal_sources || {}
        @principal_source_klasses ||= sources.each_with_object({}) do |(name, source), memo|
          klass = source.record_klass
          memo[name] = klass if klass
        end
      end

      # A deliberately small Ripper AST reader. It recognizes only literal
      # names and the two callable forms accepted here: -> {} and lambda {}.
      # rubocop:disable Metrics/ClassLength
      class SourceScopes
        def initialize(source, model_name)
          @tree = Ripper.sexp(source)
          @model_name = model_name
        end

        def call
          return [] unless @tree

          find_classes(@tree, []).uniq.sort
        end

        private

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def find_classes(node, namespace)
          return [] unless node.is_a?(Array)

          case node[0]
          when :module
            name = constant_name(node[1])
            find_classes(node[2], qualify(namespace, name))
          when :class
            name = constant_name(node[1])
            full_name = qualify(namespace, name)
            direct = full_name.join("::") == @model_name ? scopes_in_body(node[3]) : []
            direct + find_classes(node[3], full_name)
          else
            node.flat_map { |child| find_classes(child, namespace) }
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def qualify(namespace, name)
          return namespace unless name
          return name.split("::") if name.include?("::")

          namespace + [name]
        end

        def constant_name(node)
          return unless node.is_a?(Array)
          return node[1] if node[0] == :@const
          return constant_name(node[1]) if %i[const_ref top_const_ref].include?(node[0])

          [constant_name(node[1]), constant_name(node[2])].compact.join("::") if node[0] == :const_path_ref
        end

        def scopes_in_body(body)
          statements = body && body[0] == :bodystmt ? body[1] : []
          Array(statements).filter_map { |statement| scope_name(statement) }
        end

        def scope_name(node)
          arguments = scope_arguments(node)
          return unless arguments && arguments.length >= 2
          return unless zero_argument_callable?(arguments[1])

          literal_name(arguments[0])
        end

        def scope_arguments(node)
          return unless node.is_a?(Array)

          return unless scope_call?(node)

          argument_list(node[2])
        end

        def scope_call?(node)
          (node[0] == :command && identifier(node[1]) == "scope") ||
            (node[0] == :method_add_arg && fcall_name(node[1]) == "scope")
        end

        def argument_list(node)
          node = node[1] if node && node[0] == :arg_paren
          node && node[0] == :args_add_block ? node[1] : nil
        end

        def fcall_name(node)
          node = node[1] if node && node[0] == :method_add_arg
          identifier(node[1]) if node && node[0] == :fcall
        end

        def identifier(node)
          node[1] if node && %i[@ident @op].include?(node[0])
        end

        def literal_name(node)
          return unless node

          case node[0]
          when :symbol_literal then simple_symbol(node)
          when :dyna_symbol, :string_literal then static_string(node[1])&.to_sym
          end
        end

        def simple_symbol(node)
          token = node.dig(1, 1)
          token[1].to_sym if token && token[0].to_s.start_with?("@")
        end

        def static_string(node)
          return unless node && node[0] == :string_content

          tokens = node.drop(1)
          return unless tokens.all? { |token| token[0] == :@tstring_content }

          tokens.map { |token| token[1] }.join
        end

        def zero_argument_callable?(node)
          if node && node[0] == :lambda
            empty_params?(node[1])
          elsif lambda_block?(node)
            block = node[2]
            empty_params?(block[1])
          else
            false
          end
        end

        def lambda_block?(node)
          node && node[0] == :method_add_block && fcall_name(node[1]) == "lambda" &&
            %i[brace_block do_block].include?(node[2]&.first)
        end

        def empty_params?(node)
          return true if node.nil?

          node = node[1] if node[0] == :paren
          node && node[0] == :params && node.drop(1).all?(&:nil?)
        end
      end
      # rubocop:enable Metrics/ClassLength
      private_constant :SourceScopes
    end
  end
end

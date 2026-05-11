# frozen_string_literal: true

require_relative "../ast/node"

module JsxRosetta
  module IR
    # Heuristic classifier that labels a module whose top-level shape
    # isn't a function component. Used by Lowering::no_component_error
    # to produce triage-friendly messages explaining *why* a file didn't
    # translate. Pure function: program in, label symbol out — no
    # mutable state, no relationship to the rest of the lowering
    # pipeline.
    #
    # Labels (in priority order — more specific shapes win):
    #   :class_component    `class X extends React.Component { ... }`
    #   :hoc_wrapped        `const X = React.memo(...)` etc.
    #   :columns_data       top-level array literal export
    #   :hooks_only         every export is a `use*` hook
    #   :utils_only         every export is a lowercase non-hook helper
    #   :mixed_exports      mixes hooks + non-hook lowercase exports
    #   :side_effects_only  top-level expression statements, no exports
    #   :types_only         types/constants only, no functions
    #   :unknown            no signal — caller emits the bare error
    class ModuleShapeClassifier
      EXPORT_TYPES = %w[ExportNamedDeclaration ExportDefaultDeclaration].freeze
      HOC_NAMES = %w[memo forwardRef lazy observer].freeze

      def self.classify(program)
        new(program).classify
      end

      def initialize(program)
        @program = program
      end

      def classify
        ast_shape = classify_ast_shape
        return ast_shape if ast_shape

        classify_by_export_names(top_level_export_names)
      end

      private

      def classify_ast_shape
        return :class_component if @program.body.any? { |stmt| class_component?(stmt) }
        return :hoc_wrapped if @program.body.any? { |stmt| hoc_wrapped_export?(stmt) }
        return :columns_data if @program.body.any? { |stmt| array_literal_export?(stmt) }

        nil
      end

      def classify_by_export_names(names)
        export_label = classify_by_export_pattern(names)
        return export_label if export_label

        classify_non_export_module
      end

      def classify_by_export_pattern(names)
        any_hooks = names.any? { |n| hook_name?(n) }
        any_helpers = names.any? { |n| /\A[a-z]/.match?(n) && !hook_name?(n) }
        return :mixed_exports if any_hooks && any_helpers
        return :hooks_only if any_hooks
        return :utils_only if any_helpers

        nil
      end

      def classify_non_export_module
        return :side_effects_only if @program.body.any? { |s| side_effect_statement?(s) }
        return :types_only if top_level_has_anything?

        :unknown
      end

      def hook_name?(name)
        name.start_with?("use") && name.length > 3 && name[3] == name[3].upcase
      end

      def class_component?(stmt)
        decl = stmt.of_type?(*EXPORT_TYPES) ? stmt[:declaration] : stmt
        AST::Node.matches?(decl, "ClassDeclaration")
      end

      # Recognize `export const X = React.memo(...)` (export wrapper) or a
      # top-level `const X = lazy(() => ...)` followed by `export default X`
      # — a VariableDeclaration whose init is a CallExpression to a known HOC.
      def hoc_wrapped_export?(stmt)
        decl = stmt.of_type?(*EXPORT_TYPES) ? stmt[:declaration] : stmt
        return false unless AST::Node.matches?(decl, "VariableDeclaration")

        decl[:declarations].any? do |d|
          init = d[:init]
          AST::Node.matches?(init, "CallExpression") && hoc_callee?(init[:callee])
        end
      end

      def hoc_callee?(callee)
        return false unless callee.is_a?(AST::Node)

        case callee.type
        when "Identifier" then HOC_NAMES.include?(callee[:name])
        when "MemberExpression"
          property = callee.child(:property)
          property&.of_type?("Identifier") && HOC_NAMES.include?(property[:name])
        else false
        end
      end

      def array_literal_export?(stmt)
        return false unless stmt.of_type?(*EXPORT_TYPES)

        decl = stmt[:declaration]
        return true if AST::Node.matches?(decl, "ArrayExpression")
        return false unless AST::Node.matches?(decl, "VariableDeclaration")

        decl[:declarations].any? { |d| AST::Node.matches?(d[:init], "ArrayExpression") }
      end

      def side_effect_statement?(stmt)
        AST::Node.matches?(stmt, "ExpressionStatement")
      end

      def top_level_has_anything?
        @program.body.any? { |stmt| stmt.is_a?(AST::Node) && !stmt.of_type?("ImportDeclaration") }
      end

      def top_level_export_names
        @program.body.flat_map { |stmt| extract_top_level_names(stmt) }.compact
      end

      def extract_top_level_names(stmt)
        case stmt.type
        when "FunctionDeclaration"
          [stmt.child(:id)&.[](:name)]
        when "VariableDeclaration"
          stmt[:declarations].map { |d| AST::Node.matches?(d[:id], "Identifier") ? d[:id][:name] : nil }
        when "ExportNamedDeclaration", "ExportDefaultDeclaration"
          decl = stmt.child(:declaration)
          decl ? extract_top_level_names(decl) : []
        else
          []
        end
      end
    end
  end
end

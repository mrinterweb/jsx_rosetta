# frozen_string_literal: true

module JsxRosetta
  module IR
    # When a shadcn TSX wraps a Radix primitive like
    # `<SeparatorPrimitive.Root orientation="horizontal" />`, the translator
    # has historically lowered it to a `ComponentInvocation` whose name is
    # the member chain (`"SeparatorPrimitive.Root"`) — which emits as
    # `render SeparatorPrimitive::Root.new(...)`, an undefined-constant
    # NameError at render time.
    #
    # The shapes underneath are stable enough across Radix that we can map
    # the common (LocalImportName, MemberName) pairs to plain HTML elements
    # plus any always-applied attributes. The mapping is keyed on the LOCAL
    # binding name shadcn uses by convention (e.g. `SeparatorPrimitive`),
    # which matches the import-aliasing pattern in every shadcn fork I've
    # surveyed. Unknown pairs fall through to the existing ComponentInvocation
    # / TODO behavior so consumers can hand-shim primitives we don't cover.
    #
    # Source specifiers that count as "Radix" — both the `radix-ui` umbrella
    # package and the older `@radix-ui/react-*` per-primitive packages.
    RADIX_SOURCE_PATTERN = %r{\A(?:radix-ui|@radix-ui/react-[\w-]+)\z}

    module RadixRegistry
      # Each entry maps [LocalImportName, MemberName] →
      #   { tag: <html-tag>, attrs: { <fixed kwarg name> => <value> } }
      # The `attrs` are merged into the element's lowered attributes (the
      # consumer's own kwargs win on conflict — see `merge_radix_attrs`).
      MAP = {
        # Separator / Label / Avatar / Switch primitives — the shapes we hit
        # most often in the bulk shadcn translation pass.
        %w[SeparatorPrimitive Root] => { tag: "div", attrs: { role: "separator" } },
        %w[LabelPrimitive Root] => { tag: "label", attrs: {} },
        %w[AvatarPrimitive Root] => { tag: "span", attrs: {} },
        %w[AvatarPrimitive Image] => { tag: "img", attrs: {} },
        %w[AvatarPrimitive Fallback] => { tag: "span", attrs: {} },
        %w[SwitchPrimitive Root] => { tag: "button", attrs: { type: "button", role: "switch" } },
        %w[SwitchPrimitive Thumb] => { tag: "span", attrs: {} },
        %w[ProgressPrimitive Root] => { tag: "div", attrs: { role: "progressbar" } },
        %w[ProgressPrimitive Indicator] => { tag: "div", attrs: {} },
        # Aspect-ratio + scroll-area roots are presentational containers.
        %w[AspectRatioPrimitive Root] => { tag: "div", attrs: {} },
        %w[ScrollAreaPrimitive Root] => { tag: "div", attrs: {} },
        %w[ScrollAreaPrimitive Viewport] => { tag: "div", attrs: {} }
      }.freeze

      def self.lookup(local_name, member)
        MAP[[local_name, member]]
      end
    end
  end
end

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

    # Local binding names that resolve to Radix's `Slot` primitive.
    # Matches `Slot` (shadcn-v4 umbrella) and `SlotPrimitive` (older
    # convention). Anything looser would silently drop user-defined
    # components whose names happen to start with "Slot".
    SLOT_LOCAL_NAME_PATTERN = /\ASlot(?:Primitive)?\z/

    module RadixRegistry
      # Each entry maps [PrimitiveBaseName, MemberName] →
      #   { tag: <html-tag>, attrs: { <fixed kwarg name> => <value> } }
      # The `attrs` are merged into the element's lowered attributes (the
      # consumer's own kwargs win on conflict — see `merge_radix_attrs`).
      #
      # `PrimitiveBaseName` is the *canonical* Radix primitive name
      # (e.g. `Separator`); the lookup strips an optional `Primitive` suffix
      # from the consumer's local binding before keying in, so both shadcn-v3
      # (`import { Separator as SeparatorPrimitive } from "radix-ui"`) and
      # shadcn-v4 (`import { Separator } from "radix-ui"`) umbrella idioms
      # resolve. Namespace imports (`import * as SeparatorPrimitive from
      # "@radix-ui/react-separator"`) also strip the suffix.
      MAP = {
        # Separator / Label / Avatar / Switch primitives — the shapes we hit
        # most often in the bulk shadcn translation pass.
        %w[Separator Root] => { tag: "div", attrs: { role: "separator" } },
        %w[Label Root] => { tag: "label", attrs: {} },
        %w[Avatar Root] => { tag: "span", attrs: {} },
        %w[Avatar Image] => { tag: "img", attrs: {} },
        %w[Avatar Fallback] => { tag: "span", attrs: {} },
        %w[Switch Root] => { tag: "button", attrs: { type: "button", role: "switch" } },
        %w[Switch Thumb] => { tag: "span", attrs: {} },
        %w[Progress Root] => { tag: "div", attrs: { role: "progressbar" } },
        %w[Progress Indicator] => { tag: "div", attrs: {} },
        # Aspect-ratio + scroll-area roots are presentational containers.
        %w[AspectRatio Root] => { tag: "div", attrs: {} },
        %w[ScrollArea Root] => { tag: "div", attrs: {} },
        %w[ScrollArea Viewport] => { tag: "div", attrs: {} },
        # Tabs primitives — `data-orientation` comes from the JSX attrs;
        # role=tablist on List + role=tab on Trigger + role=tabpanel on Content.
        %w[Tabs Root] => { tag: "div", attrs: {} },
        %w[Tabs List] => { tag: "div", attrs: { role: "tablist" } },
        %w[Tabs Trigger] => { tag: "button", attrs: { type: "button", role: "tab" } },
        %w[Tabs Content] => { tag: "div", attrs: { role: "tabpanel" } },
        # Toggle / ToggleGroup — pressable buttons.
        %w[Toggle Root] => { tag: "button", attrs: { type: "button" } },
        %w[ToggleGroup Root] => { tag: "div", attrs: { role: "group" } },
        %w[ToggleGroup Item] => { tag: "button", attrs: { type: "button" } },
        # Collapsible — presentational containers; the open/closed state is
        # data-state driven by the consumer (Stimulus or otherwise).
        %w[Collapsible Root] => { tag: "div", attrs: {} },
        %w[Collapsible Trigger] => { tag: "button", attrs: { type: "button" } },
        %w[Collapsible Content] => { tag: "div", attrs: {} }
      }.freeze

      # Strip an optional `Primitive` suffix from the local binding so the
      # registry's canonical names match both umbrella imports (`Separator`)
      # and the older convention (`SeparatorPrimitive`).
      def self.lookup(local_name, member)
        MAP[[local_name, member]] || MAP[[local_name.sub(/Primitive\z/, ""), member]]
      end
    end
  end
end

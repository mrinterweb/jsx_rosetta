# frozen_string_literal: true

class ButtonComponent < ::ViewComponent::Base
  def initialize(children: nil, on_click: nil, variant: "primary")
    @children = children
    @on_click = on_click
    @variant = variant
  end
end

# frozen_string_literal: true

class ButtonComponent < ::ViewComponent::Base
  def initialize(on_click: nil, variant: "primary")
    @on_click = on_click
    @variant = variant
  end
end

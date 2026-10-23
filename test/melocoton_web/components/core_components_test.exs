defmodule MelocotonWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import MelocotonWeb.CoreComponents

  alias MelocotonWeb.CoreComponents

  describe "contrast_foreground/1" do
    test "chooses readable text for light and dark environment colors" do
      for color <- ["#22c55e", "#f59e0b", "#0891b2", "#ffffff", "#fff"] do
        assert CoreComponents.contrast_foreground(color) == "#000000"
      end

      for color <- ["#000000", "#000", "#1e293b", "#7c3aed"] do
        assert CoreComponents.contrast_foreground(color) == "#ffffff"
      end
    end

    test "maintains at least 4.5:1 contrast across the grayscale range" do
      for channel <- 0..255 do
        hex = channel |> Integer.to_string(16) |> String.pad_leading(2, "0")
        color = "#" <> String.duplicate(hex, 3)
        value = channel / 255

        luminance =
          if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)

        contrast =
          case CoreComponents.contrast_foreground(color) do
            "#000000" -> (luminance + 0.05) / 0.05
            "#ffffff" -> 1.05 / (luminance + 0.05)
          end

        assert contrast >= 4.5, "Insufficient contrast for #{color}"
      end
    end

    test "handles invalid or missing colors without raising" do
      for color <- [nil, "", "red", "#gggggg", "#12345"] do
        assert CoreComponents.contrast_foreground(color) == "#000000"
      end
    end
  end

  describe "modal/1" do
    test "opening preserves the flex layout needed for content scrolling" do
      assert ["show", options] =
               Enum.find(show_modal("settings-modal").ops, fn
                 ["show", %{to: "#settings-modal-container"}] -> true
                 _ -> false
               end)

      assert options.display == "flex"
    end

    test "bounds the panel height and scrolls its content below a fixed header" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.modal id="settings-modal" title="Settings">
          Settings content
        </.modal>
        """)

      assert html =~ "max-h-[calc(100dvh-2rem)]"
      assert html =~ "flex shrink-0 items-center justify-between"
      assert html =~ ~s(id="settings-modal-content" class="min-h-0 overflow-y-auto")
      assert html =~ "Settings content"
    end
  end

  describe "sql_block/1" do
    test "wraps SQL in the shared ai-sql-block container" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sql_block sql="SELECT 1" />
        """)

      assert html =~ ~s(class="ai-sql-block rounded overflow-hidden text-xs")
    end

    test "renders the SQL content through MDEx (tokens are highlighted)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sql_block sql="SELECT id FROM users" />
        """)

      # MDEx wraps code fences in <pre><code>...
      assert html =~ "<pre"
      assert html =~ "<code"
      # Identifiers from the SQL still appear in the output
      assert html =~ "SELECT"
      assert html =~ "users"
    end

    test "accepts a custom class override" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sql_block sql="SELECT 1" class="text-[10px]" />
        """)

      assert html =~ ~s(class="ai-sql-block rounded overflow-hidden text-[10px]")
      refute html =~ "text-xs"
    end
  end
end

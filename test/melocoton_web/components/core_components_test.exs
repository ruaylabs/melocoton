defmodule MelocotonWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import MelocotonWeb.CoreComponents

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

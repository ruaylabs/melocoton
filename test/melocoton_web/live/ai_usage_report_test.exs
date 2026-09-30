defmodule MelocotonWeb.AiUsageReportTest do
  use MelocotonWeb.ConnCase

  import Phoenix.LiveViewTest
  import Melocoton.DatabasesFixtures

  alias Melocoton.Databases

  test "palette opens the lazy-loaded usage modal", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/databases")
    refute has_element?(view, "#ai-usage-filters")
    render_hook(view, "open-command-palette", %{})
    view |> element("#command-palette-item-ai_usage") |> render_click()
    assert_push_event(view, "open-ai-usage-modal", %{})
    assert has_element?(view, "#ai-usage-modal #ai-usage-filters")
    refute has_element?(view, "#command-palette-input")
  end

  test "report excludes missing costs while retaining zero-cost responses" do
    database = database_fixture()
    {:ok, chat} = Databases.get_or_create_active_chat(database.id)

    attrs = %{
      role: "assistant",
      content: "SELECT 1;",
      database_id: database.id,
      chat_id: chat.id,
      provider: "openai",
      model: "test-model",
      total_tokens: 120
    }

    {:ok, _} = Databases.create_chat_message(attrs)
    assert Databases.ai_usage_report(database_id: database.id) == []

    for cost <- ["0", "0.03"] do
      assert {:ok, _} = Databases.create_chat_message(Map.put(attrs, :total_cost, cost))
    end

    [row] = Databases.ai_usage_report(database_id: database.id)
    assert row.messages == 2
    assert row.total_tokens == 240
    assert Decimal.equal?(row.total_cost, "0.03")
  end

  test "persisted usage is reported and date filters still work", %{conn: conn} do
    database = database_fixture()
    {:ok, chat} = Databases.get_or_create_active_chat(database.id)

    {:ok, _} =
      Databases.create_chat_message(%{
        role: "assistant",
        content: "SELECT 1;",
        database_id: database.id,
        chat_id: chat.id,
        provider: "openai",
        model: "test-model",
        input_tokens: 100,
        output_tokens: 20,
        total_tokens: 120,
        total_cost: "0.03"
      })

    {:ok, view, _} = live(conn, ~p"/databases")
    render_hook(view, "open-ai-usage-report", %{})
    assert has_element?(view, "#ai-usage-totals", "Responses: 1")
    assert has_element?(view, "#ai-usage-totals", "$0.03")
    assert has_element?(view, "#ai-usage-totals", "Total tokens: 120")
    refute has_element?(view, "#ai-usage-table th", "Unknown costs")

    view
    |> form("#ai-usage-filters", filters: %{from: "2000-01-01", to: "2000-01-01"})
    |> render_submit()

    assert has_element?(view, "#ai-usage-empty")
  end
end

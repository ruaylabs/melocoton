defmodule MelocotonWeb.CommandPaletteHook do
  @moduledoc """
  on_mount hook that adds command palette support to all LiveViews.
  Attaches a handle_event for "open-command-palette" that triggers
  the command palette component via send_update.
  """

  import Phoenix.LiveView
  # this is required to use verified routes
  use Phoenix.VerifiedRoutes, endpoint: MelocotonWeb.Endpoint, router: MelocotonWeb.Router

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> attach_hook(:command_palette_event, :handle_event, &handle_event/3)
      |> attach_hook(:command_palette_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_event("open-command-palette", _params, socket) do
    context = %{
      has_results: match?(%{rows: [_ | _]}, socket.assigns[:result]),
      has_query: socket.assigns[:last_query] != nil,
      has_explain:
        is_binary(socket.assigns[:last_query]) and
          socket.assigns[:last_query]
          |> String.trim()
          |> String.downcase()
          |> String.starts_with?("explain"),
      running_transaction: socket.assigns[:running_transaction?] == true,
      ai_panel_open: socket.assigns[:ai_panel_open] == true,
      on_run_page: Map.has_key?(socket.assigns, :conn),
      on_query_tab:
        Map.has_key?(socket.assigns, :conn) and
          match?(
            %{type: :query},
            Enum.at(socket.assigns[:tabs] || [], socket.assigns[:active_tab_index] || 0)
          )
    }

    send_update(MelocotonWeb.CommandPalette,
      id: "command-palette",
      action: :open,
      context: context
    )

    {:halt, socket}
  end

  defp handle_event("open-ai-usage-report", _params, socket) do
    send_update(MelocotonWeb.AiUsageReportComponent, id: "ai-usage-report", action: :open)
    {:halt, socket}
  end

  # Panel toggle shortcuts — only active on pages that have these assigns
  defp handle_event("toggle-ai-panel", _params, socket) do
    if Map.has_key?(socket.assigns, :ai_panel_open) do
      {:cont, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket) do
    {:cont, socket}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "open-settings"}}, socket) do
    {:halt, push_event(socket, "open-settings-modal", %{})}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "show-ai-usage"}}, socket) do
    send_update(MelocotonWeb.AiUsageReportComponent, id: "ai-usage-report", action: :open)
    {:halt, socket}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "show-shortcuts"}}, socket) do
    {:halt, push_event(socket, "open-shortcuts-modal", %{})}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "show-diagram"}}, socket) do
    {:halt, push_event(socket, "open-diagram-modal", %{})}
  end

  defp handle_info(
         {MelocotonWeb.CommandPalette, {:palette_action, "toggle-ai-panel"}},
         socket
       ) do
    {:halt, push_event(socket, "palette-exec", %{event: "toggle-ai-panel"})}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "show-history"}}, socket) do
    {:halt, push_event(socket, "palette-exec", %{event: "switch-result-tab", value: "history"})}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "rename-tab"}}, socket) do
    active = socket.assigns[:active_tab_index] || 0
    {:halt, Phoenix.Component.assign(socket, :renaming_tab_index, active)}
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "show-onboarding"}}, socket) do
    Melocoton.Settings.reset_onboarding()
    {:halt, push_navigate(socket, to: ~p"/databases")}
  end

  defp handle_info(
         {MelocotonWeb.CommandPalette, {:palette_action, "explain-with-ai"}},
         socket
       ) do
    query = socket.assigns[:last_query]

    if query && query |> String.trim() |> String.downcase() |> String.starts_with?("explain") do
      send(self(), :explain_with_ai)
      {:halt, socket}
    else
      {:halt, put_flash(socket, :error, "Run an EXPLAIN query first.")}
    end
  end

  defp handle_info({MelocotonWeb.CommandPalette, {:palette_action, "export-" <> format}}, socket) do
    result = socket.assigns[:result]

    if result && result.rows != [] do
      database_name = (socket.assigns[:database] && socket.assigns.database.name) || "export"

      token =
        Melocoton.ExportStore.put(%{
          result: result,
          database_name: database_name
        })

      {:halt, push_event(socket, "open-url", %{url: ~p"/export/#{format}/#{token}"})}
    else
      {:halt, put_flash(socket, :error, "No results to export. Run a query first.")}
    end
  end

  defp handle_info(_msg, socket) do
    {:cont, socket}
  end
end

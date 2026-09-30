defmodule MelocotonWeb.CommandPalette do
  use MelocotonWeb, :live_component

  alias Melocoton.Databases

  @actions [
    %{id: :home, name: "Home", icon: "lucide-home", action: "navigate-home"},
    %{id: :settings, name: "Settings", icon: "lucide-settings", action: "open-settings"},
    %{
      id: :ai_usage,
      name: "AI Usage Report",
      icon: "lucide-bar-chart-3",
      action: "show-ai-usage"
    },
    %{
      id: :shortcuts,
      name: "Keyboard Shortcuts",
      icon: "lucide-keyboard",
      action: "show-shortcuts"
    },
    %{
      id: :onboarding,
      name: "Show Welcome Tutorial",
      icon: "lucide-graduation-cap",
      action: "show-onboarding"
    }
  ]

  @contextual_actions [
    %{
      id: :export_csv,
      name: "Export Results to CSV",
      icon: "lucide-file-spreadsheet",
      action: "export-csv",
      when: :has_results
    },
    %{
      id: :export_xlsx,
      name: "Export Results to Excel",
      icon: "lucide-file-spreadsheet",
      action: "export-xlsx",
      when: :has_results
    },
    %{
      id: :explain_ai,
      name: "Analyze Query Plan with AI",
      icon: "lucide-bot",
      action: "explain-with-ai",
      when: :has_explain
    },
    %{
      id: :diagram,
      name: "Schema Diagram",
      icon: "lucide-network",
      action: "show-diagram",
      when: :on_run_page
    },
    %{
      id: :toggle_ai,
      name: "Toggle AI Assistant",
      icon: "lucide-bot",
      action: "toggle-ai-panel",
      when: :on_run_page
    },
    %{
      id: :history,
      name: "Query History",
      icon: "lucide-history",
      action: "show-history",
      when: :on_run_page
    },
    %{
      id: :rename_tab,
      name: "Rename Current Tab",
      icon: "lucide-pencil",
      action: "rename-tab",
      when: :on_query_tab
    }
  ]

  @impl true
  def update(%{action: :open} = assigns, socket) do
    context = Map.get(assigns, :context, %{})
    items = build_items(context)

    socket
    |> assign(open: true, query: "", filtered: items, selected_index: 0, items: items)
    |> ok()
  end

  def update(assigns, socket) do
    if socket.assigns[:items] do
      socket |> assign(assigns) |> ok()
    else
      items = build_items(%{})

      socket
      |> assign(assigns)
      |> assign(items: items, filtered: items, query: "", selected_index: 0, open: false)
      |> ok()
    end
  end

  defp build_items(context) do
    databases = Databases.list_databases() |> Enum.map(&Map.put(&1, :kind, :database))
    always = Enum.map(@actions, &Map.put(&1, :kind, :action))

    contextual =
      @contextual_actions
      |> Enum.filter(fn action -> Map.get(context, action.when, false) end)
      |> Enum.map(&Map.put(&1, :kind, :action))

    databases ++ contextual ++ always
  end

  @impl true
  def handle_event("close", _params, socket) do
    socket
    |> assign(open: false)
    |> push_event("refocus-editor", %{})
    |> noreply()
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered = fuzzy_filter(socket.assigns.items, query)

    socket
    |> assign(query: query, filtered: filtered, selected_index: 0)
    |> noreply()
  end

  @impl true
  def handle_event("navigate", %{"key" => "ArrowDown"}, socket) do
    max = length(socket.assigns.filtered) - 1
    index = min(socket.assigns.selected_index + 1, max)

    socket
    |> assign(selected_index: index)
    |> noreply()
  end

  @impl true
  def handle_event("navigate", %{"key" => "ArrowUp"}, socket) do
    index = max(socket.assigns.selected_index - 1, 0)

    socket
    |> assign(selected_index: index)
    |> noreply()
  end

  # Ctrl+N = down
  def handle_event("navigate", %{"key" => "n", "ctrlKey" => true}, socket) do
    handle_event("navigate", %{"key" => "ArrowDown"}, socket)
  end

  # Ctrl+P = up
  def handle_event("navigate", %{"key" => "p", "ctrlKey" => true}, socket) do
    handle_event("navigate", %{"key" => "ArrowUp"}, socket)
  end

  @impl true
  def handle_event("navigate", %{"key" => "Escape"}, socket) do
    socket
    |> assign(open: false)
    |> push_event("refocus-editor", %{})
    |> noreply()
  end

  @impl true
  def handle_event("navigate", %{"key" => "Enter"}, socket) do
    select_current(socket)
  end

  def handle_event("navigate", _params, socket), do: noreply(socket)

  # Prevent form submission (Enter is handled by navigate keydown)
  def handle_event("do-nothing", _params, socket), do: noreply(socket)

  @impl true
  def handle_event("select-current", _params, socket) do
    select_current(socket)
  end

  @impl true
  def handle_event("select", %{"type" => "database", "id" => id}, socket) do
    navigate_to_database(socket, id)
  end

  def handle_event("select", %{"type" => "action", "action" => action}, socket) do
    execute_action(socket, action)
  end

  defp select_current(socket) do
    case Enum.at(socket.assigns.filtered, socket.assigns.selected_index) do
      nil -> noreply(socket)
      %{kind: :database} = db -> navigate_to_database(socket, db.id)
      %{kind: :action} = action -> execute_action(socket, action.action)
    end
  end

  defp navigate_to_database(socket, id) do
    socket
    |> assign(open: false)
    |> push_navigate(to: ~p"/databases/#{id}/run")
    |> noreply()
  end

  defp execute_action(socket, "navigate-home") do
    socket
    |> assign(open: false)
    |> push_navigate(to: ~p"/databases")
    |> noreply()
  end

  defp execute_action(socket, action) do
    notify_parent({:palette_action, action})

    socket
    |> assign(open: false)
    |> noreply()
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp fuzzy_filter(items, "") do
    items
  end

  defp fuzzy_filter(items, query) do
    query_down = String.downcase(query)

    Enum.filter(items, fn
      %{kind: :database} = db ->
        fuzzy_match?(String.downcase(db.name), query_down) or
          fuzzy_match?(String.downcase(db.group.name), query_down)

      %{kind: :action} = action ->
        fuzzy_match?(String.downcase(action.name), query_down)
    end)
  end

  defp fuzzy_match?(string, query) do
    String.contains?(string, query) or subsequence_match?(string, query)
  end

  defp subsequence_match?(string, query) do
    string_chars = String.graphemes(string)
    query_chars = String.graphemes(query)
    do_subsequence_match(string_chars, query_chars)
  end

  defp do_subsequence_match(_string, []), do: true
  defp do_subsequence_match([], _query), do: false

  defp do_subsequence_match([s | s_rest], [q | q_rest] = query) do
    if s == q do
      do_subsequence_match(s_rest, q_rest)
    else
      do_subsequence_match(s_rest, query)
    end
  end
end

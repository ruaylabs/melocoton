defmodule MelocotonWeb.SqlLive.AiChatComponent do
  use MelocotonWeb, :live_component

  alias Melocoton.{AI, Databases}

  @impl true
  def update(%{ai_chat_pubsub: {:assistant_message_saved, message}}, socket) do
    if socket.assigns.viewing_archived do
      ok(socket)
    else
      socket
      |> assign(messages: socket.assigns.messages ++ [message], loading: false)
      |> push_event("focus-ai-chat", %{})
      |> ok()
    end
  end

  def update(%{ai_chat_pubsub: {:ai_error, reason}}, socket) do
    if socket.assigns.viewing_archived do
      ok(socket)
    else
      socket
      |> assign(loading: false, error: reason)
      |> push_event("focus-ai-chat", %{})
      |> ok()
    end
  end

  def update(%{send_message: message}, socket) do
    socket
    |> send_message(message)
    |> ok()
  end

  def update(assigns, socket) do
    if socket.assigns[:database_id] && socket.assigns.database_id == assigns.database.id do
      # Same database — preserve state, only update parent-driven assigns
      socket
      |> assign(
        database: assigns.database,
        tables: assigns.tables,
        indexes: assigns.indexes,
        functions: assigns.functions,
        triggers: assigns.triggers
      )
      |> ok()
    else
      # First mount or database changed — full init
      {:ok, chat} = Databases.get_or_create_active_chat(assigns.database.id)
      messages = Databases.list_chat_messages(chat.id)

      socket
      |> assign(assigns)
      |> assign(
        database_id: assigns.database.id,
        current_chat: chat,
        messages: messages,
        input: "",
        loading: false,
        error: nil,
        show_history: false,
        viewing_archived: false,
        archived_chats: [],
        confirm_delete_message_id: nil
      )
      |> ok()
    end
  end

  @impl true
  def handle_event("send-message", %{"message" => message}, socket) when message != "" do
    socket |> send_message(message) |> noreply()
  end

  def handle_event("send-message", _params, socket), do: noreply(socket)

  @impl true
  def handle_event("update-input", %{"message" => value}, socket) do
    socket |> assign(input: value) |> noreply()
  end

  @impl true
  def handle_event("insert-sql", %{"sql" => sql}, socket) do
    notify_parent({:insert_sql, sql})
    noreply(socket)
  end

  @impl true
  def handle_event("run-sql", %{"sql" => sql}, socket) do
    notify_parent({:run_sql, sql})
    noreply(socket)
  end

  @impl true
  def handle_event("new-chat", _params, socket) do
    chat = socket.assigns.current_chat

    # Only archive if the current chat has messages
    if socket.assigns.messages != [] do
      Databases.archive_chat(chat.id)
    end

    {:ok, new_chat} = Databases.get_or_create_active_chat(socket.assigns.database_id)

    socket
    |> assign(
      current_chat: new_chat,
      messages: [],
      error: nil,
      show_history: false,
      viewing_archived: false
    )
    |> noreply()
  end

  @impl true
  def handle_event("toggle-history", _params, socket) do
    show = !socket.assigns.show_history

    socket =
      if show do
        chats = Databases.list_archived_chats(socket.assigns.database_id)
        assign(socket, archived_chats: chats, show_history: true)
      else
        assign(socket, show_history: false)
      end

    noreply(socket)
  end

  @impl true
  def handle_event("view-chat", %{"chat-id" => chat_id}, socket) do
    chat_id = String.to_integer(chat_id)
    chat = Enum.find(socket.assigns.archived_chats, &(&1.id == chat_id))

    if chat do
      messages = Databases.list_chat_messages(chat.id)

      socket
      |> assign(
        current_chat: chat,
        messages: messages,
        viewing_archived: true,
        show_history: false
      )
      |> noreply()
    else
      noreply(socket)
    end
  end

  @impl true
  def handle_event("back-to-active", _params, socket) do
    {:ok, chat} = Databases.get_or_create_active_chat(socket.assigns.database_id)
    messages = Databases.list_chat_messages(chat.id)

    socket
    |> assign(
      current_chat: chat,
      messages: messages,
      viewing_archived: false,
      show_history: false,
      error: nil
    )
    |> noreply()
  end

  @impl true
  def handle_event("delete-chat", %{"chat-id" => chat_id}, socket) do
    chat_id = String.to_integer(chat_id)
    Databases.delete_chat(chat_id)

    chats = Enum.reject(socket.assigns.archived_chats, &(&1.id == chat_id))

    socket
    |> assign(archived_chats: chats)
    |> noreply()
  end

  @impl true
  def handle_event("confirm-delete-message", %{"message-id" => message_id}, socket) do
    socket
    |> assign(confirm_delete_message_id: String.to_integer(message_id))
    |> noreply()
  end

  @impl true
  def handle_event("cancel-delete-message", _params, socket) do
    socket
    |> assign(confirm_delete_message_id: nil)
    |> noreply()
  end

  @impl true
  def handle_event("delete-message", %{"message-id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    Databases.delete_chat_message(message_id)

    messages = Enum.reject(socket.assigns.messages, &(&1.id == message_id))

    socket
    |> assign(messages: messages, confirm_delete_message_id: nil)
    |> noreply()
  end

  @impl true
  def handle_event("send-suggestion", %{"message" => message}, socket) when message != "" do
    socket |> send_message(message) |> noreply()
  end

  @impl true
  def handle_event("close-panel", _params, socket) do
    notify_parent(:close_ai_panel)
    noreply(socket)
  end

  defp send_message(socket, message) do
    %{database_id: database_id, database: database, messages: messages, current_chat: chat} =
      socket.assigns

    schema = %{
      type: database.type,
      tables: async_value(socket.assigns.tables),
      indexes: async_value(socket.assigns.indexes),
      functions: async_value(socket.assigns.functions),
      triggers: async_value(socket.assigns.triggers)
    }

    {:ok, user_msg} =
      Databases.create_chat_message(%{
        role: "user",
        content: message,
        database_id: database_id,
        chat_id: chat.id
      })

    if messages == [] do
      Databases.update_chat_title(chat, String.slice(message, 0, 80))
    end

    messages = messages ++ [user_msg]

    Task.start(fn ->
      case AI.chat(schema, messages, session_id: chat.id) do
        {:ok, text} ->
          {:ok, assistant_msg} =
            Databases.create_chat_message(%{
              role: "assistant",
              content: text,
              database_id: database_id,
              chat_id: chat.id
            })

          Phoenix.PubSub.broadcast(
            Melocoton.PubSub,
            Databases.ai_chat_topic(database_id),
            {:ai_chat, :assistant_message_saved, assistant_msg}
          )

        {:error, reason} ->
          Phoenix.PubSub.broadcast(
            Melocoton.PubSub,
            Databases.ai_chat_topic(database_id),
            {:ai_chat, :ai_error, reason}
          )
      end
    end)

    socket
    |> assign(messages: messages, input: "", loading: true, error: nil)
    |> push_event("focus-ai-chat", %{})
  end

  defp parse_message_parts(content) do
    parts = Regex.split(~r/```sql\n?(.*?)```/s, content, include_captures: true)

    Enum.map(parts, fn part ->
      case Regex.run(~r/```sql\n?(.*?)```/s, part) do
        [_, sql] -> {:sql, String.trim(sql)}
        nil -> {:markdown, render_markdown(part)}
      end
    end)
  end

  defp render_markdown(text) do
    text
    |> String.trim()
    |> Earmark.as_html!(gfm: true, gfm_tables: true)
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
  end

  defp async_value(%{ok?: true, result: result}) when is_list(result), do: result
  defp async_value(_), do: []

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end

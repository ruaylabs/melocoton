defmodule Melocoton.Databases do
  @moduledoc """
  The Databases context.
  """

  import Ecto.Query, warn: false
  alias Melocoton.Repo

  alias Melocoton.Databases.{Chat, ChatMessage, Database, QueryHistory, Session}

  @doc """
  Returns the list of databases.

  ## Examples

      iex> list_databases()
      [%Database{}, ...]

  """
  def list_databases do
    Database
    |> preload(:group)
    |> Repo.all()
  end

  def list_databases(term) do
    term = String.downcase("%#{term}%")

    query =
      from database in Database,
        where: like(fragment("LOWER(?)", database.name), ^term),
        preload: [:group]

    Repo.all(query)
  end

  @doc """
  Gets a single database.

  Raises `Ecto.NoResultsError` if the Database does not exist.

  ## Examples

      iex> get_database!(123)
      %Database{}

      iex> get_database!(456)
      ** (Ecto.NoResultsError)

  """
  def get_database!(id), do: Repo.get!(Database, id) |> Repo.preload([:group, :sessions])

  @doc """
  Creates a database.

  ## Examples

      iex> create_database(%{field: value})
      {:ok, %Database{}}

      iex> create_database(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_database(attrs \\ %{}) do
    %Database{}
    |> Database.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a database.

  ## Examples

      iex> update_database(database, %{field: new_value})
      {:ok, %Database{}}

      iex> update_database(database, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_database(%Database{} = database, attrs) do
    database
    |> Database.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a database.

  ## Examples

      iex> delete_database(database)
      {:ok, %Database{}}

      iex> delete_database(database)
      {:error, %Ecto.Changeset{}}

  """
  def delete_database(%Database{} = database) do
    Repo.delete(database)
  end

  def touch_last_connected(%Database{} = database) do
    database
    |> Ecto.Changeset.change(last_connected_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update()
  end

  def save_test_result(%Database{} = database, status) when status in [:ok, :error] do
    database
    |> Ecto.Changeset.change(
      last_test_status: status,
      last_tested_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking database changes.

  ## Examples

      iex> change_database(database)
      %Ecto.Changeset{data: %Database{}}

  """
  def change_database(%Database{} = database, attrs \\ %{}) do
    Database.changeset(database, attrs)
  end

  @doc """
  Creates a session.

  ## Examples

      iex> create_session(%{field: value})
      {:ok, %Database{}}

      iex> create_session(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_session(attrs \\ %{}) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a session.

  ## Examples

      iex> update_session(session, %{field: new_value})
      {:ok, %Session{}}

      iex> update_session(session, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking session changes.

  ## Examples

      iex> change_session(session)
      %Ecto.Changeset{data: %Session{}}

  """
  def change_session(%Session{} = session, attrs \\ %{}) do
    Session.changeset(session, attrs)
  end

  alias Melocoton.Databases.Group

  @doc """
  Returns the list of groups.

  ## Examples

      iex> list_groups()
      [%Group{}, ...]

  """
  def list_groups do
    Repo.all(Group)
  end

  @doc """
  Gets a single group.

  Raises `Ecto.NoResultsError` if the Group does not exist.

  ## Examples

      iex> get_group!(123)
      %Group{}

      iex> get_group!(456)
      ** (Ecto.NoResultsError)

  """
  def get_group!(id), do: Repo.get!(Group, id)

  @doc """
  Creates a group.

  ## Examples

      iex> create_group(%{field: value})
      {:ok, %Group{}}

      iex> create_group(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_group(attrs \\ %{}) do
    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a group.

  ## Examples

      iex> update_group(group, %{field: new_value})
      {:ok, %Group{}}

      iex> update_group(group, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a group.

  ## Examples

      iex> delete_group(group)
      {:ok, %Group{}}

      iex> delete_group(group)
      {:error, %Ecto.Changeset{}}

  """
  def delete_group(%Group{} = group) do
    Repo.delete(group)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking group changes.

  ## Examples

      iex> change_group(group)
      %Ecto.Changeset{data: %Group{}}

  """
  def change_group(%Group{} = group, attrs \\ %{}) do
    Group.changeset(group, attrs)
  end

  @doc """
  Ensures at least one group exists by creating a default group when the database is empty.
  Safe to call multiple times — it is a no-op if any group already exists.
  """
  def ensure_default_group do
    if Enum.empty?(list_groups()) do
      create_group(%{name: "Default", color: "#6b7280"})
    else
      :ok
    end
  end

  def ai_chat_topic(database_id), do: "ai_chat:#{database_id}"

  def get_or_create_active_chat(database_id) do
    Chat
    |> where([c], c.database_id == ^database_id and is_nil(c.archived_at))
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        %Chat{}
        |> Chat.changeset(%{database_id: database_id})
        |> Repo.insert()

      chat ->
        {:ok, chat}
    end
  end

  def archive_chat(chat_id) do
    Repo.get!(Chat, chat_id)
    |> Chat.changeset(%{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  def list_archived_chats(database_id) do
    Chat
    |> where([c], c.database_id == ^database_id and not is_nil(c.archived_at))
    |> order_by(desc: :archived_at)
    |> Repo.all()
  end

  def delete_chat(chat_id) do
    Repo.get!(Chat, chat_id) |> Repo.delete()
  end

  def update_chat_title(%Chat{} = chat, title) do
    chat
    |> Chat.changeset(%{title: title})
    |> Repo.update()
  end

  def list_chat_messages(chat_id, limit \\ 50) do
    ChatMessage
    |> where(chat_id: ^chat_id)
    |> order_by(asc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_chat_message(attrs) do
    %ChatMessage{}
    |> ChatMessage.changeset(attrs)
    |> Repo.insert()
  end

  def delete_chat_message(message_id) do
    Repo.get!(ChatMessage, message_id) |> Repo.delete()
  end

  @doc """
  Summarizes saved assistant messages by group, database, provider, and requested model.
  Filters: `:group_id`, `:database_id`, `:provider`, `:model`, `:from`, and `:to`.
  Dates are inclusive UTC dates. Costs are USD estimates captured at response time.
  Messages without total cost data are excluded; zero-cost messages are included.
  Deleted messages/chats are excluded; groups reflect the database's current group.
  """
  def ai_usage_report(filters \\ []) do
    query =
      from m in ChatMessage,
        join: d in assoc(m, :database),
        left_join: g in assoc(d, :group),
        where: m.role == "assistant" and not is_nil(m.total_cost),
        group_by: [g.id, g.name, d.id, d.name, m.provider, m.model],
        order_by: [g.name, d.name, m.provider, m.model],
        select: %{
          group_id: g.id,
          group: g.name,
          database_id: d.id,
          database: d.name,
          provider: m.provider,
          model: m.model,
          messages: count(m.id),
          input_tokens: sum(m.input_tokens),
          output_tokens: sum(m.output_tokens),
          total_tokens: sum(m.total_tokens),
          input_cost: sum(m.input_cost),
          output_cost: sum(m.output_cost),
          total_cost: sum(m.total_cost),
          unknown_tokens: count(m.id) - count(m.total_tokens)
        }

    filters
    |> Enum.reduce(query, &filter_ai_usage/2)
    |> Repo.all()
  end

  defp filter_ai_usage({_key, value}, query) when value in [nil, ""], do: query

  defp filter_ai_usage({:group_id, id}, query), do: where(query, [_m, d], d.group_id == ^id)
  defp filter_ai_usage({:database_id, id}, query), do: where(query, [m], m.database_id == ^id)

  defp filter_ai_usage({key, value}, query) when key in [:provider, :model],
    do: where(query, [m], field(m, ^key) == ^value)

  defp filter_ai_usage({:from, %Date{} = date}, query) do
    start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    where(query, [m], m.inserted_at >= ^start)
  end

  defp filter_ai_usage({:to, %Date{} = date}, query) do
    finish = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
    where(query, [m], m.inserted_at < ^finish)
  end

  @max_history_entries 500

  def record_query(attrs) do
    %QueryHistory{}
    |> QueryHistory.changeset(attrs)
    |> Repo.insert()
    |> tap(fn _ -> prune_query_history(attrs[:database_id] || attrs["database_id"]) end)
  end

  def list_query_history(database_id, limit \\ 100) do
    QueryHistory
    |> where(database_id: ^database_id)
    |> order_by(desc: :executed_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def delete_query_history_entry(id) do
    QueryHistory |> Repo.get(id) |> Repo.delete()
  end

  def clear_query_history(database_id) do
    QueryHistory |> where(database_id: ^database_id) |> Repo.delete_all()
  end

  defp prune_query_history(database_id) when is_integer(database_id) do
    keep_ids =
      QueryHistory
      |> where(database_id: ^database_id)
      |> order_by(desc: :executed_at)
      |> limit(@max_history_entries)
      |> select([q], q.id)

    QueryHistory
    |> where([q], q.database_id == ^database_id and q.id not in subquery(keep_ids))
    |> Repo.delete_all()
  end

  defp prune_query_history(_), do: :ok
end

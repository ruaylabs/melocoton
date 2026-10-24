defmodule MelocotonWeb.DatabaseLive.FormComponent do
  use MelocotonWeb, :live_component

  alias Melocoton.Databases

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4">
      <.simple_form
        for={@form}
        id="database-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input
          field={@form[:group_id]}
          type="select"
          label="Group"
          options={Enum.map(@groups, &{&1.name, &1.id})}
          required={true}
        />
        <.input field={@form[:name]} type="text" label="Name" />
        <.input
          field={@form[:type]}
          type="select"
          options={Ecto.Enum.values(Melocoton.Databases.Database, :type)}
          label="Type"
        />

        <%= if @db_type in [:postgres, :mysql] do %>
          <fieldset
            class="rounded p-3 space-y-3"
            style="border: 1px solid var(--border-medium);"
          >
            <legend
              class="px-2 text-[10px] uppercase font-semibold tracking-wide"
              style="color: var(--text-tertiary);"
            >
              {if @db_type == :postgres, do: "PostgreSQL", else: "MySQL"} Connection
            </legend>
            <div>
              <label
                class="block text-sm font-semibold leading-6"
                style="color: var(--text-secondary);"
              >
                Connection string
              </label>
              <input
                type="text"
                name="connection_string"
                value=""
                placeholder={"#{if @db_type == :postgres, do: "postgres", else: "mysql"}://user:password@host:port/database"}
                autocomplete="off"
                autocorrect="off"
                autocapitalize="off"
                spellcheck="false"
                phx-change="parse-connection-string"
                phx-target={@myself}
                class="mt-1 block w-full rounded border px-3 py-1.5 text-sm"
                style="background: var(--bg-primary); color: var(--text-primary); border-color: var(--border-medium);"
              />
              <p class="mt-1 text-[11px]" style="color: var(--text-tertiary);">
                Paste a connection string to fill the fields below
              </p>
            </div>
            <.input field={@form[:pg_host]} type="text" label="Host" value={@pg_host} />
            <.input field={@form[:pg_port]} type="text" label="Port" value={@pg_port} />
            <.input field={@form[:pg_user]} type="text" label="User" value={@pg_user} />
            <.input
              field={@form[:pg_password]}
              type="password"
              label="Password"
              value={@pg_password}
            />
            <.input field={@form[:pg_database]} type="text" label="Database" value={@pg_database} />
            <div
              class="px-2.5 py-1.5 rounded text-[11px] font-mono truncate"
              style="background: var(--bg-tertiary); color: var(--text-tertiary); border: 0.5px solid var(--border-medium);"
              title={
                build_display_url(@db_type, @pg_host, @pg_port, @pg_user, @pg_password, @pg_database)
              }
            >
              {build_display_url(@db_type, @pg_host, @pg_port, @pg_user, @pg_password, @pg_database)}
            </div>
          </fieldset>
        <% else %>
          <fieldset
            class="rounded p-3 space-y-3"
            style="border: 1px solid var(--border-medium);"
          >
            <legend
              class="px-2 text-[10px] uppercase font-semibold tracking-wide"
              style="color: var(--text-tertiary);"
            >
              SQLite Connection
            </legend>
            <.input field={@form[:url]} type="text" label="File path" />
          </fieldset>
        <% end %>

        <:actions>
          <.button phx-disable-with="Saving...">Save Database</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{database: database} = assigns, socket) do
    db_type = database.type || :sqlite

    {pg_host, pg_port, pg_user, pg_password, pg_database} =
      parse_connection_url(database.url, db_type)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       db_type: db_type,
       pg_host: pg_host,
       pg_port: pg_port,
       pg_user: pg_user,
       pg_password: pg_password,
       pg_database: pg_database
     )
     |> assign_new(:form, fn ->
       to_form(Databases.change_database(database))
     end)}
  end

  @impl true
  def handle_event("parse-connection-string", %{"connection_string" => url}, socket) do
    {host, port, user, password, database} = parse_connection_url(url, socket.assigns.db_type)

    socket =
      assign(socket,
        pg_host: host,
        pg_port: port,
        pg_user: user,
        pg_password: password,
        pg_database: database
      )

    url = build_connection_url(socket.assigns.db_type, host, port, user, password, database)
    current = socket.assigns.form.params || %{}
    params = Map.merge(current, %{"url" => url, "type" => to_string(socket.assigns.db_type)})
    changeset = Databases.change_database(socket.assigns.database, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("validate", %{"database" => database_params}, socket) do
    db_type = String.to_existing_atom(database_params["type"] || "sqlite")

    socket =
      if db_type in [:postgres, :mysql] do
        pg_host = database_params["pg_host"] || socket.assigns.pg_host
        pg_port = database_params["pg_port"] || socket.assigns.pg_port
        pg_user = database_params["pg_user"] || socket.assigns.pg_user
        pg_password = database_params["pg_password"] || socket.assigns.pg_password
        pg_database = database_params["pg_database"] || socket.assigns.pg_database

        assign(socket,
          pg_host: pg_host,
          pg_port: pg_port,
          pg_user: pg_user,
          pg_password: pg_password,
          pg_database: pg_database
        )
      else
        socket
      end

    database_params = maybe_build_url(database_params, db_type, socket.assigns)
    changeset = Databases.change_database(socket.assigns.database, database_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate), db_type: db_type)}
  end

  def handle_event("save", %{"database" => database_params}, socket) do
    db_type = String.to_existing_atom(database_params["type"] || "sqlite")
    database_params = maybe_build_url(database_params, db_type, socket.assigns)
    save_database(socket, socket.assigns.action, database_params)
  end

  defp save_database(socket, :edit, database_params) do
    case Databases.update_database(socket.assigns.database, database_params) do
      {:ok, database} ->
        notify_parent({:saved, database})

        {:noreply,
         socket
         |> put_flash(:info, "Database updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_database(socket, :new, database_params) do
    case Databases.create_database(database_params) do
      {:ok, database} ->
        notify_parent({:saved, database})

        {:noreply,
         socket
         |> put_flash(:info, "Database created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp build_display_url(db_type, host, port, user, password, database) do
    masked = if password != "", do: String.duplicate("*", String.length(password)), else: ""
    build_connection_url(db_type, host, port, user, masked, database)
  end

  defp maybe_build_url(params, :postgres, assigns) do
    pg = extract_pg_fields(params, assigns, "5432")
    url = build_connection_url(:postgres, pg.host, pg.port, pg.user, pg.password, pg.database)
    Map.put(params, "url", url)
  end

  defp maybe_build_url(params, :mysql, assigns) do
    pg = extract_pg_fields(params, assigns, "3306")
    url = build_connection_url(:mysql, pg.host, pg.port, pg.user, pg.password, pg.database)
    Map.put(params, "url", url)
  end

  defp maybe_build_url(params, _type, _assigns), do: params

  defp extract_pg_fields(params, assigns, default_port) do
    fields = [:host, :port, :user, :password, :database]
    defaults = %{"host" => "localhost", "port" => default_port}

    Map.new(fields, fn field ->
      pg_key = "pg_#{field}"
      field_key = Atom.to_string(field)

      value =
        params[pg_key] || Map.get(assigns, String.to_existing_atom(pg_key)) || defaults[field_key] ||
          ""

      {field, value}
    end)
  end

  defp build_connection_url(db_type, host, port, user, password, database) do
    scheme = if db_type == :mysql, do: "mysql", else: "postgres"
    default_port = if db_type == :mysql, do: "3306", else: "5432"
    userinfo = format_userinfo(user || "", password || "")
    "#{scheme}://#{userinfo}#{host || "localhost"}:#{port || default_port}/#{database || ""}"
  end

  defp format_userinfo("", _), do: ""
  defp format_userinfo(user, ""), do: "#{URI.encode(user, &URI.char_unreserved?/1)}@"

  defp format_userinfo(user, pass) do
    "#{URI.encode(user, &URI.char_unreserved?/1)}:#{URI.encode(pass, &URI.char_unreserved?/1)}@"
  end

  defp parse_connection_url(url, db_type) when url in [nil, ""],
    do: default_connection_values(db_type)

  defp parse_connection_url(url, db_type) do
    case URI.parse(url) do
      %URI{host: host, port: port, path: path, userinfo: userinfo}
      when not is_nil(host) ->
        {user, password} = parse_userinfo(userinfo)
        database = extract_database(path)
        {host, to_string(port || default_port(db_type)), user, password, database}

      _ ->
        default_connection_values(db_type)
    end
  end

  defp extract_database(nil), do: ""
  defp extract_database(path), do: String.trim_leading(path, "/")

  defp default_port(:mysql), do: 3306
  defp default_port(_), do: 5432

  defp parse_userinfo(nil), do: {"", ""}

  defp parse_userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, password] -> {URI.decode(user), URI.decode(password)}
      [user] -> {URI.decode(user), ""}
    end
  end

  defp default_connection_values(:mysql), do: {"localhost", "3306", "", "", ""}
  defp default_connection_values(_), do: {"localhost", "5432", "", "", ""}

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end

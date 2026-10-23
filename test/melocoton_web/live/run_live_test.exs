defmodule MelocotonWeb.SQLLive.RunTest do
  use MelocotonWeb.ConnCase

  import Phoenix.LiveViewTest
  import Melocoton.DatabasesFixtures

  defp create_test_db(extra_sql) do
    db_path =
      Path.join(System.tmp_dir!(), "melocoton_test_#{System.unique_integer([:positive])}.db")

    {:ok, db} = Exqlite.Sqlite3.open(db_path)
    :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
    :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO users (name) VALUES ('alice')")
    :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO users (name) VALUES ('bob')")
    Enum.each(extra_sql, &Exqlite.Sqlite3.execute(db, &1))
    Exqlite.Sqlite3.close(db)

    db_path
  end

  # render_async may return early if a previously in-flight async resolves
  # before the newly triggered one starts. Calling it twice ensures we drain
  # both the old and the new async results.
  defp flush_async(live_view) do
    render_async(live_view)
    render_async(live_view)
  end

  defp open_table_explorer(live_view, table_name) do
    render_click(live_view, "set-table-explorer", %{"table" => table_name})
    flush_async(live_view)
  end

  defp apply_filter(live_view, filter) do
    live_view
    |> element("form[phx-change='filter-rows']")
    |> render_change(%{"filter" => filter})

    flush_async(live_view)
  end

  defp apply_sort(live_view, column) do
    live_view
    |> element("[phx-click='sort-column'][phx-value-column='#{column}']")
    |> render_click()

    flush_async(live_view)
  end

  defp open_structure_tab(live_view, table_name) do
    open_table_explorer(live_view, table_name)

    live_view
    |> element("[phx-click='switch-tab'][phx-value-tab='structure']")
    |> render_click()

    flush_async(live_view)
  end

  setup do
    # Clear Pool cache to prevent stale connections from previous tests
    # (Ecto Sandbox rolls back transactions, reusing database IDs while
    # the Pool still holds connections to deleted DB files)
    :sys.replace_state(Melocoton.Pool, fn _ -> %{} end)

    item_inserts = for i <- 1..25, do: "INSERT INTO items (value) VALUES ('item_#{i}')"

    db_path =
      create_test_db(
        [
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), title TEXT)",
          "INSERT INTO posts (user_id, title) VALUES (1, 'hello')",
          "CREATE TABLE strict_table (id INTEGER PRIMARY KEY, required_field TEXT NOT NULL, optional_field TEXT)",
          "CREATE TABLE with_defaults (id INTEGER PRIMARY KEY, status TEXT DEFAULT 'active', count INTEGER DEFAULT 0)",
          "CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)",
          "CREATE TABLE cell_types (id INTEGER PRIMARY KEY, json_col TEXT, long_col TEXT, url_col TEXT, num_col REAL, bin_col BLOB)",
          ~s[INSERT INTO cell_types (json_col, long_col, url_col, num_col, bin_col) VALUES ('{"key":"value"}', '#{String.duplicate("a", 150)}', 'https://example.com/path', 3.14, X'f3beabc69348')],
          "CREATE TABLE no_pk (val TEXT, other TEXT)",
          "INSERT INTO no_pk (val, other) VALUES ('test', 'data')",
          "CREATE INDEX idx_posts_title ON posts(title)",
          "CREATE UNIQUE INDEX idx_posts_user_title ON posts(user_id, title)"
        ] ++ item_inserts
      )

    database = database_fixture(%{url: db_path, type: :sqlite})

    on_exit(fn -> File.rm(db_path) end)

    %{database: database, db_path: db_path}
  end

  describe "Run LiveView" do
    test "shows matching and total rows only while filtering results", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "run-query", %{"query" => "SELECT * FROM users"})

      refute has_element?(live_view, "#search-match-count")

      for {term, count} <- [{"alice", 1}, {"missing", 0}, {"ALICE", 1}, {"", nil}] do
        live_view
        |> element("form[phx-change='validate-filter-results']")
        |> render_change(%{"term" => term})

        if count do
          assert has_element?(
                   live_view,
                   "#search-match-count[role='status']",
                   "#{count} of 2 rows"
                 )
        else
          refute has_element?(live_view, "#search-match-count")
        end
      end
    end

    test "mounts and renders the database name", %{conn: conn, database: database} do
      {:ok, _live, html} = live(conn, ~p"/databases/#{database.id}/run")

      assert html =~ database.name
    end

    test "renders table explorer when a table is selected", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html =
        render_click(live_view, "set-table-explorer", %{"table" => "users"})

      assert html =~ "phx-value-tab=\"data\""
      assert html =~ "users"
    end
  end

  describe "table explorer with special table names" do
    test "renders table explorer for a table name with spaces", %{conn: conn} do
      db_path =
        create_test_db([
          ~s[CREATE TABLE "my table" (id INTEGER PRIMARY KEY, value TEXT)],
          ~s[INSERT INTO "my table" (value) VALUES ('test')]
        ])

      database = database_fixture(%{url: db_path, type: :sqlite, name: "special-tables"})
      on_exit(fn -> File.rm(db_path) end)

      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html = render_click(live_view, "set-table-explorer", %{"table" => "my table"})

      assert html =~ "my table"
      assert html =~ "phx-value-tab=\"data\""
    end

    test "renders table explorer for a table name with double quotes", %{conn: conn} do
      db_path =
        create_test_db([
          ~s[CREATE TABLE "my""quoted" (id INTEGER PRIMARY KEY, value TEXT)],
          ~s[INSERT INTO "my""quoted" (value) VALUES ('test')]
        ])

      database = database_fixture(%{url: db_path, type: :sqlite, name: "quoted-tables"})
      on_exit(fn -> File.rm(db_path) end)

      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html = render_click(live_view, "set-table-explorer", %{"table" => ~s(my"quoted)})

      assert html =~ "phx-value-tab=\"data\""
    end

    test "handles SQL injection attempt in table name safely", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      # This should not execute the DROP TABLE — it should just fail gracefully
      html =
        render_click(
          live_view,
          "set-table-explorer",
          %{"table" => ~s(users"; DROP TABLE users; --)}
        )

      # The table explorer renders but the async query will fail (table doesn't exist)
      assert html =~ "phx-value-tab=\"data\""
    end
  end

  describe "table explorer data tab" do
    test "displays table data with column headers", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "users")

      assert html =~ "id"
      assert html =~ "name"
      assert html =~ "alice"
      assert html =~ "bob"
    end

    test "data tab is active by default", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "users")

      assert html =~ "Data"
      assert html =~ "Showing"
    end

    test "sorts by column ascending on first click", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = apply_sort(live_view, "name")

      # alice comes before bob in ascending order
      alice_pos = :binary.match(html, "alice") |> elem(0)
      bob_pos = :binary.match(html, "bob") |> elem(0)
      assert alice_pos < bob_pos
      assert html =~ "lucide-arrow-up"
    end

    test "sorts descending on second click", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      apply_sort(live_view, "name")
      html = apply_sort(live_view, "name")

      # bob comes before alice in descending order
      alice_pos = :binary.match(html, "alice") |> elem(0)
      bob_pos = :binary.match(html, "bob") |> elem(0)
      assert bob_pos < alice_pos
      assert html =~ "lucide-arrow-down"
    end

    test "clears sort on third click", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      for _i <- 1..3, do: apply_sort(live_view, "name")

      html = render(live_view)

      refute html =~ "lucide-arrow-up "
      refute html =~ "lucide-arrow-down "
    end

    test "sorting a different column resets to ascending", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      # Sort by name descending (two clicks)
      apply_sort(live_view, "name")
      apply_sort(live_view, "name")

      # Now sort by id — should start ascending
      html = apply_sort(live_view, "id")
      assert html =~ "lucide-arrow-up"
    end

    test "sort persists across pagination", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "items")

      # Sort by value descending (two clicks)
      apply_sort(live_view, "value")
      apply_sort(live_view, "value")

      # Go to next page — sort should still be active
      live_view
      |> element("[phx-click='next-page']")
      |> render_click()

      html = flush_async(live_view)
      assert html =~ "lucide-arrow-down"
    end

    test "paginates with next and previous", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "items")

      live_view
      |> element("[phx-click='next-page']")
      |> render_click()

      html = flush_async(live_view)

      assert html =~ "item_21"
    end

    test "filters rows by search term", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})
      render_async(live_view)

      html = apply_filter(live_view, "alice")

      assert html =~ "alice"
      refute html =~ "bob"
    end

    test "filter is case-insensitive", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})
      render_async(live_view)

      html = apply_filter(live_view, "ALICE")

      # SQLite LIKE is case-insensitive for ASCII by default
      assert html =~ "alice"
      refute html =~ "bob"
    end

    test "clearing filter shows all rows again", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})
      render_async(live_view)

      apply_filter(live_view, "alice")
      html = apply_filter(live_view, "")

      assert html =~ "alice"
      assert html =~ "bob"
    end

    test "filter with no matches shows empty table", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})
      render_async(live_view)

      html = apply_filter(live_view, "nonexistent")

      refute html =~ "alice"
      refute html =~ "bob"
    end

    test "filter searches across all columns", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})
      render_async(live_view)

      html = apply_filter(live_view, "alice")
      assert html =~ "alice"
    end

    test "filter highlights matched text in cells", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})
      render_async(live_view)

      html = apply_filter(live_view, "ali")

      assert html =~ "<mark>ali</mark>"
      assert html =~ "ce"
    end

    test "no highlight marks when filter is empty", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      render_click(live_view, "set-table-explorer", %{"table" => "users"})

      html = render_async(live_view)

      refute html =~ "<mark>"
    end
  end

  describe "table explorer column filters" do
    defp toggle_filter_panel(live_view) do
      live_view
      |> element("[phx-click='toggle-filter-panel']")
      |> render_click()
    end

    defp add_column_filter(live_view) do
      live_view
      |> element("[phx-click='add-filter']")
      |> render_click()
    end

    defp update_filter(live_view, filter_id, params) do
      live_view
      |> form("#filter-#{filter_id}", Map.put(params, "filter_id", filter_id))
      |> render_change()

      flush_async(live_view)
    end

    defp get_filter_ids(html) do
      ~r/name="filter_id" value="(\d+)"/
      |> Regex.scan(html)
      |> Enum.map(fn [_, id] -> id end)
    end

    test "toggle filter panel opens and shows initial filter row", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)

      assert html =~ "Where"
      assert html =~ "contains"
      assert html =~ ~s(name="column")
      assert html =~ ~s(name="operator")
    end

    test "toggle filter panel closed hides it", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      toggle_filter_panel(live_view)
      html = toggle_filter_panel(live_view)

      refute html =~ ~s(name="operator")
    end

    test "add-filter adds another filter row", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")
      toggle_filter_panel(live_view)

      html = add_column_filter(live_view)

      assert html =~ "and"
      ids = get_filter_ids(html)
      assert length(ids) == 2
    end

    test "remove-filter removes a filter row", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        live_view
        |> element("[phx-click='remove-filter'][phx-value-id='#{filter_id}']")
        |> render_click()

      flush_async(live_view)
      assert get_filter_ids(html) == []
    end

    test "contains filter narrows results", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        update_filter(live_view, filter_id, %{
          "column" => "name",
          "operator" => "contains",
          "value" => "alice"
        })

      assert html =~ "alice"
      refute html =~ "bob"
    end

    test "equals filter matches exact value", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        update_filter(live_view, filter_id, %{
          "column" => "name",
          "operator" => "equals",
          "value" => "bob"
        })

      assert html =~ "bob"
      refute html =~ "alice"
    end

    test "not equals filter excludes matching rows", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        update_filter(live_view, filter_id, %{
          "column" => "name",
          "operator" => "not equals",
          "value" => "alice"
        })

      # "alice" appears in the filter input value, so check table rows specifically
      assert html =~ "bob"
      refute has_element?(live_view, "tbody td", "alice")
    end

    test "is null filter shows rows with null values", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "posts")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      # posts table has only one row with user_id=1, so "is null" on user_id should return nothing
      html =
        update_filter(live_view, filter_id, %{"column" => "user_id", "operator" => "is null"})

      refute html =~ "hello"
    end

    test "is not null filter shows rows with values", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "posts")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        update_filter(live_view, filter_id, %{"column" => "user_id", "operator" => "is not null"})

      assert html =~ "hello"
    end

    test "greater than filter works on numeric column", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        update_filter(live_view, filter_id, %{
          "column" => "id",
          "operator" => "greater than",
          "value" => "1"
        })

      assert html =~ "bob"
      refute html =~ "alice"
    end

    test "less than filter works on numeric column", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        update_filter(live_view, filter_id, %{
          "column" => "id",
          "operator" => "less than",
          "value" => "2"
        })

      assert html =~ "alice"
      refute html =~ "bob"
    end

    test "clear-filters removes all filters and closes panel", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      update_filter(live_view, filter_id, %{
        "column" => "name",
        "operator" => "equals",
        "value" => "alice"
      })

      live_view
      |> element("[phx-click='clear-filters']")
      |> render_click()

      html = flush_async(live_view)

      assert html =~ "alice"
      assert html =~ "bob"
      refute html =~ ~s(name="operator")
    end

    test "multiple filters combine with AND", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      toggle_filter_panel(live_view)
      html = render(live_view)
      [id1] = get_filter_ids(html)

      # First filter: id > 0 (matches both)
      update_filter(live_view, id1, %{
        "column" => "id",
        "operator" => "greater than",
        "value" => "0"
      })

      add_column_filter(live_view)
      html = render(live_view)
      [_, id2] = get_filter_ids(html)

      # Second filter: name = bob (matches only bob)
      html =
        update_filter(live_view, id2, %{
          "column" => "name",
          "operator" => "equals",
          "value" => "bob"
        })

      assert html =~ "bob"
      refute html =~ "alice"
    end

    test "sql expression mode toggle changes input style", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      html =
        live_view
        |> element("[phx-click='toggle-filter-sql'][phx-value-id='#{filter_id}']")
        |> render_click()

      assert html =~ "e.g. now()"
      assert html =~ "font-family"
    end

    test "sql expression mode uses raw value in query", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      # Enable SQL mode
      live_view
      |> element("[phx-click='toggle-filter-sql'][phx-value-id='#{filter_id}']")
      |> render_click()

      # Use SQL expression: equals lower('BOB')
      html =
        update_filter(live_view, filter_id, %{
          "column" => "name",
          "operator" => "equals",
          "value" => "lower('BOB')"
        })

      assert html =~ "bob"
      refute html =~ "alice"
    end

    test "filter badge shows active filter count", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      # Empty value filter should not count
      refute html =~ ~r/Filter.*<span[^>]*rounded-full/s

      html =
        update_filter(live_view, filter_id, %{
          "column" => "name",
          "operator" => "contains",
          "value" => "alice"
        })

      # Now should show badge with count
      assert html =~ ~r/>\s*1\s*<\/span>/
    end

    test "invalid sql expression in filter shows error instead of crashing", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = toggle_filter_panel(live_view)
      [filter_id] = get_filter_ids(html)

      # Enable SQL mode
      live_view
      |> element("[phx-click='toggle-filter-sql'][phx-value-id='#{filter_id}']")
      |> render_click()

      # Use invalid SQL expression
      update_filter(live_view, filter_id, %{
        "column" => "name",
        "operator" => "equals",
        "value" => "INVALID((("
      })

      # Should show error banner, not crash the component
      html = flush_async(live_view)
      assert html =~ "syntax error"
    end
  end

  describe "table explorer column visibility" do
    test "columns dropdown opens and shows all columns", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      live_view
      |> element("[phx-click='toggle-columns-dropdown']")
      |> render_click()

      html = render(live_view)

      assert html =~ "lucide-check-square"
      assert html =~ "phx-click=\"toggle-column\""
    end

    test "hiding a column removes it from the table", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      # Open dropdown, then hide "name"
      live_view |> element("[phx-click='toggle-columns-dropdown']") |> render_click()

      live_view
      |> element("[phx-click='toggle-column'][phx-value-column='name']")
      |> render_click()

      html = render(live_view)

      refute html =~ "alice"
      refute html =~ "bob"
      assert html =~ "id"
    end

    test "cannot hide the last visible column", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      live_view |> element("[phx-click='toggle-columns-dropdown']") |> render_click()

      # Hide "name" first
      live_view
      |> element("[phx-click='toggle-column'][phx-value-column='name']")
      |> render_click()

      # Try to hide "id" — should be prevented (last column)
      live_view
      |> element("[phx-click='toggle-column'][phx-value-column='id']")
      |> render_click()

      html = render(live_view)

      # "id" column data should still be visible
      assert html =~ "1"
      assert html =~ "2"
    end

    test "re-showing a hidden column restores it", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      live_view |> element("[phx-click='toggle-columns-dropdown']") |> render_click()

      # Hide then re-show "name"
      live_view
      |> element("[phx-click='toggle-column'][phx-value-column='name']")
      |> render_click()

      live_view
      |> element("[phx-click='toggle-column'][phx-value-column='name']")
      |> render_click()

      html = render(live_view)

      assert html =~ "alice"
      assert html =~ "bob"
    end

    test "shows count badge when columns are hidden", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      # Open dropdown and hide one column — badge with count should appear
      live_view |> element("[phx-click='toggle-columns-dropdown']") |> render_click()

      live_view
      |> element("[phx-click='toggle-column'][phx-value-column='name']")
      |> render_click()

      html = render(live_view)
      # Badge shows count of visible columns (1 of 2)
      assert html =~ "Columns"
      assert html =~ ">1</span>"
    end
  end

  describe "table explorer cell rendering" do
    test "renders JSON values with cell-json class", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "cell_types")

      assert html =~ "cell-json"
      # JSON quotes are HTML-escaped
      assert html =~ "key"
      assert html =~ "value"
    end

    test "truncates json text values with ellipsis", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "cell_types")

      assert html =~ "cell-json"
      assert html =~ "cell-expandable"
    end

    test "renders URLs with cell-url class", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "cell_types")

      assert html =~ "cell-url"
      assert html =~ "https://example.com/path"
    end

    test "renders numbers with cell-number class", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "cell_types")

      assert html =~ "cell-number"
      assert html =~ "3.14"
    end

    test "renders binary values in hex format", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "cell_types")

      assert html =~ "\\xf3beabc69348"
    end
  end

  describe "table explorer primary key detection" do
    test "enables editing controls when table has a primary key", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "users")

      # Add row button should be enabled
      refute html =~ "cursor: not-allowed"
      assert html =~ "Add row"
    end

    test "disables editing controls when table has no primary key", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "no_pk")

      # Add row button should be disabled with tooltip
      assert html =~ "Editing disabled: table has no primary key"
      assert html =~ "disabled"
    end
  end

  describe "table explorer cell editing" do
    defp edit_cell(live_view, row_idx, column) do
      live_view
      |> element(
        "[phx-click='edit-cell'][phx-value-row-idx='#{row_idx}'][phx-value-column='#{column}']"
      )
      |> render_click()
    end

    defp save_cell(live_view, row_idx, column, value) do
      live_view
      |> form("#cell-editor-#{row_idx}-#{column}", %{"value" => value})
      |> render_submit()
    end

    defp save_cell_null(live_view) do
      live_view
      |> element("[phx-click='save-cell-null']")
      |> render_click()
    end

    defp apply_changes(live_view) do
      live_view
      |> element("[phx-click='apply-changes']")
      |> render_click()

      flush_async(live_view)
    end

    defp discard_changes(live_view) do
      live_view
      |> element("[phx-click='discard-changes']")
      |> render_click()
    end

    defp cancel_edit(live_view) do
      live_view
      |> element("[phx-click='cancel-edit']")
      |> render_click()
    end

    test "clicking a cell enters edit mode", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html = edit_cell(live_view, 0, "name")

      assert html =~ "cell-editor-0-name"
      assert html =~ ~s(value="alice")
    end

    test "cancel-edit closes the editor", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      html = cancel_edit(live_view)

      refute html =~ "cell-editor-0-name"
      assert html =~ "alice"
    end

    test "save-cell stages a pending change without writing to database", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      html = save_cell(live_view, 0, "name", "alice_updated")

      # Change is shown in the UI as pending
      assert html =~ "alice_updated"
      # Pending changes counter is visible
      assert html =~ "Apply changes"
      assert html =~ ">1</span>"
      # Editor should be closed
      refute html =~ "cell-editor"
    end

    test "save-cell submits the typed value, not null", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      html = save_cell(live_view, 0, "name", "new_name")

      # The typed value should be staged, not NULL
      assert html =~ "new_name"
      refute html =~ "cell-null"
    end

    test "save-cell-null sets value to null", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      html = save_cell_null(live_view)

      assert html =~ "cell-null"
      assert html =~ "Apply changes"
    end

    test "apply-changes writes pending changes to database", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      save_cell(live_view, 0, "name", "alice_updated")

      html = apply_changes(live_view)

      assert html =~ "alice_updated"
      # Apply button should be gone (no more pending changes)
      refute html =~ "Apply changes"
    end

    test "discard-changes removes all pending changes", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      save_cell(live_view, 0, "name", "alice_updated")

      html = discard_changes(live_view)

      # Original value is back
      assert html =~ "alice"
      refute html =~ "alice_updated"
      refute html =~ "Apply changes"
    end

    test "multiple cells can be edited before applying", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      # Edit first row's name
      edit_cell(live_view, 0, "name")
      save_cell(live_view, 0, "name", "alice_v2")

      # Edit second row's name
      edit_cell(live_view, 1, "name")
      html = save_cell(live_view, 1, "name", "bob_v2")

      # Both pending changes visible
      assert html =~ "alice_v2"
      assert html =~ "bob_v2"
      assert html =~ ">2</span>"

      # Apply all at once
      html = apply_changes(live_view)

      assert html =~ "alice_v2"
      assert html =~ "bob_v2"
      refute html =~ "Apply changes"
    end

    test "setting same value as original removes pending change", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      edit_cell(live_view, 0, "name")
      save_cell(live_view, 0, "name", "changed")

      # Edit the same cell back to original value
      edit_cell(live_view, 0, "name")
      html = save_cell(live_view, 0, "name", "alice")

      # No pending changes
      refute html =~ "Apply changes"
    end

    test "undo-cell reverts a single pending change", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      # Stage two changes
      edit_cell(live_view, 0, "name")
      save_cell(live_view, 0, "name", "alice_changed")
      edit_cell(live_view, 1, "name")
      save_cell(live_view, 1, "name", "bob_changed")

      # Undo only the first change
      html =
        live_view
        |> element("[phx-click='undo-cell'][phx-value-row-idx='0'][phx-value-column='name']")
        |> render_click()

      # First row reverted to original, second still pending
      assert html =~ "alice"
      refute html =~ "alice_changed"
      assert html =~ "bob_changed"
      # One pending change left
      assert html =~ ">1</span>"
    end

    test "click-to-edit is not available for tables without primary key", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_table_explorer(live_view, "no_pk")

      # Cells should not have edit-cell click handler
      refute html =~ "phx-click=\"edit-cell\""
    end
  end

  describe "table explorer structure tab" do
    test "switches to structure tab and shows column details", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_structure_tab(live_view, "users")

      assert html =~ "Columns"
      assert html =~ "id"
      assert html =~ "name"
      assert html =~ "INTEGER"
      assert html =~ "TEXT"
    end

    test "shows CREATE TABLE statement for sqlite", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_structure_tab(live_view, "users")

      assert html =~ "Create Statement"
      assert html =~ "CREATE"
      assert html =~ "TABLE"
      assert html =~ "users"
    end

    test "shows primary key columns", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_structure_tab(live_view, "users")

      assert html =~ "PK"
    end

    test "shows foreign keys when present", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_structure_tab(live_view, "posts")

      assert html =~ "Foreign Keys"
      assert html =~ "user_id"
      assert html =~ "users"
    end

    test "can switch back to data tab from structure", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_structure_tab(live_view, "users")

      live_view
      |> element("[phx-click='switch-tab'][phx-value-tab='data']")
      |> render_click()

      html = flush_async(live_view)

      assert html =~ "alice"
      assert html =~ "bob"
      assert html =~ "Showing"
    end

    test "shows nullable info for columns", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_structure_tab(live_view, "strict_table")

      assert html =~ "required_field"
      assert html =~ "optional_field"
      assert html =~ "NO"
    end

    test "shows default values for columns", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_structure_tab(live_view, "with_defaults")

      assert html =~ "&#39;active&#39;"
      assert html =~ "0"
    end
  end

  describe "table explorer indexes tab" do
    defp open_indexes_tab(live_view, table_name) do
      open_table_explorer(live_view, table_name)

      live_view
      |> element("[phx-click='switch-tab'][phx-value-tab='indexes']")
      |> render_click()

      flush_async(live_view)
    end

    test "shows indexes for a table", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_indexes_tab(live_view, "posts")

      assert html =~ "idx_posts_title"
      assert html =~ "title"
    end

    test "shows unique badge for unique indexes", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_indexes_tab(live_view, "posts")

      assert html =~ "idx_posts_user_title"
      assert html =~ "YES"
    end

    test "shows multiple columns for composite indexes", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_indexes_tab(live_view, "posts")

      assert html =~ "user_id"
      assert html =~ "title"
    end

    test "shows empty state when no indexes", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_indexes_tab(live_view, "users")

      assert html =~ "No indexes found"
    end
  end

  describe "table explorer relations tab" do
    defp open_relations_tab(live_view, table_name) do
      open_table_explorer(live_view, table_name)

      live_view
      |> element("[phx-click='switch-tab'][phx-value-tab='relations']")
      |> render_click()

      flush_async(live_view)
    end

    test "shows outgoing foreign keys", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_relations_tab(live_view, "posts")

      assert html =~ "References (outgoing)"
      assert html =~ "user_id"
      assert html =~ "users"
    end

    test "shows incoming references", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_relations_tab(live_view, "users")

      assert html =~ "Referenced by (incoming)"
      assert html =~ "posts"
    end

    test "shows empty state when no outgoing references", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_relations_tab(live_view, "users")

      assert html =~ "This table does not reference other tables"
    end

    test "shows empty state when no incoming references", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_relations_tab(live_view, "posts")

      assert html =~ "No other tables reference this table"
    end

    test "table names are clickable to navigate", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      html = open_relations_tab(live_view, "posts")

      assert html =~ "phx-click=\"set-table-explorer\""
      assert html =~ "phx-value-table=\"users\""
    end
  end

  describe "session names" do
    test "first tab shows the default session name", %{conn: conn, database: database} do
      {:ok, _live, html} = live(conn, ~p"/databases/#{database.id}/run")

      assert html =~ "#1"
    end

    test "new session tab gets a correlative name", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html = render_click(live_view, "new-session", %{})

      assert html =~ "query_2.sql"
    end

    test "start-rename-tab renders the rename input for the right tab", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html = render_click(live_view, "start-rename-tab", %{"index" => "0"})

      assert html =~ ~s(phx-blur="commit-rename-tab")
      assert html =~ ~s(phx-keydown="keydown-rename-tab")
    end

    test "commit-rename-tab updates the tab label", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "start-rename-tab", %{"index" => "0"})

      html =
        render_click(live_view, "commit-rename-tab", %{
          "index" => "0",
          "value" => "my_query.sql"
        })

      assert html =~ "my_query.sql"
      refute html =~ ~s(phx-blur="commit-rename-tab")
    end

    test "commit-rename-tab persists the name across remounts", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "start-rename-tab", %{"index" => "0"})

      render_click(live_view, "commit-rename-tab", %{
        "index" => "0",
        "value" => "persisted.sql"
      })

      {:ok, _live2, html} = live(conn, ~p"/databases/#{database.id}/run")

      assert html =~ "persisted.sql"
    end

    test "escape keydown cancels rename without saving", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "start-rename-tab", %{"index" => "0"})

      html =
        render_click(live_view, "keydown-rename-tab", %{
          "index" => "0",
          "key" => "Escape"
        })

      refute html =~ ~s(phx-blur="commit-rename-tab")
      assert html =~ "#1"
    end

    test "commit with blank name does not change the tab label", %{
      conn: conn,
      database: database
    } do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "start-rename-tab", %{"index" => "0"})

      html =
        render_click(live_view, "commit-rename-tab", %{"index" => "0", "value" => "   "})

      assert html =~ "#1"
    end

    test "commit for a non-renaming tab index is ignored", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "start-rename-tab", %{"index" => "0"})

      html =
        render_click(live_view, "commit-rename-tab", %{
          "index" => "1",
          "value" => "should_not_appear.sql"
        })

      refute html =~ "should_not_appear.sql"
    end

    test "rename icon is rendered for query tabs", %{conn: conn, database: database} do
      {:ok, _live, html} = live(conn, ~p"/databases/#{database.id}/run")

      assert html =~ ~s(phx-click="start-rename-tab")
      assert html =~ "lucide-pencil"
    end
  end

  describe "save query" do
    test "save-query pushes a download event", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "save-query")

      assert_push_event(live_view, "open-url", %{url: "/export/sql/" <> _token})
    end
  end

  describe "read-only mode" do
    setup %{db_path: db_path} do
      group = group_fixture(%{name: "Production", color: "#ff0000", read_only: true})
      database = database_fixture(%{url: db_path, type: :sqlite, group_id: group.id})

      %{ro_database: database}
    end

    test "blocks INSERT queries", %{conn: conn, ro_database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html =
        render_click(live_view, "run-query", %{
          "query" => "INSERT INTO users (name) VALUES ('eve')"
        })

      assert html =~ "Read-only mode"
    end

    test "blocks UPDATE queries", %{conn: conn, ro_database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html =
        render_click(live_view, "run-query", %{
          "query" => "UPDATE users SET name = 'changed' WHERE id = 1"
        })

      assert html =~ "Read-only mode"
    end

    test "blocks DELETE queries", %{conn: conn, ro_database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html =
        render_click(live_view, "run-query", %{"query" => "DELETE FROM users WHERE id = 1"})

      assert html =~ "Read-only mode"
    end

    test "blocks DROP queries", %{conn: conn, ro_database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      html = render_click(live_view, "run-query", %{"query" => "DROP TABLE users"})

      assert html =~ "Read-only mode"
    end

    test "allows SELECT queries", %{conn: conn, ro_database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")

      render_click(live_view, "run-query", %{"query" => "SELECT * FROM users"})
      html = render(live_view)

      refute html =~ "Read-only mode"
      assert html =~ "alice"
    end

    test "shows read-only badge in toolbar", %{conn: conn, ro_database: database} do
      {:ok, _live_view, html} = live(conn, ~p"/databases/#{database.id}/run")

      assert html =~ "read-only"
      assert html =~ "lucide-lock"
    end
  end

  describe "add row" do
    test "shows modal when add row is clicked", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html =
        live_view
        |> element("[phx-click='add-row']")
        |> render_click()

      assert html =~ "Insert Row"
      assert html =~ "Add row to users"
    end

    test "shows all columns as form fields", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html =
        live_view
        |> element("[phx-click='add-row']")
        |> render_click()

      assert html =~ "name"
      assert html =~ "id"
    end

    test "marks primary key columns", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      html =
        live_view
        |> element("[phx-click='add-row']")
        |> render_click()

      assert html =~ "PK"
    end

    test "cancels add row via button", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      live_view |> element("[phx-click='add-row']") |> render_click()

      html =
        live_view
        |> element("button[phx-click='cancel-add-row']")
        |> render_click()

      refute html =~ "Insert Row"
    end

    test "inserts a new row with values", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "users")

      live_view |> element("[phx-click='add-row']") |> render_click()

      live_view
      |> element("form[phx-submit='save-new-row']")
      |> render_submit(%{"name" => "charlie"})

      html = flush_async(live_view)
      refute html =~ "Insert Row"
      assert html =~ "charlie"
    end

    test "inserts a row with defaults", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "with_defaults")

      live_view |> element("[phx-click='add-row']") |> render_click()

      live_view
      |> element("form[phx-submit='save-new-row']")
      |> render_submit(%{})

      html = flush_async(live_view)
      refute html =~ "Insert Row"
      assert html =~ "active"
    end

    test "shows error and preserves values on failure", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "strict_table")

      live_view |> element("[phx-click='add-row']") |> render_click()

      # Submit without required_field (NOT NULL constraint)
      live_view
      |> element("form[phx-submit='save-new-row']")
      |> render_submit(%{"optional_field" => "test_value"})

      html = render(live_view)
      # Modal should stay open with error
      assert html =~ "Insert Row"
      assert html =~ "NOT NULL"
      # Entered value should be preserved
      assert html =~ "test_value"
    end

    test "add row button is disabled when table has no PK", %{conn: conn, database: database} do
      {:ok, live_view, _html} = live(conn, ~p"/databases/#{database.id}/run")
      open_table_explorer(live_view, "no_pk")

      html = render(live_view)
      assert html =~ "Editing disabled"
    end
  end
end

defmodule Melocoton.AI do
  @moduledoc """
  AI service for SQL query generation using the connected database's schema as context.
  Uses ReqLLM for provider-agnostic LLM integration.
  """

  @doc """
  Sends a chat message to the configured LLM with database schema context.

  `schema` is a map with `:type` (atom) and `:tables` (list).

  Returns `{:ok, attrs}` with content, provider, model, token usage, and USD cost estimates,
  or `{:error, reason}`. The model identifies the requested model (including provider tiers).
  """
  def chat(schema, messages, opts \\ []) do
    model_str = opts[:model] || get_in(Application.get_env(:melocoton, :ai, []), [:model])

    if is_nil(model_str) or model_str == "" do
      {:error, "No AI model configured. Go to Settings to set a model and API key."}
    else
      do_chat(schema, messages, model_str, Keyword.delete(opts, :model))
    end
  end

  defp do_chat(schema, messages, model_str, opts) do
    system_prompt = build_system_prompt(schema)

    llm_messages =
      [%{role: "system", content: system_prompt}] ++
        Enum.map(messages, fn m -> %{role: m.role, content: m.content} end)

    request_opts = Keyword.delete(opts, :session_id)

    result =
      case parse_provider(model_str) do
        {:minimax, model_name} ->
          Melocoton.AI.MinimaxProvider.chat(
            llm_messages,
            Keyword.put(request_opts, :model, model_name)
          )

        {:ollama, model_name} ->
          request_opts =
            Keyword.merge([api_key: "ollama", receive_timeout: 300_000], request_opts)

          ReqLLM.generate_text(Melocoton.AI.Ollama.model(model_name), llm_messages, request_opts)

        {:opencode, model_name} ->
          Melocoton.AI.OpenCode.chat(llm_messages, Keyword.put(opts, :model, model_name))

        _ ->
          ReqLLM.generate_text(model_str, llm_messages, request_opts)
      end

    case result do
      {:ok, response} -> {:ok, response_attributes(response, model_str)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, error} -> {:error, "LLM error: #{inspect(error)}"}
    end
  end

  defp parse_provider("minimax:" <> model), do: {:minimax, model}
  defp parse_provider("ollama:" <> model), do: {:ollama, model}
  defp parse_provider("opencode:" <> model), do: {:opencode, model}
  defp parse_provider(_), do: :standard

  @doc false
  def response_attributes(%ReqLLM.Response{} = response, model_str) do
    [provider, model] = String.split(model_str, ":", parts: 2)
    # Response usage is already normalized. Re-normalizing drops ReqLLM's cost metadata.
    usage = response.usage || %{}
    input_tokens = usage[:input_tokens] || usage[:input]
    output_tokens = usage[:output_tokens] || usage[:output]
    cost = usage[:cost] || %{}

    %{
      content: ReqLLM.Response.text(response),
      provider: provider,
      model: model,
      usage: usage,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: usage[:total_tokens] || total_tokens(input_tokens, output_tokens),
      input_cost: decimal_cost(usage[:input_cost] || cost[:input_cost], provider),
      output_cost: decimal_cost(usage[:output_cost] || cost[:output_cost], provider),
      total_cost: decimal_cost(usage[:total_cost] || cost[:total], provider)
    }
  end

  defp total_tokens(input, output) when is_integer(input) and is_integer(output),
    do: input + output

  defp total_tokens(_input, _output), do: nil

  # Local inference has no provider API charge; hardware/electricity costs are not included.
  defp decimal_cost(_cost, "ollama"), do: Decimal.new(0)
  defp decimal_cost(nil, _provider), do: nil
  defp decimal_cost(cost, _provider) when is_float(cost), do: Decimal.from_float(cost)
  defp decimal_cost(cost, _provider), do: Decimal.new(cost)

  @doc """
  Builds a system prompt with the full database schema for LLM context.

  `schema` is a map with `:type` and `:tables`.
  """
  def build_system_prompt(schema) do
    db_type =
      case schema.type do
        :postgres -> "PostgreSQL"
        :mysql -> "MySQL"
        :sqlite -> "SQLite"
      end

    schema_text = build_schema_text(schema.tables)
    indexes_text = build_indexes_text(schema.indexes)
    triggers_text = build_triggers_text(schema.triggers)
    functions_text = build_functions_text(schema.functions)

    """
    You are a SQL assistant for a #{db_type} database.

    #{schema_text}
    #{indexes_text}
    #{triggers_text}
    #{functions_text}

    Rules:
    - Generate valid #{db_type} SQL
    - When the user asks for a query, respond with the SQL inside a ```sql code block
    - You can include a brief explanation before or after the SQL if helpful
    - If the user's request is ambiguous, ask for clarification
    - Use the exact table and column names from the schema above
    - Consider foreign key relationships when joining tables
    """
  end

  defp build_schema_text(tables) do
    table_descriptions =
      Enum.map_join(tables, "\n\n", fn table ->
        cols =
          Enum.map_join(table.cols, "\n", fn col -> "    - #{col.name} (#{col.type})" end)

        "  Table: #{table.name}\n#{cols}"
      end)

    "Database schema:\n#{table_descriptions}"
  end

  defp build_indexes_text([]), do: ""

  defp build_indexes_text(indexes) do
    descriptions =
      indexes
      |> Enum.group_by(& &1.table)
      |> Enum.map_join("\n", fn {table, idxs} ->
        "  #{table}: #{Enum.map_join(idxs, ", ", & &1.name)}"
      end)

    "Indexes:\n#{descriptions}"
  end

  defp build_triggers_text([]), do: ""

  defp build_triggers_text(triggers) do
    descriptions =
      Enum.map_join(triggers, "\n", fn t -> "  #{t.name} ON #{t.table}" end)

    "Triggers:\n#{descriptions}"
  end

  defp build_functions_text([]), do: ""

  defp build_functions_text(functions) do
    descriptions =
      Enum.map_join(functions, "\n", fn f ->
        schema_prefix = if f.schema, do: "#{f.schema}.", else: ""
        args = if f.arguments, do: "(#{f.arguments})", else: "()"
        returns = if f.return_type, do: " -> #{f.return_type}", else: ""
        "  #{f.kind} #{schema_prefix}#{f.name}#{args}#{returns}"
      end)

    "Functions and procedures:\n#{descriptions}"
  end
end

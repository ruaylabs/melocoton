defmodule Melocoton.Databases.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Melocoton.Databases.{Chat, Database}

  schema "chat_messages" do
    field :role, :string
    field :content, :string
    field :provider, :string
    field :model, :string
    field :usage, :map
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :total_tokens, :integer
    field :input_cost, :decimal
    field :output_cost, :decimal
    field :total_cost, :decimal
    belongs_to :database, Database
    belongs_to :chat, Chat

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chat_message, attrs) do
    chat_message
    |> cast(attrs, [
      :role,
      :content,
      :database_id,
      :chat_id,
      :provider,
      :model,
      :usage,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :input_cost,
      :output_cost,
      :total_cost
    ])
    |> validate_required([:role, :content, :database_id, :chat_id])
    |> validate_inclusion(:role, ["user", "assistant"])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:input_cost, greater_than_or_equal_to: 0)
    |> validate_number(:output_cost, greater_than_or_equal_to: 0)
    |> validate_number(:total_cost, greater_than_or_equal_to: 0)
  end
end

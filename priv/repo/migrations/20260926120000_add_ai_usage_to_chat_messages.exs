defmodule Melocoton.Repo.Migrations.AddAiUsageToChatMessages do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :provider, :string
      add :model, :string
      add :usage, :map
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :total_tokens, :integer
      add :input_cost, :decimal
      add :output_cost, :decimal
      add :total_cost, :decimal
    end

    create index(:chat_messages, [:role, :inserted_at])
    create index(:chat_messages, [:provider, :model])
  end
end

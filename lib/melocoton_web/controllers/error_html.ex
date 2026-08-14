defmodule MelocotonWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use MelocotonWeb, :html

  require Logger

  embed_templates "error_html/*"

  def diagnostic_report(kind, reason, stack) do
    reference = error_reference()
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    support_email = Application.fetch_env!(:melocoton, :support_email)

    report = """
    Melocoton diagnostic report
    Reference: #{reference}
    Version: #{application_version()}
    Generated: #{generated_at}
    System: #{system_info()}
    Error type: #{error_type(reason)}

    This report excludes error messages, stack traces, database queries, and credentials.
    """

    Logger.error("Error reference #{reference}\n" <> Exception.format(kind, reason, stack))

    subject = URI.encode_www_form("Melocoton error #{reference}")
    body = URI.encode_www_form(report)

    %{
      reference: reference,
      report: report,
      support_email: support_email,
      mailto: "mailto:#{support_email}?subject=#{subject}&body=#{body}"
    }
  end

  # Fall back to Phoenix's status message for errors without a custom page.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  defp error_reference do
    Logger.metadata()[:request_id] ||
      :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp application_version do
    :melocoton
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp system_info do
    {family, name} = :os.type()
    architecture = :erlang.system_info(:system_architecture)
    "#{family}/#{name} (#{architecture})"
  end

  defp error_type(%{__struct__: module}), do: inspect(module)
  defp error_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type(_reason), do: "Unknown error"
end

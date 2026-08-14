defmodule MelocotonWeb.ErrorHTMLTest do
  use MelocotonWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  test "renders 404.html" do
    assert render_to_string(MelocotonWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders a helpful 500 page with sanitized diagnostics" do
    reason = RuntimeError.exception("database password: super-secret")
    assigns = [kind: :error, reason: reason, stack: []]
    html = render_to_string(MelocotonWeb.ErrorHTML, "500", "html", assigns)

    assert String.starts_with?(html, "<!DOCTYPE html>")
    assert html =~ "Something went wrong"
    assert html =~ "Melocoton ran into an unexpected error"
    assert html =~ "Copy diagnostics"
    assert html =~ "Email support"
    assert html =~ "support@ruaylabs.com"
    assert html =~ "mailto:support@ruaylabs.com"
    assert html =~ "Reference:"
    assert html =~ "Error type: RuntimeError"
    assert html =~ ~s(href="/")
    assert html =~ "Go to home"
    refute html =~ "super-secret"
    refute html =~ "Internal Server Error"
  end
end

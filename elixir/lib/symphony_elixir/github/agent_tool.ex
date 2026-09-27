defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc "Constrained GitHub mutation tools for the supervised pilot."

  alias SymphonyElixir.GitHub.Client

  @marker "<!-- symphony-workpad:v1 -->"
  @tools ["github_workpad", "github_apply_workflow_label", "github_attach_draft_pr"]

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      spec(
        "github_workpad",
        "Create or update the single Symphony workpad comment.",
        %{
          "issue_number" => integer_schema(),
          "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 60_000}
        },
        ["issue_number", "body"]
      ),
      spec(
        "github_apply_workflow_label",
        "Apply one configured workflow label.",
        %{
          "issue_number" => integer_schema(),
          "label" => %{"type" => "string", "minLength" => 1}
        },
        ["issue_number", "label"]
      ),
      spec(
        "github_attach_draft_pr",
        "Verify and attach one Draft PR URL to the workpad.",
        %{
          "issue_number" => integer_schema(),
          "pr_url" => %{"type" => "string", "minLength" => 1}
        },
        ["issue_number", "pr_url"]
      )
    ]
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) when tool in @tools and is_map(arguments) do
    case run(tool, arguments, opts) do
      {:ok, payload} -> response(true, payload)
      {:error, reason} -> response(false, %{"error" => %{"code" => error_code(reason)}})
    end
  end

  def execute(_tool, _arguments, _opts),
    do: response(false, %{"error" => %{"code" => "unsupported_github_tool", "supportedTools" => @tools}})

  defp run("github_workpad", %{"issue_number" => number, "body" => body}, opts)
       when is_integer(number) and number > 0 and is_binary(body) and byte_size(body) in 1..60_000,
       do: upsert_workpad(number, body, opts)

  defp run("github_apply_workflow_label", %{"issue_number" => number, "label" => label}, opts)
       when is_integer(number) and number > 0 and is_binary(label) do
    with {:ok, settings} <- tool_settings(opts),
         :ok <- authorize_issue(number, opts),
         true <- MapSet.member?(settings.workflow_labels, label) or {:error, :label_not_allowed},
         {:ok, %{status: status, body: body}} <-
           request("POST", issue_path(settings, number) <> "/labels", %{}, %{"labels" => [label]}, opts),
         true <- status in 200..299 or {:error, {:github_api_status, status}} do
      {:ok, %{"status" => status, "body" => body}}
    end
  end

  defp run("github_attach_draft_pr", %{"issue_number" => number, "pr_url" => url}, opts)
       when is_integer(number) and number > 0 and is_binary(url) do
    with {:ok, settings} <- tool_settings(opts),
         :ok <- authorize_issue(number, opts),
         {:ok, pr_number} <- scoped_pr_number(url, settings.repo),
         {:ok, %{status: 200, body: %{"draft" => true, "html_url" => ^url}}} <-
           request("GET", "/repos/#{settings.repo}/pulls/#{pr_number}", %{}, nil, opts) do
      upsert_workpad(number, "Draft PR: #{url}", opts)
    else
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
    end
  end

  defp run(_tool, _arguments, _opts), do: {:error, :invalid_arguments}

  defp upsert_workpad(number, body, opts) do
    with {:ok, settings} <- tool_settings(opts),
         :ok <- authorize_issue(number, opts),
         {:ok, %{status: 200, body: comments}} <-
           request("GET", issue_path(settings, number) <> "/comments", %{"per_page" => 100}, nil, opts),
         {:ok, comment} <- owned_workpad(comments, settings.actor_id),
         {:ok, %{status: status, body: response_body}} <- write_workpad(comment, number, body, settings, opts),
         true <- status in 200..299 or {:error, {:github_api_status, status}} do
      {:ok, %{"status" => status, "body" => response_body}}
    end
  end

  defp owned_workpad(comments, actor_id) when is_list(comments) and length(comments) < 100 do
    matches =
      Enum.filter(comments, fn
        %{"body" => body, "user" => %{"node_id" => ^actor_id}} when is_binary(body) ->
          String.contains?(body, @marker)

        _ ->
          false
      end)

    case matches do
      [] -> {:ok, nil}
      [comment] -> {:ok, comment}
      _ -> {:error, :ambiguous_workpad}
    end
  end

  defp owned_workpad(_, _), do: {:error, :comment_pagination_ambiguous}

  defp write_workpad(nil, number, body, settings, opts),
    do: request("POST", issue_path(settings, number) <> "/comments", %{}, %{"body" => workpad(body)}, opts)

  defp write_workpad(%{"id" => id}, _number, body, settings, opts) when is_integer(id),
    do: request("PATCH", "/repos/#{settings.repo}/issues/comments/#{id}", %{}, %{"body" => workpad(body)}, opts)

  defp write_workpad(_, _, _, _, _), do: {:error, :malformed_workpad}

  defp request(method, path, params, body, opts) do
    client = Keyword.get(opts, :github_client, &Client.rest/5)
    client.(method, path, params, body, Keyword.take(opts, [:tracker_settings]))
  end

  defp authorize_issue(number, opts) do
    checker = Keyword.get(opts, :scope_checker, &Client.issue_in_scope?/2)
    checker.(number, Keyword.take(opts, [:tracker_settings]))
  end

  defp tool_settings(opts) do
    case Keyword.get(opts, :tracker_settings) do
      %{provider: provider} when is_map(provider) ->
        with repo when is_binary(repo) <- provider["repo"],
             actor when is_binary(actor) <- provider["actor_id"],
             labels when is_list(labels) and labels != [] <- provider["workflow_labels"] do
          {:ok, %{repo: repo, actor_id: actor, workflow_labels: MapSet.new(labels)}}
        else
          _ -> {:error, :invalid_github_tool_settings}
        end

      _ ->
        {:error, :invalid_github_tool_settings}
    end
  end

  defp scoped_pr_number(url, repo) do
    expected = "https://github.com/#{repo}/pull/"

    case String.replace_prefix(url, expected, "") do
      ^url ->
        {:error, :pr_scope_violation}

      suffix ->
        case Integer.parse(suffix) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :invalid_pr_url}
        end
    end
  end

  defp issue_path(settings, number), do: "/repos/#{settings.repo}/issues/#{number}"
  defp workpad(body), do: @marker <> "\n" <> body

  defp spec(name, description, properties, required),
    do: %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => required,
        "properties" => properties
      }
    }

  defp integer_schema, do: %{"type" => "integer", "minimum" => 1}

  defp response(success, payload) do
    output = Jason.encode!(payload)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
end

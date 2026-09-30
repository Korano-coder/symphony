defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc "Constrained GitHub mutation tools for the supervised pilot."

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue

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
         {:ok, allowed_label} <- allowed_label(settings.workflow_labels, label),
         {:ok, _} <- authorize_issue(number, settings, opts),
         {:ok, current} <- authorize_issue(number, settings, opts),
         {:ok, labels} <- transition_labels(current.labels, settings.workflow_labels, allowed_label),
         {:ok, %{status: status, body: body}} <-
           request("PATCH", issue_path(settings, number), %{}, %{"labels" => labels}, opts),
         true <- status in 200..299 or {:error, {:github_api_status, status}} do
      with %{"labels" => labels} when is_list(labels) <- body,
           names <- Enum.map(labels, & &1["name"]),
           [^allowed_label] <- Enum.filter(names, &(&1 in settings.workflow_labels)) do
        {:ok, %{"status" => status, "label" => allowed_label}}
      else
        _ -> {:error, :github_unknown_payload}
      end
    end
  end

  defp run("github_attach_draft_pr", %{"issue_number" => number, "pr_url" => url}, opts)
       when is_integer(number) and number > 0 and is_binary(url) do
    with {:ok, settings} <- tool_settings(opts),
         {:ok, _} <- authorize_issue(number, settings, opts),
         {:ok, pr_number} <- scoped_pr_number(url, settings.repo),
         {:ok,
          %{
            status: 200,
            body: %{
              "draft" => true,
              "state" => "open",
              "html_url" => ^url,
              "base" => %{
                "ref" => base_branch,
                "repo" => %{"full_name" => base_repo}
              }
            }
          }}
         when base_branch == settings.base_branch and base_repo == settings.repo <-
           request("GET", "/repos/#{settings.repo}/pulls/#{pr_number}", %{}, nil, opts) do
      with {:ok, result} <- upsert_workpad(number, "Draft PR: #{url}", opts) do
        {:ok, Map.merge(result, %{"draft_pr" => url, "base_branch" => settings.base_branch})}
      end
    else
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
    end
  end

  defp run(_tool, _arguments, _opts), do: {:error, :invalid_arguments}

  defp upsert_workpad(number, body, opts) do
    with {:ok, settings} <- tool_settings(opts),
         {:ok, _} <- authorize_issue(number, settings, opts),
         {:ok, %{status: 200, body: comments}} <-
           request("GET", issue_path(settings, number) <> "/comments", %{"per_page" => 100}, nil, opts),
         {:ok, comment} <- owned_workpad(comments, settings.actor_id),
         {:ok, _} <- authorize_issue(number, settings, opts),
         {:ok, %{status: status, body: response_body}} <- write_workpad(comment, number, body, settings, opts),
         true <- status in 200..299 or {:error, {:github_api_status, status}} do
      case response_body do
        %{"id" => id} when is_integer(id) -> {:ok, %{"status" => status, "comment_id" => id}}
        _ -> {:error, :github_unknown_payload}
      end
    end
  end

  defp owned_workpad(comments, actor_id) when is_list(comments) and length(comments) < 100 do
    matches =
      Enum.filter(comments, fn
        %{"body" => body, "user" => %{"node_id" => ^actor_id}} when is_binary(body) ->
          body == @marker or String.starts_with?(body, @marker <> "\n")

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

  defp authorize_issue(number, settings, opts) do
    with %Issue{native_ref: native_ref} when is_map(native_ref) <- Keyword.get(opts, :issue),
         true <-
           (native_ref["issue_number"] == number and native_ref["repository"] == settings.repo and
              native_ref["repository_id"] == settings.repository_id and
              present?(native_ref["issue_id"]) and
              Enum.sort(Map.keys(native_ref)) ==
                ["issue_id", "issue_number", "repository", "repository_id"]) or
             {:error, :github_issue_context_mismatch} do
      checker_opts =
        Keyword.take(opts, [:tracker_settings]) ++
          if(Keyword.has_key?(opts, :github_client),
            do: [
              request_fun: fn method, path, params, body, _settings ->
                request(method, path, params, body, opts)
              end
            ],
            else: []
          )

      run_scope_checker(Keyword.get(opts, :scope_checker), native_ref, checker_opts, opts)
    else
      nil -> {:error, :missing_github_issue_context}
      {:error, _} = error -> error
      _ -> {:error, :github_issue_context_mismatch}
    end
  end

  defp run_scope_checker(nil, native_ref, checker_opts, _opts),
    do: Client.issue_snapshot(native_ref, checker_opts)

  defp run_scope_checker(checker, native_ref, checker_opts, opts) do
    with :ok <- checker.(native_ref, checker_opts), do: {:ok, Keyword.fetch!(opts, :issue)}
  end

  defp allowed_label(labels, requested) do
    if requested in labels, do: {:ok, requested}, else: {:error, :label_not_allowed}
  end

  defp transition_labels(labels, workflow_labels, target) when is_list(labels) do
    names =
      Enum.map(labels, fn
        name when is_binary(name) -> name
        _ -> nil
      end)

    if Enum.any?(names, &is_nil/1) do
      {:error, :github_unknown_payload}
    else
      {:ok, Enum.reject(names, &(&1 in workflow_labels)) ++ [target]}
    end
  end

  defp transition_labels(_, _, _), do: {:error, :github_unknown_payload}

  defp tool_settings(opts) do
    case Keyword.get(opts, :tracker_settings) do
      %{provider: provider} when is_map(provider) ->
        with repo when is_binary(repo) <- provider["repo"],
             repository_id when is_binary(repository_id) <- provider["repository_id"],
             base_branch when is_binary(base_branch) <- provider["base_branch"],
             actor when is_binary(actor) <- provider["actor_id"],
             labels when is_list(labels) and labels != [] <- provider["workflow_labels"],
             true <- Enum.all?([repo, repository_id, base_branch, actor], &present?/1),
             true <- Enum.all?(labels, &present?/1),
             true <- Enum.uniq(Enum.map(labels, &normalize/1)) == Enum.map(labels, &normalize/1) do
          {:ok,
           %{
             repo: String.trim(repo),
             repository_id: String.trim(repository_id),
             base_branch: String.trim(base_branch),
             actor_id: String.trim(actor),
             workflow_labels: Enum.map(labels, &String.trim/1)
           }}
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
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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

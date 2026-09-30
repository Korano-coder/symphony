defmodule SymphonyElixir.GitHub.Client do
  @moduledoc "Fail-closed GitHub Issues client scoped to one configured repository."

  alias SymphonyElixir.{Config, Tracker.Issue}

  @rest_url "https://api.github.com"
  @page_size 100
  @default_max_pages 20
  @default_timeout_ms 30_000
  @workflow_labels ~w(symphony:ready symphony:in-progress symphony:human-review symphony:done)
  @priority_labels %{"priority:p0" => 0, "priority:p1" => 1, "priority:p2" => 2}

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(settings), do: with({:ok, _} <- parse_settings(settings), do: :ok)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(settings) do
    provider = provider(settings)

    ["GITHUB_TOKEN", "GH_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_ENTERPRISE_TOKEN" | env_names([provider["token"]])]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) when is_list(states),
    do: fetch(states, nil, Config.settings!().tracker, &rest_request/5)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(ids) when is_list(ids),
    do: fetch([], MapSet.new(ids), Config.settings!().tracker, &rest_request/5)

  @spec issue_in_scope?(map(), keyword()) :: :ok | {:error, term()}
  def issue_in_scope?(native_ref, opts \\ []) when is_map(native_ref) do
    with {:ok, _issue} <- issue_snapshot(native_ref, opts), do: :ok
  end

  @spec issue_snapshot(map(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def issue_snapshot(native_ref, opts \\ []) when is_map(native_ref) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &rest_request/5)

    with {:ok, settings} <- parse_settings(tracker),
         :ok <- native_identity(native_ref, settings),
         {:ok, %{status: 200, body: repository}} <- request_fun.("GET", "/repos/#{settings.repo}", %{}, nil, settings),
         :ok <- repository_identity(repository, settings),
         {:ok, %{status: 200, body: raw}} <- request_fun.("GET", issue_path(settings, native_ref["issue_number"]), %{}, nil, settings),
         {:ok, issue} <- normalize_issue(raw, settings, request_fun),
         true <- raw["number"] == native_ref["issue_number"] or {:error, :github_issue_identity_mismatch},
         true <- issue.id == native_ref["issue_id"] or {:error, :github_issue_identity_mismatch},
         true <-
           (raw["state"] == "open" and issue.state in ["symphony:ready", "symphony:in-progress"] and
              Enum.all?(issue.blocked_by, &(&1["state"] == "closed"))) or
             {:error, :github_issue_not_eligible} do
      {:ok, issue}
    else
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:github_permission_denied, status}}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :github_unknown_payload}
    end
  end

  @doc false
  @spec fetch_for_test([String.t()], [String.t()] | nil, map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_for_test(states, ids, settings, request_fun),
    do: fetch(states, if(is_list(ids), do: MapSet.new(ids)), settings, request_fun)

  @spec rest(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def rest(method, path, params, body, opts \\ []) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &rest_request/5)

    with {:ok, settings} <- parse_settings(tracker),
         true <- scoped_path?(method, path, settings) or {:error, :github_scope_violation} do
      request_fun.(method, path, params, body, settings)
    end
  end

  defp fetch([], nil, _tracker, _request_fun), do: {:ok, []}

  defp fetch(states, %MapSet{} = ids, tracker, request_fun) do
    if MapSet.size(ids) == 0,
      do: {:ok, []},
      else: fetch_nonempty(states, ids, tracker, request_fun)
  end

  defp fetch(states, ids, tracker, request_fun), do: fetch_nonempty(states, ids, tracker, request_fun)

  defp fetch_nonempty(states, ids, tracker, request_fun) do
    with {:ok, settings} <- parse_settings(tracker),
         {:ok, %{status: 200, body: repository}} <- request_fun.("GET", "/repos/#{settings.repo}", %{}, nil, settings),
         :ok <- repository_identity(repository, settings) do
      list_pages(settings, MapSet.new(states), ids, if(is_nil(ids), do: "open", else: "all"), 1, request_fun, [], MapSet.new())
    else
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:github_permission_denied, status}}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp list_pages(settings, states, ids, api_state, page, request_fun, acc, seen) when page <= settings.max_pages do
    params = %{"state" => api_state, "per_page" => @page_size, "page" => page}

    with {:ok, %{status: 200, body: nodes}} when is_list(nodes) <- request_fun.("GET", "/repos/#{settings.repo}/issues", params, nil, settings),
         {:ok, issues, next_seen} <- normalize_page(nodes, settings, request_fun, states, ids, seen) do
      next_acc = acc ++ issues

      if length(nodes) < @page_size,
        do: {:ok, next_acc},
        else: list_pages(settings, states, ids, api_state, page + 1, request_fun, next_acc, next_seen)
    else
      {:ok, %{status: 429}} -> {:error, :github_rate_limited}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:github_permission_denied, status}}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp list_pages(_, _, _, _, _, _, _, _), do: {:error, :github_pagination_limit}

  defp normalize_page(nodes, settings, request_fun, states, ids, seen) do
    Enum.reduce_while(nodes, {:ok, [], seen}, fn raw, result ->
      normalize_page_item(raw, result, settings, request_fun, states, ids)
    end)
  end

  defp normalize_page_item(%{"pull_request" => pull_request}, result, _, _, _, _)
       when is_map(pull_request),
       do: {:cont, result}

  defp normalize_page_item(raw, result, settings, request_fun, states, ids) do
    if candidate?(raw, ids),
      do: normalize_candidate(raw, result, settings, request_fun, states, ids),
      else: {:cont, result}
  end

  defp normalize_candidate(raw, {:ok, acc, seen}, settings, request_fun, states, ids) do
    with {:ok, issue} <- normalize_issue(raw, settings, request_fun),
         false <- MapSet.member?(seen, issue.id) do
      selected = if(is_nil(ids), do: MapSet.member?(states, issue.state), else: true)

      {:cont, {:ok, if(selected, do: acc ++ [issue], else: acc), MapSet.put(seen, issue.id)}}
    else
      true -> {:halt, {:error, :github_ambiguous_issue}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp candidate?(raw, %MapSet{} = ids) when is_map(raw), do: MapSet.member?(ids, raw["node_id"])

  defp candidate?(%{"labels" => labels}, nil) when is_list(labels),
    do: Enum.any?(labels, &match?(%{"name" => name} when name in @workflow_labels, &1))

  defp candidate?(_, _), do: false

  defp normalize_issue(raw, settings, request_fun) when is_map(raw) do
    with true <- not is_map(raw["pull_request"]) or {:error, :github_pull_request_not_allowed},
         :ok <- issue_shape(raw),
         :ok <- issue_repository(raw, settings),
         {:ok, labels} <- labels(raw["labels"]),
         {:ok, workflow} <- exact_workflow(labels),
         {:ok, priority} <- exact_priority(labels),
         {:ok, blockers} <- blockers(raw, settings, request_fun),
         {:ok, created_at} <- datetime(raw["created_at"]),
         {:ok, updated_at} <- datetime(raw["updated_at"]) do
      dispatchable = raw["state"] == "open" and workflow == "symphony:ready" and Enum.all?(blockers, &(&1["state"] == "closed"))

      {:ok,
       %Issue{
         id: raw["node_id"],
         native_ref: %{"repository_id" => settings.repository_id, "repository" => settings.repo, "issue_id" => raw["node_id"], "issue_number" => raw["number"]},
         identifier: "GH-#{raw["number"]}",
         title: raw["title"],
         description: raw["body"],
         priority: priority,
         state: workflow,
         url: raw["html_url"],
         assignee_id: assignee(raw),
         labels: labels,
         blocked_by: blockers,
         dispatchable: dispatchable,
         created_at: created_at,
         updated_at: updated_at
       }}
    end
  end

  defp normalize_issue(_, _, _), do: {:error, :github_unknown_payload}

  defp blockers(raw, settings, request_fun) do
    path = issue_path(settings, raw["number"]) <> "/dependencies/blocked_by"

    with {:ok, %{status: 200, body: nodes}} when is_list(nodes) <-
           request_fun.("GET", path, %{"per_page" => @page_size}, nil, settings),
         true <- length(nodes) < @page_size or {:error, :github_blocker_pagination_ambiguous} do
      normalize_blockers(nodes)
    else
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:github_permission_denied, status}}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp normalize_blockers(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn
      %{"node_id" => id, "number" => number, "state" => state, "repository_url" => repo_url}, {:ok, acc}
      when is_binary(id) and is_integer(number) and state in ["open", "closed"] ->
        blocker = %{"id" => id, "identifier" => "#{repo_url}##{number}", "state" => state}
        {:cont, {:ok, acc ++ [blocker]}}

      _, _ ->
        {:halt, {:error, :github_unknown_payload}}
    end)
  end

  defp issue_shape(raw) do
    required = [raw["node_id"], raw["title"], raw["html_url"], raw["repository_url"]]

    if is_integer(raw["number"]) and raw["number"] > 0 and Enum.all?(required, &present?/1) and raw["state"] in ["open", "closed"] and
         (is_binary(raw["body"]) or is_nil(raw["body"])),
       do: :ok,
       else: {:error, :github_unknown_payload}
  end

  defp issue_repository(%{"repository_url" => url}, settings) do
    if url == @rest_url <> "/repos/" <> settings.repo, do: :ok, else: {:error, :github_repository_scope_mismatch}
  end

  defp labels(nodes) when is_list(nodes) do
    names =
      Enum.map(nodes, fn
        %{"name" => name} when is_binary(name) -> name
        _ -> nil
      end)

    if Enum.any?(names, &is_nil/1) or Enum.uniq(names) != names, do: {:error, :github_malformed_labels}, else: {:ok, names}
  end

  defp labels(_), do: {:error, :github_malformed_labels}
  defp exact_workflow(labels), do: exact_one(Enum.filter(labels, &(&1 in @workflow_labels)), :github_missing_workflow_label, :github_conflicting_workflow_labels)

  defp exact_priority(labels) do
    with {:ok, label} <- exact_one(Enum.filter(labels, &Map.has_key?(@priority_labels, &1)), :github_missing_priority_label, :github_conflicting_priority_labels),
         do: {:ok, @priority_labels[label]}
  end

  defp exact_one([value], _, _), do: {:ok, value}
  defp exact_one([], missing, _), do: {:error, missing}
  defp exact_one(_, _, conflicting), do: {:error, conflicting}
  defp assignee(%{"assignee" => %{"node_id" => id}}) when is_binary(id), do: id
  defp assignee(_), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, result, _} -> {:ok, result}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp datetime(_), do: {:error, :github_unknown_payload}

  defp native_identity(native_ref, settings) do
    keys = ["issue_id", "issue_number", "repository", "repository_id"]

    valid =
      native_ref["repository"] == settings.repo and native_ref["repository_id"] == settings.repository_id and
        is_integer(native_ref["issue_number"]) and native_ref["issue_number"] > 0 and present?(native_ref["issue_id"]) and
        Enum.sort(Map.keys(native_ref)) == keys

    if valid, do: :ok, else: {:error, :github_issue_context_mismatch}
  end

  defp repository_identity(%{"node_id" => id, "full_name" => repo}, %{repository_id: id, repo: repo}), do: :ok
  defp repository_identity(_, _), do: {:error, :github_repository_scope_mismatch}

  defp parse_settings(tracker) do
    value = provider(tracker)

    with :ok <- reject_project_configuration(tracker),
         {:ok, repo} <- repo(value["repo"]),
         {:ok, repository_id} <- id(value["repository_id"], :missing_github_repository_id),
         {:ok, base_branch} <- branch(value["base_branch"]),
         {:ok, actor_id} <- id(value["actor_id"], :missing_github_actor_id),
         true <- value["workflow_labels"] == @workflow_labels or {:error, :invalid_github_workflow_labels},
         true <- value["priority_labels"] == Map.keys(@priority_labels) or {:error, :invalid_github_priority_labels},
         {:ok, max_pages} <- bounded(value["max_pages"], @default_max_pages, 1, 100, :invalid_github_max_pages),
         {:ok, timeout_ms} <- bounded(value["timeout_ms"], @default_timeout_ms, 1_000, 120_000, :invalid_github_timeout),
         token when is_binary(token) and token != "" <- secret(value["token"]) do
      {:ok,
       %{
         repo: repo,
         repository_id: repository_id,
         base_branch: base_branch,
         actor_id: actor_id,
         workflow_labels: @workflow_labels,
         max_pages: max_pages,
         timeout_ms: timeout_ms,
         token: token
       }}
    else
      nil -> {:error, :missing_github_token}
      "" -> {:error, :missing_github_token}
      {:error, _} = error -> error
      _ -> {:error, :invalid_github_settings}
    end
  end

  defp provider(%{provider: value}) when is_map(value), do: value
  defp provider(_), do: %{}

  defp reject_project_configuration(value) do
    if project_configuration?(value),
      do: {:error, :github_project_configuration_not_allowed},
      else: :ok
  end

  defp project_configuration?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} -> project_key?(key) or project_configuration?(nested) end)
  end

  defp project_configuration?(value) when is_list(value), do: Enum.any?(value, &project_configuration?/1)
  defp project_configuration?(_value), do: false
  defp project_key?(key) when is_binary(key), do: String.contains?(String.downcase(key), "project")
  defp project_key?(key) when is_atom(key), do: key |> Atom.to_string() |> project_key?()
  defp project_key?(_key), do: false

  defp repo(value) when is_binary(value), do: if(String.match?(String.trim(value), ~r/^[^\s\/]+\/[^\s\/]+$/), do: {:ok, String.trim(value)}, else: {:error, :invalid_github_repo})
  defp repo(_), do: {:error, :missing_github_repo}
  defp branch(value) when is_binary(value), do: if(present?(value), do: {:ok, String.trim(value)}, else: {:error, :invalid_github_base_branch})
  defp branch(_), do: {:error, :missing_github_base_branch}
  defp id(value, error) when is_binary(value), do: if(present?(value), do: {:ok, String.trim(value)}, else: {:error, error})
  defp id(_, error), do: {:error, error}
  defp bounded(nil, default, _, _, _), do: {:ok, default}
  defp bounded(value, _, min, max, _) when is_integer(value) and value in min..max//1, do: {:ok, value}
  defp bounded(_, _, _, _, error), do: {:error, error}
  defp secret("$" <> name), do: if(String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/), do: System.get_env(name))
  defp secret(value) when is_binary(value), do: String.trim(value)
  defp secret(_), do: nil

  defp env_names(values),
    do:
      Enum.flat_map(values, fn
        "$" <> name -> if(String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/), do: [name], else: [])
        _ -> []
      end)

  defp rest_request(method, path, params, body, settings) do
    opts = [
      method: %{"GET" => :get, "POST" => :post, "PATCH" => :patch}[method],
      url: @rest_url <> path,
      headers: headers(settings.token),
      params: params,
      connect_options: [timeout: settings.timeout_ms],
      receive_timeout: settings.timeout_ms
    ]

    request(if(is_nil(body), do: opts, else: Keyword.put(opts, :json, body)))
  end

  defp request(opts) do
    case Req.request(opts) do
      {:ok, %{status: 429}} -> {:error, :github_rate_limited}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:github_permission_denied, status}}
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :github_timeout}
      {:error, _} -> {:error, :github_transport}
    end
  end

  defp headers(token), do: [{"Accept", "application/vnd.github+json"}, {"Authorization", "Bearer #{token}"}, {"X-GitHub-Api-Version", "2022-11-28"}, {"User-Agent", "symphony"}]

  defp scoped_path?(method, path, settings) do
    safe = not String.contains?(path, ["..", "?", "#", "\n", "\r"])
    repo = Regex.escape(settings.repo)

    allowed =
      case method do
        "GET" -> Regex.match?(~r{^/repos/#{repo}(?:$|/issues(?:$|/\d+$|/\d+/comments$|/\d+/dependencies/blocked_by$)|/pulls/\d+$)}, path)
        "POST" -> Regex.match?(~r{^/repos/#{repo}/issues/\d+/comments$}, path)
        "PATCH" -> Regex.match?(~r{^/repos/#{repo}/issues(?:/\d+|/comments/\d+)$}, path)
        _ -> false
      end

    safe and allowed
  end

  defp issue_path(settings, number), do: "/repos/#{settings.repo}/issues/#{number}"
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

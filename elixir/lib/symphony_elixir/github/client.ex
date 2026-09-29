defmodule SymphonyElixir.GitHub.Client do
  @moduledoc "Fail-closed GitHub Projects v2 client for one repository and project."

  alias SymphonyElixir.{Config, Tracker.Issue}

  @graphql_url "https://api.github.com/graphql"
  @rest_url "https://api.github.com"
  @page_size 50
  @nested_page_size 100
  @default_max_pages 20
  @default_timeout_ms 30_000

  @project_query """
  query SymphonyGitHubProject($projectId: ID!, $first: Int!, $after: String, $nestedFirst: Int!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        id
        items(first: $first, after: $after) {
          nodes {
            id type
            content {
              ... on Issue {
                id number title body state url createdAt updatedAt
                repository { id nameWithOwner }
                assignees(first: 1) { nodes { id } pageInfo { hasNextPage } }
                labels(first: $nestedFirst) { nodes { id name } pageInfo { hasNextPage } }
                blockedBy(first: $nestedFirst) {
                  nodes { id number state repository { id nameWithOwner } }
                  pageInfo { hasNextPage }
                }
              }
            }
            fieldValues(first: $nestedFirst) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  optionId name field { ... on ProjectV2SingleSelectField { id } }
                }
              }
              pageInfo { hasNextPage }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    rateLimit { remaining resetAt }
  }
  """

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(settings), do: with({:ok, _} <- parse_settings(settings), do: :ok)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(settings) do
    provider = provider(settings)

    [
      "GITHUB_TOKEN",
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GH_ENTERPRISE_TOKEN"
      | env_names([provider["token"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) when is_list(states),
    do: fetch(states, nil, Config.settings!().tracker, &graphql_request/3)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(ids) when is_list(ids),
    do: fetch([], MapSet.new(ids), Config.settings!().tracker, &graphql_request/3)

  @spec issue_in_scope?(map(), keyword()) :: :ok | {:error, term()}
  def issue_in_scope?(native_ref, opts \\ []) when is_map(native_ref) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :graphql_fun, &graphql_request/3)

    with {:ok, settings} <- parse_settings(tracker),
         {:ok, issues} <- fetch(Map.values(settings.status_options), nil, tracker, request_fun),
         true <-
           Enum.any?(issues, &(&1.native_ref == native_ref)) or
             {:error, :github_issue_out_of_scope} do
      :ok
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

  defp fetch(states, nil, tracker, request_fun),
    do: fetch_nonempty(states, nil, tracker, request_fun)

  defp fetch_nonempty(states, ids, tracker, request_fun) do
    with {:ok, settings} <- parse_settings(tracker) do
      fetch_page(settings, MapSet.new(states, &normalize/1), ids, nil, 1, request_fun, [], MapSet.new())
    end
  end

  defp fetch_page(settings, states, ids, cursor, page, request_fun, acc, seen)
       when page <= settings.max_pages do
    variables = %{
      "projectId" => settings.project_id,
      "first" => @page_size,
      "after" => cursor,
      "nestedFirst" => @nested_page_size
    }

    with {:ok, %{status: 200, body: body}} <- request_fun.(@project_query, variables, settings),
         {:ok, data} <- decode_graphql(body),
         :ok <- rate_limit(data["rateLimit"]),
         {:ok, nodes, page_info} <- project_page(data, settings.project_id),
         {:ok, issues, next_seen} <- normalize_page(nodes, settings, states, ids, seen),
         {:ok, next} <- next_cursor(page_info, cursor) do
      if is_nil(next),
        do: {:ok, acc ++ issues},
        else: fetch_page(settings, states, ids, next, page + 1, request_fun, acc ++ issues, next_seen)
    else
      {:ok, %{status: 429}} -> {:error, :github_rate_limited}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:github_permission_denied, status}}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp fetch_page(_settings, _states, _ids, _cursor, _page, _request_fun, _acc, _seen),
    do: {:error, :github_pagination_limit}

  defp decode_graphql(%{"errors" => errors}) when is_list(errors) and errors != [] do
    if Enum.any?(errors, &rate_limit_error?/1),
      do: {:error, :github_rate_limited},
      else: {:error, :github_graphql_error}
  end

  defp decode_graphql(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp decode_graphql(_), do: {:error, :github_unknown_payload}

  defp project_page(
         %{"node" => %{"id" => id, "items" => %{"nodes" => nodes, "pageInfo" => page_info}}},
         id
       )
       when is_list(nodes) and is_map(page_info),
       do: {:ok, nodes, page_info}

  defp project_page(_, _), do: {:error, :github_project_scope_mismatch}

  defp normalize_page(nodes, settings, states, ids, seen) do
    Enum.reduce_while(nodes, {:ok, [], seen}, fn raw, {:ok, acc, current_seen} ->
      case normalize_item(raw, settings) do
        {:ok, issue} ->
          accumulate_issue(issue, acc, current_seen, states, ids)

        {:skip, :pull_request} ->
          {:cont, {:ok, acc, current_seen}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp accumulate_issue(issue, acc, seen, states, ids) do
    if MapSet.member?(seen, issue.id) do
      {:halt, {:error, :github_ambiguous_project_membership}}
    else
      selected =
        if is_nil(ids),
          do: MapSet.member?(states, normalize(issue.state)),
          else: MapSet.member?(ids, issue.id)

      {:cont, {:ok, if(selected, do: acc ++ [issue], else: acc), MapSet.put(seen, issue.id)}}
    end
  end

  defp normalize_item(%{"type" => "PULL_REQUEST"}, _), do: {:skip, :pull_request}

  defp normalize_item(%{"type" => type}, _) when type in ["DRAFT_ISSUE", "REDACTED"],
    do: {:error, :github_unsupported_project_item}

  defp normalize_item(%{"id" => item_id, "type" => "ISSUE", "content" => issue} = item, settings)
       when is_binary(item_id) and is_map(issue) do
    with :ok <- issue_shape(issue),
         :ok <- repository_scope(issue["repository"], settings),
         {:ok, labels} <- labels(issue["labels"]),
         {:ok, blockers} <- blockers(issue["blockedBy"]),
         {:ok, values} <- field_values(item["fieldValues"]),
         {:ok, status} <- select_value(values, settings.status_field_id, settings.status_options),
         {:ok, priority} <- priority_value(values, settings.priority_field_id, settings.priority_options),
         {:ok, assignee} <- assignee(issue["assignees"]),
         {:ok, created_at} <- datetime(issue["createdAt"]),
         {:ok, updated_at} <- datetime(issue["updatedAt"]) do
      blocked = Enum.any?(blockers, &(&1["state"] != "closed"))
      ready = settings.ready_label in labels and MapSet.member?(settings.ready_statuses, normalize(status))

      {:ok,
       %Issue{
         id: item_id,
         native_ref: %{
           "project_id" => settings.project_id,
           "project_item_id" => item_id,
           "repository_id" => settings.repository_id,
           "repository" => settings.repo,
           "issue_id" => issue["id"],
           "issue_number" => issue["number"]
         },
         identifier: "GH-#{issue["number"]}",
         title: issue["title"],
         description: issue["body"],
         priority: priority,
         state: status,
         url: issue["url"],
         assignee_id: assignee,
         labels: labels,
         blocked_by: blockers,
         dispatchable: issue["state"] == "OPEN" and ready and not blocked,
         created_at: created_at,
         updated_at: updated_at
       }}
    end
  end

  defp normalize_item(_, _), do: {:error, :github_unknown_payload}

  defp issue_shape(issue) do
    strings = [issue["id"], issue["title"], issue["url"]]

    if is_integer(issue["number"]) and issue["number"] > 0 and
         Enum.all?(strings, &present?/1) and issue["state"] in ["OPEN", "CLOSED"] and
         (is_binary(issue["body"]) or is_nil(issue["body"])),
       do: :ok,
       else: {:error, :github_unknown_payload}
  end

  defp repository_scope(%{"id" => id, "nameWithOwner" => repo}, %{repository_id: id, repo: repo}),
    do: :ok

  defp repository_scope(_, _), do: {:error, :github_repository_scope_mismatch}

  defp labels(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}})
       when is_list(nodes) do
    names =
      Enum.map(nodes, fn
        %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
          name |> String.trim() |> String.downcase()

        _ ->
          nil
      end)

    if Enum.any?(names, &is_nil/1), do: {:error, :github_unknown_payload}, else: {:ok, Enum.uniq(names)}
  end

  defp labels(_), do: {:error, :github_nested_pagination}

  defp blockers(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}})
       when is_list(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn blocker, {:ok, acc} ->
      case blocker do
        %{
          "id" => id,
          "number" => number,
          "state" => state,
          "repository" => %{"id" => repo_id, "nameWithOwner" => repo}
        }
        when is_binary(id) and is_integer(number) and state in ["OPEN", "CLOSED"] and
               is_binary(repo_id) and is_binary(repo) ->
          ref = %{"id" => id, "identifier" => "#{repo}##{number}", "state" => normalize(state)}
          {:cont, {:ok, acc ++ [ref]}}

        _ ->
          {:halt, {:error, :github_unknown_payload}}
      end
    end)
  end

  defp blockers(_), do: {:error, :github_nested_pagination}

  defp field_values(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}})
       when is_list(nodes),
       do: {:ok, nodes}

  defp field_values(_), do: {:error, :github_nested_pagination}

  defp select_value(values, field_id, options) do
    case Enum.filter(values, &(get_in(&1, ["field", "id"]) == field_id)) do
      [%{"optionId" => option, "name" => name}] when is_binary(option) and is_binary(name) ->
        if options[option] == name, do: {:ok, name}, else: {:error, :github_unknown_project_option}

      [] ->
        {:error, :github_missing_project_field}

      _ ->
        {:error, :github_ambiguous_project_field}
    end
  end

  defp priority_value(values, field_id, options) do
    case Enum.filter(values, &(get_in(&1, ["field", "id"]) == field_id)) do
      [%{"optionId" => option}] when is_binary(option) ->
        case Map.fetch(options, option) do
          {:ok, priority} -> {:ok, priority}
          :error -> {:error, :github_unknown_project_option}
        end

      [] ->
        {:error, :github_missing_project_field}

      _ ->
        {:error, :github_ambiguous_project_field}
    end
  end

  defp assignee(%{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}), do: {:ok, nil}

  defp assignee(%{"nodes" => [%{"id" => id}], "pageInfo" => %{"hasNextPage" => false}})
       when is_binary(id),
       do: {:ok, id}

  defp assignee(%{"pageInfo" => %{"hasNextPage" => true}}), do: {:error, :github_ambiguous_assignee}
  defp assignee(_), do: {:error, :github_unknown_payload}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, result, _} -> {:ok, result}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp datetime(_), do: {:error, :github_unknown_payload}

  defp next_cursor(%{"hasNextPage" => false}, _), do: {:ok, nil}

  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor}, previous)
       when is_binary(cursor) and cursor != "" and cursor != previous,
       do: {:ok, cursor}

  defp next_cursor(_, _), do: {:error, :github_pagination_ambiguous}

  defp rate_limit(%{"remaining" => remaining}) when is_integer(remaining) and remaining > 0, do: :ok
  defp rate_limit(%{"remaining" => 0}), do: {:error, :github_rate_limited}
  defp rate_limit(_), do: {:error, :github_unknown_payload}

  defp rate_limit_error?(%{"type" => type}) when type in ["RATE_LIMITED", "RATE_LIMITED_BY_IP"],
    do: true

  defp rate_limit_error?(%{"message" => message}) when is_binary(message),
    do: String.contains?(String.downcase(message), "rate limit")

  defp rate_limit_error?(_), do: false

  defp parse_settings(tracker) do
    value = provider(tracker)

    with {:ok, repo} <- repo(value["repo"]),
         {:ok, repository_id} <- id(value["repository_id"], :missing_github_repository_id),
         {:ok, project_id} <- id(value["project_id"], :missing_github_project_id),
         {:ok, base_branch} <- branch(value["base_branch"]),
         {:ok, ready_label} <- label(value["ready_label"]),
         {:ok, status_field_id} <- id(value["status_field_id"], :missing_github_status_field_id),
         {:ok, status_options} <- string_map(value["status_options"], :invalid_github_status_options),
         {:ok, ready_statuses} <- string_set(value["ready_statuses"], :invalid_github_ready_statuses),
         true <-
           Enum.all?(ready_statuses, &(&1 in Enum.map(Map.values(status_options), fn name -> normalize(name) end))) or
             {:error, :invalid_github_ready_statuses},
         {:ok, priority_field_id} <- id(value["priority_field_id"], :missing_github_priority_field_id),
         {:ok, priority_options} <- integer_map(value["priority_options"]),
         {:ok, workflow_labels} <- string_set(value["workflow_labels"], :invalid_github_workflow_labels),
         {:ok, actor_id} <- id(value["actor_id"], :missing_github_actor_id),
         {:ok, max_pages} <- bounded(value["max_pages"], @default_max_pages, 1, 100, :invalid_github_max_pages),
         {:ok, timeout_ms} <- bounded(value["timeout_ms"], @default_timeout_ms, 1_000, 120_000, :invalid_github_timeout),
         token when is_binary(token) and token != "" <- secret(value["token"]) do
      {:ok,
       %{
         repo: repo,
         repository_id: repository_id,
         project_id: project_id,
         base_branch: base_branch,
         ready_label: normalize(ready_label),
         status_field_id: status_field_id,
         status_options: status_options,
         ready_statuses: ready_statuses,
         priority_field_id: priority_field_id,
         priority_options: priority_options,
         workflow_labels: workflow_labels,
         actor_id: actor_id,
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

  defp repo(value) when is_binary(value) do
    value = String.trim(value)
    if String.match?(value, ~r/^[^\s\/]+\/[^\s\/]+$/), do: {:ok, value}, else: {:error, :invalid_github_repo}
  end

  defp repo(_), do: {:error, :missing_github_repo}
  defp branch(value) when is_binary(value), do: if(present?(value), do: {:ok, String.trim(value)}, else: {:error, :invalid_github_base_branch})
  defp branch(_), do: {:error, :missing_github_base_branch}
  defp id(value, error) when is_binary(value), do: if(present?(value), do: {:ok, String.trim(value)}, else: {:error, error})
  defp id(_, error), do: {:error, error}
  defp label(value) when is_binary(value), do: if(present?(value), do: {:ok, value}, else: {:error, :invalid_github_ready_label})
  defp label(_), do: {:error, :missing_github_ready_label}

  defp string_map(value, error) when is_map(value) and map_size(value) > 0 do
    entries = Enum.map(value, fn {key, item} -> {key, if(is_binary(item), do: String.trim(item))} end)
    normalized_values = Enum.map(entries, fn {_key, item} -> normalize(item) end)

    if Enum.all?(entries, fn {key, item} -> present?(key) and present?(item) end) and
         Enum.uniq(normalized_values) == normalized_values,
       do: {:ok, Map.new(entries)},
       else: {:error, error}
  end

  defp string_map(_, error), do: {:error, error}

  defp integer_map(value) when is_map(value) and map_size(value) > 0 do
    if Enum.all?(value, fn {key, item} -> present?(key) and is_integer(item) and item >= 0 end), do: {:ok, value}, else: {:error, :invalid_github_priority_options}
  end

  defp integer_map(_), do: {:error, :invalid_github_priority_options}

  defp string_set(value, error) when is_list(value) and value != [] do
    normalized = Enum.map(value, &normalize/1)

    if Enum.all?(value, &present?/1) and Enum.uniq(normalized) == normalized,
      do: {:ok, MapSet.new(normalized)},
      else: {:error, error}
  end

  defp string_set(_, error), do: {:error, error}
  defp bounded(nil, default, _, _, _), do: {:ok, default}

  defp bounded(value, _, min, max, _) when is_integer(value) and value in min..max//1,
    do: {:ok, value}

  defp bounded(_, _, _, _, error), do: {:error, error}

  defp secret("$" <> name) do
    if String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/), do: System.get_env(name), else: nil
  end

  defp secret(value) when is_binary(value), do: String.trim(value)
  defp secret(_), do: nil

  defp env_names(values) do
    Enum.flat_map(values, fn
      "$" <> name -> if String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/), do: [name], else: []
      _ -> []
    end)
  end

  defp graphql_request(query, variables, settings) do
    request(
      url: @graphql_url,
      headers: headers(settings.token),
      json: %{"query" => query, "variables" => variables},
      connect_options: [timeout: settings.timeout_ms],
      receive_timeout: settings.timeout_ms
    )
  end

  defp rest_request(method, path, params, body, settings) do
    method_atom = %{"GET" => :get, "POST" => :post, "PATCH" => :patch}[method]

    opts = [
      method: method_atom,
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
      {:error, _reason} -> {:error, :github_transport}
    end
  end

  defp headers(token),
    do: [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"User-Agent", "symphony"}
    ]

  defp scoped_path?(method, path, settings) do
    safe = not String.contains?(path, ["..", "?", "#", "\n", "\r"])
    escaped_repo = Regex.escape(settings.repo)

    allowed =
      case method do
        "GET" -> Regex.match?(~r{^/repos/#{escaped_repo}/(?:issues/\d+/comments|pulls/\d+)$}, path)
        "POST" -> Regex.match?(~r{^/repos/#{escaped_repo}/issues/\d+/(?:comments|labels)$}, path)
        "PATCH" -> Regex.match?(~r{^/repos/#{escaped_repo}/issues/comments/\d+$}, path)
        _ -> false
      end

    safe and allowed
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

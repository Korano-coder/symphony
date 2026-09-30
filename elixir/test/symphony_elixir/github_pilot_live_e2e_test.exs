defmodule SymphonyElixir.GitHub.PilotLiveE2ETest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitHub.{AgentTool, Client}

  @moduletag :live_e2e
  @moduletag timeout: 180_000
  @skip if(System.get_env("SYMPHONY_RUN_GITHUB_PILOT_LIVE_E2E") != "1", do: "set SYMPHONY_RUN_GITHUB_PILOT_LIVE_E2E=1")

  @tag skip: @skip
  test "proves the repository-only fine-grained PAT contract" do
    settings = settings_from_env!()
    number = required_integer_env!("SYMPHONY_LIVE_GITHUB_ISSUE_NUMBER")
    issue_id = required_env!("SYMPHONY_LIVE_GITHUB_ISSUE_NODE_ID")
    draft_pr_url = required_env!("SYMPHONY_LIVE_GITHUB_DRAFT_PR_URL")

    assert {:ok, [issue]} = Client.fetch_for_test(["symphony:ready"], [issue_id], settings, &request/5)
    assert issue.native_ref["issue_number"] == number
    assert is_binary(issue.description) and issue.description != ""
    assert issue.dispatchable

    opts = [tracker_settings: settings, issue: issue]
    body = "Safe repository-only live validation #{System.system_time(:second)}"

    assert {:ok, %{status: 201, body: %{"id" => comment_id}}} =
             request(
               "POST",
               "/repos/#{settings.provider["repo"]}/issues/#{number}/comments",
               %{},
               %{"body" => body},
               settings
             )

    assert {:ok, %{status: 200}} =
             request(
               "PATCH",
               "/repos/#{settings.provider["repo"]}/issues/comments/#{comment_id}",
               %{},
               %{"body" => body <> " updated"},
               settings
             )

    assert success?(AgentTool.execute("github_workpad", %{"issue_number" => number, "body" => body}, opts))
    assert success?(AgentTool.execute("github_workpad", %{"issue_number" => number, "body" => body <> " updated"}, opts))
    assert success?(AgentTool.execute("github_apply_workflow_label", %{"issue_number" => number, "label" => "symphony:in-progress"}, opts))
    assert success?(AgentTool.execute("github_apply_workflow_label", %{"issue_number" => number, "label" => "symphony:ready"}, opts))
    assert success?(AgentTool.execute("github_attach_draft_pr", %{"issue_number" => number, "pr_url" => draft_pr_url}, opts))

    assert_read_capabilities_denied!(settings.provider["repo"], fn path ->
      request_status_and_headers("GET", path, settings)
    end)

    # GitHub documents no read-only merge-authority probe. The test never sends a merge request.
    # Merge absence remains a configured-token contract supported, but not runtime-proven, by the
    # denied Contents and git-ref reads above.
  end

  test "repository owner role flags cannot satisfy or fail the token denial probes" do
    owner_repository_response = %{
      "permissions" => %{"admin" => true, "maintain" => true, "push" => true}
    }

    requester = fn path ->
      refute path == "/repos/owner/repo"
      assert owner_repository_response["permissions"]["admin"]
      {403, %{"x-accepted-github-permissions" => ["contents=read"]}}
    end

    assert :ok = assert_read_capabilities_denied!("owner/repo", requester)
    assert length(denial_probe_paths("owner/repo")) == 8
  end

  defp settings_from_env! do
    repo = required_env!("SYMPHONY_LIVE_GITHUB_REPO")
    repository_id = required_env!("SYMPHONY_LIVE_GITHUB_REPOSITORY_ID")

    assert_pilot_target!(
      repo,
      repository_id,
      required_env!("SYMPHONY_LIVE_GITHUB_EXPECTED_REPO"),
      required_env!("SYMPHONY_LIVE_GITHUB_EXPECTED_REPOSITORY_ID")
    )

    %{
      kind: "github",
      required_labels: ["symphony:ready"],
      active_states: ["symphony:ready", "symphony:in-progress"],
      terminal_states: ["symphony:human-review", "symphony:done"],
      provider: %{
        "repo" => repo,
        "repository_id" => repository_id,
        "base_branch" => required_env!("SYMPHONY_LIVE_GITHUB_BASE_BRANCH"),
        "token" => "$SYMPHONY_GITHUB_TOKEN",
        "workflow_labels" => ~w(symphony:ready symphony:in-progress symphony:human-review symphony:done),
        "priority_labels" => ~w(priority:p0 priority:p1 priority:p2),
        "actor_id" => required_env!("SYMPHONY_LIVE_GITHUB_ACTOR_ID")
      }
    }
  end

  defp request(method, path, params, body, _settings) do
    opts = [
      method: %{"GET" => :get, "POST" => :post, "PATCH" => :patch}[method],
      url: "https://api.github.com" <> path,
      params: params,
      headers: headers(),
      connect_options: [timeout: 30_000],
      receive_timeout: 30_000
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    case Req.request(opts) do
      {:ok, response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, _} ->
        {:error, :github_transport}
    end
  end

  defp assert_read_capabilities_denied!(repo, requester) do
    for path <- denial_probe_paths(repo) do
      {status, headers} = requester.(path)
      accepted_permissions = header_value(headers, "x-accepted-github-permissions")

      assert status in [403, 404],
             "expected #{path} to be denied, got HTTP #{status}; " <>
               "endpoint accepts #{inspect(accepted_permissions)}"
    end

    :ok
  end

  defp denial_probe_paths(repo) do
    [
      "/repos/#{repo}/contents/",
      "/repos/#{repo}/git/ref/heads/main",
      "/repos/#{repo}/git/ref/heads/staging",
      "/repos/#{repo}/git/matching-refs/heads/",
      "/repos/#{repo}/branches/main/protection",
      "/repos/#{repo}/rulesets",
      "/repos/#{repo}/actions/workflows",
      "/repos/#{repo}/actions/permissions"
    ]
  end

  defp request_status_and_headers(method, path, settings) do
    {:ok, %{status: status, headers: headers}} = request(method, path, %{}, nil, settings)
    {status, headers}
  end

  defp assert_pilot_target!(repo, repository_id, expected_repo, expected_repository_id) do
    repository_name = repo |> String.split("/") |> List.last() |> String.downcase()

    if repo != expected_repo or repository_id != expected_repository_id or
         repository_name == "renewable-fuels" do
      raise "GitHub live E2E target does not match the confirmed dedicated pilot repository"
    end
  end

  defp headers,
    do: [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{System.fetch_env!("SYMPHONY_GITHUB_TOKEN")}"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"User-Agent", "symphony-safe-pilot-e2e"}
    ]

  defp success?(%{"success" => true, "output" => output}), do: not String.contains?(output, System.fetch_env!("SYMPHONY_GITHUB_TOKEN"))
  defp header_value(headers, name) when is_map(headers), do: Map.get(headers, name, [])
  defp header_value(headers, name) when is_list(headers), do: for({key, value} <- headers, key == name, do: value)
  defp required_env!(name), do: System.fetch_env!(name)
  defp required_integer_env!(name), do: name |> required_env!() |> String.to_integer()
end

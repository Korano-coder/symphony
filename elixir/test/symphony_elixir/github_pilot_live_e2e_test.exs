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
    assert success?(AgentTool.execute("github_workpad", %{"issue_number" => number, "body" => body}, opts))
    assert success?(AgentTool.execute("github_workpad", %{"issue_number" => number, "body" => body <> " updated"}, opts))
    assert success?(AgentTool.execute("github_apply_workflow_label", %{"issue_number" => number, "label" => "symphony:in-progress"}, opts))
    assert success?(AgentTool.execute("github_apply_workflow_label", %{"issue_number" => number, "label" => "symphony:ready"}, opts))
    assert success?(AgentTool.execute("github_attach_draft_pr", %{"issue_number" => number, "pr_url" => draft_pr_url}, opts))

    repo = settings.provider["repo"]
    assert %{"permissions" => permissions} = get!("/repos/#{repo}", settings)
    refute permissions["admin"] or permissions["maintain"] or permissions["push"]

    for path <- ["/repos/#{repo}/contents/", "/repos/#{repo}/git/ref/heads/main", "/repos/#{repo}/git/ref/heads/staging", "/repos/#{repo}/branches/main/protection", "/repos/#{repo}/actions/workflows"] do
      assert request_status("GET", path, settings) in [403, 404]
    end

    assert project_access_unavailable?(settings)
    # No merge request is sent: Pull requests read-only plus `permissions.push == false` proves it
    # is unavailable without risking mutation of the pre-provisioned Draft PR.
  end

  defp settings_from_env! do
    %{
      kind: "github",
      required_labels: ["symphony:ready"],
      active_states: ["symphony:ready", "symphony:in-progress"],
      terminal_states: ["symphony:human-review", "symphony:done"],
      provider: %{
        "repo" => required_env!("SYMPHONY_LIVE_GITHUB_REPO"),
        "repository_id" => required_env!("SYMPHONY_LIVE_GITHUB_REPOSITORY_ID"),
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
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _} -> {:error, :github_transport}
    end
  end

  defp get!(path, settings) do
    {:ok, %{status: 200, body: body}} = request("GET", path, %{}, nil, settings)
    body
  end

  defp request_status(method, path, settings) do
    {:ok, %{status: status}} = request(method, path, %{}, nil, settings)
    status
  end

  defp project_access_unavailable?(_settings) do
    query = %{"query" => "query { viewer { projectsV2(first: 1) { totalCount } } }"}
    {:ok, response} = Req.post("https://api.github.com/graphql", headers: headers(), json: query)
    response.status in [401, 403] or match?(%{"errors" => [_ | _]}, response.body)
  end

  defp headers,
    do: [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{System.fetch_env!("SYMPHONY_GITHUB_TOKEN")}"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"User-Agent", "symphony-safe-pilot-e2e"}
    ]

  defp success?(%{"success" => true, "output" => output}), do: not String.contains?(output, System.fetch_env!("SYMPHONY_GITHUB_TOKEN"))
  defp required_env!(name), do: System.fetch_env!(name)
  defp required_integer_env!(name), do: name |> required_env!() |> String.to_integer()
end

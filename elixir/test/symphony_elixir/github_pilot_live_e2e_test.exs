defmodule SymphonyElixir.GitHub.PilotLiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{AgentTool, Client}

  @moduletag :live_e2e
  @moduletag timeout: 180_000
  @skip if(System.get_env("SYMPHONY_RUN_GITHUB_PILOT_LIVE_E2E") != "1",
          do: "set SYMPHONY_RUN_GITHUB_PILOT_LIVE_E2E=1 to enable the safe GitHub pilot test"
        )

  @tag skip: @skip
  test "validates one pre-provisioned issue, Project item, label, workpad, and Draft PR" do
    settings = settings_from_env!()
    item_id = required_env!("SYMPHONY_LIVE_GITHUB_PROJECT_ITEM_ID")
    issue_number = required_integer_env!("SYMPHONY_LIVE_GITHUB_ISSUE_NUMBER")
    draft_pr_url = required_env!("SYMPHONY_LIVE_GITHUB_DRAFT_PR_URL")
    workflow_label = required_env!("SYMPHONY_LIVE_GITHUB_WORKFLOW_LABEL")

    assert {:ok, [issue]} =
             Client.fetch_for_test(
               settings.active_states,
               [item_id],
               settings,
               &graphql_request/3
             )

    assert issue.id == item_id
    assert issue.native_ref["issue_number"] == issue_number
    assert issue.dispatchable

    opts = [tracker_settings: settings, issue: issue]
    body = "Safe live pilot validation #{System.system_time(:second)}"

    assert success?(AgentTool.execute("github_workpad", %{"issue_number" => issue_number, "body" => body}, opts))

    assert success?(
             AgentTool.execute(
               "github_apply_workflow_label",
               %{"issue_number" => issue_number, "label" => workflow_label},
               opts
             )
           )

    assert success?(
             AgentTool.execute(
               "github_attach_draft_pr",
               %{"issue_number" => issue_number, "pr_url" => draft_pr_url},
               opts
             )
           )

    assert Client.secret_environment_names(settings) |> Enum.member?("SYMPHONY_GITHUB_TOKEN")
    refute AgentTool.execute("github_workpad", %{"issue_number" => issue_number + 1, "body" => body}, opts)["success"]

    assert %{"state" => "open"} = rest_get!(settings, "/repos/#{settings.provider["repo"]}/issues/#{issue_number}")
    assert %{"draft" => true, "state" => "open"} = rest_get_url!(settings, draft_pr_url)
  end

  defp settings_from_env! do
    status_options = json_map_env!("SYMPHONY_LIVE_GITHUB_STATUS_OPTIONS")
    priority_options = json_map_env!("SYMPHONY_LIVE_GITHUB_PRIORITY_OPTIONS")
    workflow_label = required_env!("SYMPHONY_LIVE_GITHUB_WORKFLOW_LABEL")
    ready_status = required_env!("SYMPHONY_LIVE_GITHUB_READY_STATUS")

    %{
      kind: "github",
      required_labels: [required_env!("SYMPHONY_LIVE_GITHUB_READY_LABEL")],
      active_states: [ready_status],
      terminal_states: [required_env!("SYMPHONY_LIVE_GITHUB_TERMINAL_STATUS")],
      provider: %{
        "repo" => required_env!("SYMPHONY_LIVE_GITHUB_REPO"),
        "repository_id" => required_env!("SYMPHONY_LIVE_GITHUB_REPOSITORY_ID"),
        "project_id" => required_env!("SYMPHONY_LIVE_GITHUB_PROJECT_ID"),
        "base_branch" => required_env!("SYMPHONY_LIVE_GITHUB_BASE_BRANCH"),
        "token" => "$SYMPHONY_GITHUB_TOKEN",
        "ready_label" => required_env!("SYMPHONY_LIVE_GITHUB_READY_LABEL"),
        "status_field_id" => required_env!("SYMPHONY_LIVE_GITHUB_STATUS_FIELD_ID"),
        "status_options" => status_options,
        "ready_statuses" => [ready_status],
        "priority_field_id" => required_env!("SYMPHONY_LIVE_GITHUB_PRIORITY_FIELD_ID"),
        "priority_options" => priority_options,
        "workflow_labels" => [workflow_label],
        "actor_id" => required_env!("SYMPHONY_LIVE_GITHUB_ACTOR_ID")
      }
    }
  end

  defp graphql_request(query, variables, settings) do
    request(:post, "https://api.github.com/graphql", settings, %{"query" => query, "variables" => variables})
  end

  defp rest_get!(settings, path) do
    {:ok, %{status: 200, body: body}} = request(:get, "https://api.github.com" <> path, settings, nil)
    body
  end

  defp rest_get_url!(settings, url) do
    uri = URI.parse(url)
    rest_get!(settings, uri.path)
  end

  defp request(method, url, _settings, body) do
    opts = [
      method: method,
      url: url,
      headers: [
        {"Accept", "application/vnd.github+json"},
        {"Authorization", "Bearer #{System.fetch_env!("SYMPHONY_GITHUB_TOKEN")}"},
        {"X-GitHub-Api-Version", "2022-11-28"},
        {"User-Agent", "symphony-safe-pilot-e2e"}
      ],
      connect_options: [timeout: 30_000],
      receive_timeout: 30_000
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    case Req.request(opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :github_transport}
    end
  end

  defp success?(%{"success" => true, "output" => output}) do
    refute String.contains?(output, System.fetch_env!("SYMPHONY_GITHUB_TOKEN"))
    true
  end

  defp required_env!(name), do: System.fetch_env!(name)
  defp required_integer_env!(name), do: name |> required_env!() |> String.to_integer()

  defp json_map_env!(name) do
    with {:ok, value} when is_map(value) <- Jason.decode(required_env!(name)), do: value
  end
end

defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Adapter, AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeClient do
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issues_by_ids(ids), do: {:ok, ids}
  end

  test "validates the compact project profile and advertises only constrained tools" do
    assert :ok = Adapter.validate_config(settings())
    assert {:error, :missing_github_project_id} = Adapter.validate_config(settings(%{"project_id" => nil}))
    assert {:error, :missing_github_actor_id} = Adapter.validate_config(settings(%{"actor_id" => nil}))

    assert Enum.map(Adapter.agent_tool_specs(), & &1["name"]) == [
             "github_workpad",
             "github_apply_workflow_label",
             "github_attach_draft_pr"
           ]

    refute Enum.any?(Adapter.agent_tool_specs(), &(&1["name"] == "github_api"))

    assert {:error, :missing_github_active_states} =
             Adapter.validate_config(%{settings() | active_states: nil})

    assert {:error, :invalid_github_states} =
             Adapter.validate_config(%{settings() | provider: %{}})

    assert {:error, :missing_github_ready_label_gate} =
             Adapter.validate_config(%{settings() | required_labels: []})

    assert Client.secret_environment_names(settings(%{"token" => "$PILOT_GITHUB_TOKEN"})) |> Enum.member?("PILOT_GITHUB_TOKEN")
    assert Adapter.secret_environment_names(settings(%{"token" => "$PILOT_GITHUB_TOKEN"})) |> Enum.member?("PILOT_GITHUB_TOKEN")

    no_ready_label = %{settings() | provider: Map.delete(settings().provider, "ready_label")}
    assert {:error, :missing_github_ready_label_gate} = Adapter.validate_config(no_ready_label)

    assert {:error, :invalid_github_status_options} =
             Adapter.validate_config(
               settings(%{
                 "status_options" => %{
                   "one" => " Ready ",
                   "two" => "ready",
                   "review" => "Human Review",
                   "done" => "Done"
                 }
               })
             )

    assert {:error, :invalid_github_workflow_labels} =
             Adapter.validate_config(settings(%{"workflow_labels" => [" Symphony:Human-Review ", "symphony:human-review"]}))

    assert {:error, :missing_github_ready_label_gate} =
             Adapter.validate_config(%{settings() | required_labels: [123]})
  end

  test "adapter delegates reads and tool execution" do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    assert {:ok, ["Ready"]} = Adapter.fetch_issues_by_states(["Ready"])
    assert {:ok, ["PVTI_item_42"]} = Adapter.fetch_issues_by_ids(["PVTI_item_42"])
    refute Adapter.execute_agent_tool("unknown", %{}, [])["success"]
  end

  test "normalizes an eligible project issue with stable native references" do
    request = fn _query, variables, %{token: "test-token"} ->
      assert variables["projectId"] == "PVT_project"
      {:ok, %{status: 200, body: response([item()])}}
    end

    assert {:ok, [issue]} = Client.fetch_for_test(["Ready"], nil, settings(), request)
    assert issue.id == "PVTI_item_42"
    assert issue.identifier == "GH-42"
    assert issue.priority == 1
    assert issue.state == "Ready"
    assert issue.labels == ["symphony:ready", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable

    assert issue.native_ref == %{
             "project_id" => "PVT_project",
             "project_item_id" => "PVTI_item_42",
             "repository_id" => "R_repo",
             "repository" => "Korano-coder/Renewable-Fuels-Trading-Intelligence",
             "issue_id" => "I_issue_42",
             "issue_number" => 42
           }
  end

  test "never dispatches closed, unready, or blocked issues and skips pull requests" do
    blocked = put_in(item(), ["content", "blockedBy", "nodes"], [blocker()])
    closed = put_in(item("PVTI_closed", 43), ["content", "state"], "CLOSED")
    unready = put_in(item("PVTI_unready", 44), ["content", "labels", "nodes"], [%{"id" => "L_other", "name" => "other"}])
    pull = %{"id" => "PVTI_pr", "type" => "PULL_REQUEST", "content" => %{}}
    request = fn _, _, _ -> {:ok, %{status: 200, body: response([blocked, closed, unready, pull])}} end

    assert {:ok, issues} = Client.fetch_for_test(["Ready"], nil, settings(), request)
    assert Enum.map(issues, & &1.dispatchable) == [false, false, false]
  end

  test "fails closed on scope, fields, nested pagination, duplicate membership, and malformed payloads" do
    cases = [
      {put_in(item(), ["content", "repository", "id"], "R_other"), :github_repository_scope_mismatch},
      {put_in(item(), ["fieldValues", "nodes"], []), :github_missing_project_field},
      {put_in(item(), ["content", "labels", "pageInfo", "hasNextPage"], true), :github_nested_pagination},
      {put_in(item(), ["content", "title"], nil), :github_unknown_payload}
    ]

    Enum.each(cases, fn {raw, error} ->
      request = fn _, _, _ -> {:ok, %{status: 200, body: response([raw])}} end
      assert {:error, ^error} = Client.fetch_for_test(["Ready"], nil, settings(), request)
    end)

    duplicate = fn _, _, _ -> {:ok, %{status: 200, body: response([item(), item()])}} end
    assert {:error, :github_ambiguous_project_membership} = Client.fetch_for_test(["Ready"], nil, settings(), duplicate)
  end

  test "pagination is bounded and permission and rate-limit errors fail the read" do
    page = fn _query, variables, _ ->
      body = response([], %{"hasNextPage" => true, "endCursor" => "cursor-#{variables["after"] || "first"}"})
      {:ok, %{status: 200, body: body}}
    end

    assert {:error, :github_pagination_limit} =
             Client.fetch_for_test(["Ready"], nil, settings(%{"max_pages" => 2}), page)

    permission = fn _, _, _ -> {:ok, %{status: 403, body: %{}}} end
    assert {:error, {:github_permission_denied, 403}} = Client.fetch_for_test(["Ready"], nil, settings(), permission)

    limited = fn _, _, _ -> {:ok, %{status: 200, body: response([], nil, 0)}} end
    assert {:error, :github_rate_limited} = Client.fetch_for_test(["Ready"], nil, settings(), limited)
  end

  test "ID refresh uses project-item IDs and never broad repository lookup" do
    request = fn _, _, _ -> {:ok, %{status: 200, body: response([item(), item("PVTI_other", 43)])}} end
    assert {:ok, [issue]} = Client.fetch_for_test([], ["PVTI_item_42"], settings(), request)
    assert issue.id == "PVTI_item_42"
  end

  test "empty state and ID reads do not parse settings or call GitHub" do
    no_request = fn _, _, _ -> flunk("empty reads must not call GitHub") end
    invalid = %{provider: %{}}

    assert {:ok, []} = Client.fetch_for_test([], nil, invalid, no_request)
    assert {:ok, []} = Client.fetch_for_test([], [], invalid, no_request)
  end

  test "workpad updates only one marker-owned comment and rejects ambiguous pagination" do
    test_pid = self()

    client = fn method, path, params, body, _opts ->
      send(test_pid, {:request, method, path, params, body})

      case {method, path} do
        {"GET", _} ->
          {:ok, %{status: 200, body: [%{"id" => 9, "body" => "<!-- symphony-workpad:v1 -->\nold", "user" => %{"node_id" => "U_actor"}}]}}

        {"PATCH", _} ->
          {:ok, %{status: 200, body: %{"id" => 9}}}
      end
    end

    result = AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "new"}, tool_opts(client))
    assert result["success"]
    assert_received {:request, "PATCH", "/repos/Korano-coder/Renewable-Fuels-Trading-Intelligence/issues/comments/9", %{}, %{"body" => "<!-- symphony-workpad:v1 -->\nnew"}}

    crowded = fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: List.duplicate(%{}, 100)}} end
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "new"}, tool_opts(crowded))["success"]
  end

  test "workflow labels are allowlisted and draft PR URLs are repository-scoped and verified" do
    test_pid = self()

    client = fn method, path, _params, body, _opts ->
      send(test_pid, {:request, method, path, body})

      cond do
        path == "/repos/Korano-coder/Renewable-Fuels-Trading-Intelligence/pulls/7" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "draft" => true,
               "state" => "open",
               "html_url" => "https://github.com/Korano-coder/Renewable-Fuels-Trading-Intelligence/pull/7",
               "base" => %{
                 "ref" => "staging",
                 "repo" => %{"full_name" => "Korano-coder/Renewable-Fuels-Trading-Intelligence"}
               }
             }
           }}

        method == "GET" ->
          {:ok, %{status: 200, body: []}}

        true ->
          response_body =
            case body do
              %{"labels" => [label]} -> %{"labels" => [%{"name" => label}]}
              %{"body" => _} -> %{"id" => 10}
            end

          {:ok, %{status: 201, body: response_body}}
      end
    end

    assert AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "symphony:human-review"}, tool_opts(client))["success"]
    refute AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "admin"}, tool_opts(client))["success"]

    url = "https://github.com/Korano-coder/Renewable-Fuels-Trading-Intelligence/pull/7"
    assert AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(client))["success"]
    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => "https://github.com/other/repo/pull/7"}, tool_opts(client))["success"]
  end

  test "all mutations reject issues outside the configured Project" do
    denied = fn _native_ref, _ -> {:error, :github_issue_out_of_scope} end
    client = fn _, _, _, _, _ -> flunk("out-of-scope writes must not reach REST") end
    opts = [tracker_settings: settings(), github_client: client, scope_checker: denied, issue: issue()]

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, opts)["success"]

    refute AgentTool.execute(
             "github_apply_workflow_label",
             %{"issue_number" => 42, "label" => "symphony:human-review"},
             opts
           )["success"]
  end

  test "all mutations are bound to the current session issue identity" do
    client = fn _, _, _, _, _ -> flunk("mismatched issue context must not reach REST") end
    opts = tool_opts(client)

    refute AgentTool.execute("github_workpad", %{"issue_number" => 43, "body" => "x"}, opts)["success"]

    wrong_project = put_in(opts[:issue].native_ref["project_item_id"], "PVTI_other")
    checker = fn _native_ref, _ -> {:error, :github_issue_out_of_scope} end

    refute AgentTool.execute(
             "github_apply_workflow_label",
             %{"issue_number" => 42, "label" => "symphony:human-review"},
             Keyword.merge(opts, issue: wrong_project, scope_checker: checker)
           )["success"]
  end

  test "workpad marker must be the exact first line" do
    test_pid = self()

    client = fn method, _path, _params, body, _opts ->
      send(test_pid, {method, body})

      case method do
        "GET" ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 1,
                 "body" => "quoted <!-- symphony-workpad:v1 --> marker",
                 "user" => %{"node_id" => "U_actor"}
               }
             ]
           }}

        "POST" ->
          {:ok, %{status: 201, body: %{"id" => 2}}}
      end
    end

    assert AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "new"}, tool_opts(client))["success"]
    assert_received {"POST", %{"body" => "<!-- symphony-workpad:v1 -->\nnew"}}
  end

  test "mutation tools reject malformed, ambiguous, unowned, and non-draft inputs" do
    refute AgentTool.execute("unknown", %{}, [])["success"]
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, [])["success"]

    valid_without_issue = [
      tracker_settings: settings(),
      github_client: fn _, _, _, _, _ -> flunk("missing issue context must not call GitHub") end
    ]

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, valid_without_issue)["success"]
    refute AgentTool.execute("github_workpad", %{}, tool_opts(fn _, _, _, _, _ -> flunk("no call") end))["success"]

    comments = [
      %{"id" => 1, "body" => "not a workpad", "user" => %{"node_id" => "U_other"}},
      %{"id" => 2, "body" => "<!-- symphony-workpad:v1 -->", "user" => %{"node_id" => "U_actor"}},
      %{"id" => 3, "body" => "<!-- symphony-workpad:v1 -->", "user" => %{"node_id" => "U_actor"}}
    ]

    ambiguous = fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: comments}} end
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(ambiguous))["success"]

    malformed = fn "GET", _, _, _, _ ->
      {:ok,
       %{
         status: 200,
         body: [
           %{
             "id" => "not-an-integer",
             "body" => "<!-- symphony-workpad:v1 -->",
             "user" => %{"node_id" => "U_actor"}
           }
         ]
       }}
    end

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(malformed))["success"]

    invalid_settings = [
      tracker_settings: %{provider: %{}},
      github_client: fn _, _, _, _, _ -> flunk("no call") end,
      scope_checker: fn _, _ -> :ok end
    ]

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, invalid_settings)["success"]

    malformed_write = fn
      "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}}
      "POST", _, _, _, _ -> {:ok, %{status: 201, body: %{}}}
    end

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(malformed_write))["success"]

    malformed_label = fn "POST", _, _, _, _ ->
      {:ok, %{status: 200, body: %{"labels" => [%{"name" => nil}]}}}
    end

    refute AgentTool.execute(
             "github_apply_workflow_label",
             %{"issue_number" => 42, "label" => "symphony:human-review"},
             tool_opts(malformed_label)
           )["success"]

    non_draft = fn "GET", path, _, _, _ ->
      if String.contains?(path, "/pulls/"),
        do: {:ok, %{status: 200, body: %{"draft" => false}}},
        else: {:ok, %{status: 200, body: []}}
    end

    url = "https://github.com/Korano-coder/Renewable-Fuels-Trading-Intelligence/pull/7"
    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(non_draft))["success"]

    bad_status = fn "GET", _, _, _, _ -> {:ok, %{status: 500, body: %{}}} end
    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(bad_status))["success"]

    wrong_base = fn "GET", path, _, _, _ ->
      if String.contains?(path, "/pulls/"),
        do:
          {:ok,
           %{
             status: 200,
             body: %{
               "draft" => true,
               "state" => "open",
               "html_url" => url,
               "base" => %{
                 "ref" => "main",
                 "repo" => %{"full_name" => "Korano-coder/Renewable-Fuels-Trading-Intelligence"}
               }
             }
           }},
        else: {:ok, %{status: 200, body: []}}
    end

    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(wrong_base))[
             "success"
           ]

    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => "https://github.com/Korano-coder/Renewable-Fuels-Trading-Intelligence/pull/nope"}, tool_opts(non_draft))[
             "success"
           ]
  end

  test "REST client rejects paths outside the configured repository mutation surface" do
    assert {:error, :github_scope_violation} = Client.rest("DELETE", "/repos/owner/repo/issues/1", %{}, nil, tracker_settings: settings(), request_fun: fn _, _, _, _, _ -> flunk("must not call") end)

    assert {:error, :github_scope_violation} =
             Client.rest("POST", "/repos/other/repo/issues/1/comments", %{}, %{}, tracker_settings: settings(), request_fun: fn _, _, _, _, _ -> flunk("must not call") end)
  end

  defp settings(overrides \\ %{}) do
    %{
      kind: "github",
      required_labels: ["symphony:ready"],
      active_states: ["Ready"],
      terminal_states: ["Human Review", "Done"],
      provider:
        Map.merge(
          %{
            "repo" => "Korano-coder/Renewable-Fuels-Trading-Intelligence",
            "repository_id" => "R_repo",
            "project_id" => "PVT_project",
            "base_branch" => "staging",
            "ready_label" => "symphony:ready",
            "status_field_id" => "PVTF_status",
            "status_options" => %{"OPT_ready" => "Ready", "OPT_review" => "Human Review", "OPT_done" => "Done"},
            "ready_statuses" => ["Ready"],
            "priority_field_id" => "PVTF_priority",
            "priority_options" => %{"OPT_p1" => 1, "OPT_p2" => 2},
            "workflow_labels" => ["symphony:in-progress", "symphony:human-review"],
            "actor_id" => "U_actor",
            "token" => "test-token"
          },
          overrides
        )
    }
  end

  defp tool_opts(client),
    do: [
      tracker_settings: settings(),
      github_client: client,
      scope_checker: fn native_ref, _ ->
        if native_ref == issue().native_ref, do: :ok, else: {:error, :github_issue_out_of_scope}
      end,
      issue: issue()
    ]

  defp issue do
    %Issue{
      id: "PVTI_item_42",
      identifier: "GH-42",
      title: "Issue 42",
      state: "Ready",
      dispatchable: true,
      native_ref: %{
        "project_id" => "PVT_project",
        "project_item_id" => "PVTI_item_42",
        "repository_id" => "R_repo",
        "repository" => "Korano-coder/Renewable-Fuels-Trading-Intelligence",
        "issue_id" => "I_issue_42",
        "issue_number" => 42
      }
    }
  end

  defp response(nodes, page_info \\ %{"hasNextPage" => false, "endCursor" => nil}, remaining \\ 100) do
    %{"data" => %{"node" => %{"id" => "PVT_project", "items" => %{"nodes" => nodes, "pageInfo" => page_info}}, "rateLimit" => %{"remaining" => remaining, "resetAt" => "2026-01-01T00:00:00Z"}}}
  end

  defp item(item_id \\ "PVTI_item_42", number \\ 42) do
    %{
      "id" => item_id,
      "type" => "ISSUE",
      "content" => %{
        "id" => "I_issue_#{number}",
        "number" => number,
        "title" => "Issue #{number}",
        "body" => "Untrusted issue body",
        "state" => "OPEN",
        "url" => "https://github.com/Korano-coder/Renewable-Fuels-Trading-Intelligence/issues/#{number}",
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => "2026-01-02T00:00:00Z",
        "repository" => %{"id" => "R_repo", "nameWithOwner" => "Korano-coder/Renewable-Fuels-Trading-Intelligence"},
        "assignees" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
        "labels" => %{"nodes" => [%{"id" => "L_ready", "name" => "symphony:ready"}, %{"id" => "L_platform", "name" => "Platform"}], "pageInfo" => %{"hasNextPage" => false}},
        "blockedBy" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
      },
      "fieldValues" => %{"nodes" => [select("PVTF_status", "OPT_ready", "Ready"), select("PVTF_priority", "OPT_p1", "P1")], "pageInfo" => %{"hasNextPage" => false}}
    }
  end

  defp select(field, option, name), do: %{"optionId" => option, "name" => name, "field" => %{"id" => field}}
  defp blocker, do: %{"id" => "I_blocker", "number" => 5, "state" => "OPEN", "repository" => %{"id" => "R_repo", "nameWithOwner" => "Korano-coder/Renewable-Fuels-Trading-Intelligence"}}
end

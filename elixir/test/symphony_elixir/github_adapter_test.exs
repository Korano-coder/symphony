defmodule SymphonyElixir.GitHubAdapterTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitHub.{Adapter, AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeClient do
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issues_by_ids(ids), do: {:ok, ids}
  end

  test "validates repository label profile and constrained tools" do
    assert :ok = Adapter.validate_config(settings())
    assert {:error, :missing_github_repository_id} = Adapter.validate_config(settings(%{"repository_id" => nil}))
    assert {:error, :invalid_github_workflow_labels} = Adapter.validate_config(settings(%{"workflow_labels" => ["symphony:ready"]}))
    assert {:error, :invalid_github_priority_labels} = Adapter.validate_config(settings(%{"priority_labels" => ["priority:p0"]}))

    for project_settings <- [
          settings(%{"project_id" => "PVT_1"}),
          Map.put(settings(), :project_id, "PVT_1"),
          settings(%{"extension" => %{"project_number" => 1}}),
          settings(%{project_ref: "PVT_1"})
        ] do
      assert {:error, :github_project_configuration_not_allowed} = Adapter.validate_config(project_settings)
    end

    assert {:error, :missing_github_ready_label_gate} = Adapter.validate_config(%{settings() | required_labels: []})
    assert Enum.map(Adapter.agent_tool_specs(), & &1["name"]) == ["github_workpad", "github_apply_workflow_label", "github_attach_draft_pr"]
    refute Enum.any?(Adapter.agent_tool_specs(), &(&1["name"] == "github_api"))
    refute Enum.any?(Adapter.agent_tool_specs(), &String.contains?(String.downcase(&1["name"]), "project"))
    assert "PILOT_GITHUB_TOKEN" in Client.secret_environment_names(settings(%{"token" => "$PILOT_GITHUB_TOKEN"}))

    assert {:error, :missing_github_active_states} =
             Adapter.validate_config(%{settings() | active_states: nil})

    assert {:error, :invalid_github_states} =
             Adapter.validate_config(%{settings() | terminal_states: [123]})

    assert {:error, :missing_github_ready_label_gate} =
             Adapter.validate_config(Map.delete(settings(), :required_labels))
  end

  test "adapter delegates reads, tools, and secret names" do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    assert {:ok, ["ready"]} = Adapter.fetch_issues_by_states(["ready"])
    assert {:ok, ["I_42"]} = Adapter.fetch_issues_by_ids(["I_42"])
    refute Adapter.execute_agent_tool("unknown", %{}, [])["success"]
    assert "GITHUB_TOKEN" in Adapter.secret_environment_names(settings())
  end

  test "polls only configured repository, excludes PRs, and reads exact labels" do
    request = polling_client([raw_issue(), raw_issue(43, %{"pull_request" => %{"url" => "x"}})])
    assert {:ok, [issue]} = Client.fetch_for_test(["symphony:ready"], nil, settings(), request)
    assert {issue.id, issue.priority, issue.state, issue.dispatchable} == {"I_42", 1, "symphony:ready", true}
    assert issue.native_ref == %{"repository" => "owner/repo", "repository_id" => "R_repo", "issue_id" => "I_42", "issue_number" => 42}
    refute Enum.any?(Map.keys(issue.native_ref), &String.contains?(&1, "project"))
  end

  test "explicit ID lookup ignores ordinary repository issues before the requested issue" do
    ordinary = Enum.map(1..75, &ordinary_issue/1)
    request = polling_client(ordinary ++ [raw_issue(759)])

    assert {:ok, [issue]} =
             Client.fetch_for_test(["symphony:ready"], ["I_759"], settings(), request)

    assert issue.id == "I_759"
  end

  test "ready-state polling ignores ordinary issues without Symphony workflow labels" do
    request = polling_client(Enum.map(1..75, &ordinary_issue/1) ++ [raw_issue(759)])

    assert {:ok, [issue]} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), request)

    assert issue.id == "I_759"
  end

  test "actual Symphony candidates still fail closed for malformed and conflicting labels" do
    malformed = put_in(raw_issue(), ["labels"], [%{"name" => "symphony:ready"}, %{}])
    conflicting = put_in(raw_issue(), ["labels"], labels(["symphony:ready", "symphony:done", "priority:p1"]))

    assert {:error, :github_malformed_labels} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), polling_client([malformed]))

    assert {:error, :github_conflicting_workflow_labels} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), polling_client([conflicting]))
  end

  test "pagination is bounded" do
    endless = fn
      "GET", "/repos/owner/repo", _, _, _ -> {:ok, %{status: 200, body: repository()}}
      "GET", "/repos/owner/repo/issues", _, _, _ -> {:ok, %{status: 200, body: Enum.map(1..100, &raw_issue(&1 + 100))}}
      "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}}
    end

    assert {:error, :github_pagination_limit} = Client.fetch_for_test(["symphony:ready"], nil, settings(%{"max_pages" => 1}), endless)
  end

  test "pagination follows every repository issue page" do
    request = fn
      "GET", "/repos/owner/repo", _, _, _ ->
        {:ok, %{status: 200, body: repository()}}

      "GET", "/repos/owner/repo/issues", %{"page" => 1}, _, _ ->
        {:ok, %{status: 200, body: Enum.map(1..100, &raw_issue/1)}}

      "GET", "/repos/owner/repo/issues", %{"page" => 2}, _, _ ->
        {:ok, %{status: 200, body: [raw_issue(101)]}}

      "GET", path, _, _, _ ->
        if String.ends_with?(path, "/dependencies/blocked_by"),
          do: {:ok, %{status: 200, body: []}},
          else: {:ok, %{status: 404, body: %{}}}
    end

    assert {:ok, issues} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), request)

    assert length(issues) == 101
  end

  test "explicit lookup traverses ordinary pages and rejects duplicate candidates" do
    request = fn
      "GET", "/repos/owner/repo", _, _, _ ->
        {:ok, %{status: 200, body: repository()}}

      "GET", "/repos/owner/repo/issues", %{"page" => 1}, _, _ ->
        {:ok, %{status: 200, body: Enum.map(1..100, &ordinary_issue/1)}}

      "GET", "/repos/owner/repo/issues", %{"page" => 2}, _, _ ->
        {:ok, %{status: 200, body: [raw_issue(759), raw_issue(759)]}}

      "GET", path, _, _, _ ->
        if String.ends_with?(path, "/dependencies/blocked_by"),
          do: {:ok, %{status: 200, body: []}},
          else: {:ok, %{status: 404, body: %{}}}
    end

    assert {:error, :github_ambiguous_issue} =
             Client.fetch_for_test(["symphony:ready"], ["I_759"], settings(), request)
  end

  test "fails closed for exact labels, conflicts, blockers, malformed data, and denial" do
    wrong_case = put_in(raw_issue(), ["labels"], labels(["Symphony:Ready", "priority:p1"]))
    conflict = put_in(raw_issue(), ["labels"], labels(["symphony:ready", "symphony:done", "priority:p1"]))
    priorities = put_in(raw_issue(), ["labels"], labels(["symphony:ready", "priority:p0", "priority:p1"]))

    assert {:ok, []} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), polling_client([wrong_case]))

    assert {:error, :github_missing_workflow_label} =
             Client.fetch_for_test(["symphony:ready"], ["I_42"], settings(), polling_client([wrong_case]))

    assert {:error, :github_conflicting_workflow_labels} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), polling_client([conflict]))

    assert {:error, :github_conflicting_priority_labels} =
             Client.fetch_for_test(["symphony:ready"], nil, settings(), polling_client([priorities]))

    assert {:ok, [issue]} =
             Client.fetch_for_test(
               ["symphony:ready"],
               nil,
               settings(),
               polling_client([raw_issue()], [blocker()])
             )

    refute issue.dispatchable
    denied = fn "GET", "/repos/owner/repo", _, _, _ -> {:ok, %{status: 403, body: %{}}} end
    assert {:error, {:github_permission_denied, 403}} = Client.fetch_for_test(["symphony:ready"], nil, settings(), denied)
  end

  test "all mutations reject stale, mismatched, or unauthorized session identity" do
    no_write = fn _, _, _, _, _ -> flunk("must not mutate") end

    opts = [
      tracker_settings: settings(),
      github_client: no_write,
      scope_checker: fn _, _ -> {:error, :github_issue_not_eligible} end,
      issue: issue()
    ]

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, opts)["success"]
    refute AgentTool.execute("github_workpad", %{"issue_number" => 43, "body" => "x"}, tool_opts(no_write))["success"]
    wrong = put_in(issue().native_ref["repository_id"], "R_other")
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, Keyword.put(opts, :issue, wrong))["success"]
  end

  test "real revalidation rejects PR, repository, number, and node identity mismatches" do
    native_ref = issue().native_ref

    for changed <- [
          Map.put(raw_issue(), "pull_request", %{"url" => "x"}),
          Map.put(raw_issue(), "repository_url", "https://api.github.com/repos/other/repo"),
          Map.put(raw_issue(), "number", 43),
          Map.put(raw_issue(), "node_id", "I_other")
        ] do
      request = fn
        "GET", "/repos/owner/repo", _, _, _ ->
          {:ok, %{status: 200, body: repository()}}

        "GET", "/repos/owner/repo/issues/42", _, _, _ ->
          {:ok, %{status: 200, body: changed}}

        "GET", path, _, _, _ ->
          if String.ends_with?(path, "/dependencies/blocked_by"),
            do: {:ok, %{status: 200, body: []}},
            else: {:ok, %{status: 404, body: %{}}}
      end

      assert {:error, _} =
               Client.issue_snapshot(native_ref,
                 tracker_settings: settings(),
                 request_fun: request
               )
    end
  end

  test "workpad updates only one exact marker owned by configured actor" do
    client =
      mutation_client([
        %{"id" => 8, "body" => "ordinary", "user" => %{"node_id" => "U_other"}},
        %{"id" => 9, "body" => "<!-- symphony-workpad:v1 -->\nold", "user" => %{"node_id" => "U_actor"}}
      ])

    assert AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "new"}, tool_opts(client))["success"]
    assert_received {:mutation, "PATCH", "/repos/owner/repo/issues/comments/9", %{"body" => "<!-- symphony-workpad:v1 -->\nnew"}}

    ambiguous = [
      %{"id" => 1, "body" => "<!-- symphony-workpad:v1 -->", "user" => %{"node_id" => "U_actor"}},
      %{"id" => 2, "body" => "<!-- symphony-workpad:v1 -->", "user" => %{"node_id" => "U_actor"}}
    ]

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(mutation_client(ambiguous)))["success"]
  end

  test "workflow transition preserves ordinary labels and replaces Symphony label" do
    client = mutation_client([])
    assert AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "symphony:in-progress"}, tool_opts(client))["success"]
    assert_received {:mutation, "PATCH", "/repos/owner/repo/issues/42", %{"labels" => ["priority:p1", "component:api", "symphony:in-progress"]}}
    refute AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "Symphony:done"}, tool_opts(client))["success"]
  end

  test "Draft PR must be open Draft in exact repository and base branch" do
    url = "https://github.com/owner/repo/pull/7"
    assert AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(mutation_client([])))["success"]
    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => "https://github.com/other/repo/pull/7"}, tool_opts(mutation_client([])))["success"]
    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(mutation_client([], %{"draft" => false})))["success"]
  end

  test "REST allowlist excludes contents, refs, admin, merge, Projects, and redacts secrets" do
    no_call = fn _, _, _, _, _ -> flunk("denied route") end

    for {method, path} <- [
          {"GET", "/repos/owner/repo/contents/x"},
          {"POST", "/repos/owner/repo/git/refs"},
          {"PATCH", "/repos/owner/repo/branches/main/protection"},
          {"PUT", "/repos/owner/repo/pulls/7/merge"},
          {"POST", "/graphql"}
        ] do
      assert {:error, :github_scope_violation} = Client.rest(method, path, %{}, nil, tracker_settings: settings(), request_fun: no_call)
    end

    token = "super-secret-token"
    output = AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tracker_settings: settings(%{"token" => token}))["output"]
    refute String.contains?(output, token)
  end

  test "adapter and agent tools reject Project-shaped access" do
    no_call = fn _, _, _, _, _ -> flunk("Project-shaped request reached GitHub") end

    assert {:error, :github_scope_violation} =
             Client.rest("GET", "/graphql", %{"query" => "query { viewer { projectsV2(first: 1) { totalCount } } }"}, nil, tracker_settings: settings(), request_fun: no_call)

    for tool <- ["github_project", "github_projects_v2", "github_project_mutation"] do
      refute AgentTool.execute(tool, %{}, tool_opts(no_call))["success"]
    end

    for {tool, arguments} <- [
          {"github_workpad", %{"issue_number" => 42, "body" => "x", "project_id" => "PVT_1"}},
          {"github_apply_workflow_label", %{"issue_number" => 42, "label" => "symphony:done", "project_number" => 1}},
          {"github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => "https://github.com/owner/repo/pull/7", "project_item_id" => "PVTI_1"}}
        ] do
      refute AgentTool.execute(tool, arguments, tool_opts(no_call))["success"]
    end
  end

  test "mutation tools fail closed for malformed inputs and responses" do
    refute AgentTool.execute("unknown", %{}, [])["success"]
    refute AgentTool.execute("github_workpad", %{}, tool_opts(mutation_client([])))["success"]
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => 123}, tool_opts(mutation_client([])))["success"]
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, [])["success"]

    crowded = mutation_client(List.duplicate(%{}, 100))
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(crowded))["success"]

    malformed_comment =
      mutation_client([
        %{"id" => "bad", "body" => "<!-- symphony-workpad:v1 -->", "user" => %{"node_id" => "U_actor"}}
      ])

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(malformed_comment))["success"]

    malformed = fn method, path, params, body, opts ->
      case {method, path} do
        {"GET", "/repos/owner/repo/issues/42"} -> {:ok, %{status: 200, body: %{"labels" => [%{}]}}}
        _ -> mutation_client([]).(method, path, params, body, opts)
      end
    end

    refute AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "symphony:done"}, tool_opts(malformed))["success"]

    url = "https://github.com/owner/repo/pull/nope"
    refute AgentTool.execute("github_attach_draft_pr", %{"issue_number" => 42, "pr_url" => url}, tool_opts(mutation_client([])))["success"]

    malformed_issue = Keyword.put(tool_opts(mutation_client([])), :issue, %{})
    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, malformed_issue)["success"]

    for bad_labels <- [nil, [%{}]] do
      bad_issue = %{issue() | labels: bad_labels}

      opts = [
        tracker_settings: settings(),
        github_client: mutation_client([]),
        scope_checker: fn _, _ -> :ok end,
        issue: bad_issue
      ]

      refute AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "symphony:done"}, opts)["success"]
    end

    bad_write = fn method, path, params, body, opts ->
      if method in ["POST", "PATCH"] and String.contains?(path, "/comments") do
        {:ok, %{status: 200, body: %{}}}
      else
        mutation_client([]).(method, path, params, body, opts)
      end
    end

    refute AgentTool.execute("github_workpad", %{"issue_number" => 42, "body" => "x"}, tool_opts(bad_write))["success"]

    bad_label_write = fn method, path, params, body, opts ->
      if method == "PATCH" and path == "/repos/owner/repo/issues/42" do
        {:ok, %{status: 200, body: %{}}}
      else
        mutation_client([]).(method, path, params, body, opts)
      end
    end

    refute AgentTool.execute("github_apply_workflow_label", %{"issue_number" => 42, "label" => "symphony:done"}, tool_opts(bad_label_write))["success"]
  end

  defp settings(overrides \\ %{}) do
    %{
      kind: "github",
      required_labels: ["symphony:ready"],
      active_states: ["symphony:ready", "symphony:in-progress"],
      terminal_states: ["symphony:human-review", "symphony:done"],
      provider:
        Map.merge(
          %{
            "repo" => "owner/repo",
            "repository_id" => "R_repo",
            "base_branch" => "staging",
            "workflow_labels" => ~w(symphony:ready symphony:in-progress symphony:human-review symphony:done),
            "priority_labels" => ~w(priority:p0 priority:p1 priority:p2),
            "actor_id" => "U_actor",
            "token" => "test-token"
          },
          overrides
        )
    }
  end

  defp repository, do: %{"node_id" => "R_repo", "full_name" => "owner/repo"}
  defp labels(names), do: Enum.map(names, &%{"name" => &1})

  defp raw_issue(number \\ 42, extra \\ %{}),
    do:
      Map.merge(
        %{
          "node_id" => "I_#{number}",
          "number" => number,
          "title" => "Issue #{number}",
          "body" => "private body",
          "state" => "open",
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "repository_url" => "https://api.github.com/repos/owner/repo",
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z",
          "assignee" => nil,
          "labels" => labels(["symphony:ready", "priority:p1", "component:api"])
        },
        extra
      )

  defp ordinary_issue(number),
    do: raw_issue(number, %{"labels" => labels(["bug", "priority:p2"])})

  defp blocker do
    %{
      "node_id" => "I_5",
      "number" => 5,
      "state" => "open",
      "repository_url" => "https://api.github.com/repos/owner/repo"
    }
  end

  defp polling_client(nodes, blockers \\ []),
    do: fn
      "GET", "/repos/owner/repo", _, _, _ ->
        {:ok, %{status: 200, body: repository()}}

      "GET", "/repos/owner/repo/issues", _, _, _ ->
        {:ok, %{status: 200, body: nodes}}

      "GET", path, _, _, _ ->
        if String.ends_with?(path, "/dependencies/blocked_by"),
          do: {:ok, %{status: 200, body: blockers}},
          else: {:ok, %{status: 404, body: %{}}}
    end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp mutation_client(comments, pr_overrides \\ %{}),
    do: fn method, path, _params, body, _opts ->
      cond do
        method == "GET" and path == "/repos/owner/repo" ->
          {:ok, %{status: 200, body: repository()}}

        method == "GET" and path == "/repos/owner/repo/issues/42" ->
          {:ok, %{status: 200, body: raw_issue()}}

        method == "GET" and String.ends_with?(path, "/dependencies/blocked_by") ->
          {:ok, %{status: 200, body: []}}

        method == "GET" and String.ends_with?(path, "/comments") ->
          {:ok, %{status: 200, body: comments}}

        method == "GET" and path == "/repos/owner/repo/pulls/7" ->
          {:ok,
           %{
             status: 200,
             body:
               Map.merge(
                 %{
                   "draft" => true,
                   "state" => "open",
                   "html_url" => "https://github.com/owner/repo/pull/7",
                   "base" => %{"ref" => "staging", "repo" => %{"full_name" => "owner/repo"}}
                 },
                 pr_overrides
               )
           }}

        method in ["POST", "PATCH"] ->
          send(self(), {:mutation, method, path, body})
          {:ok, %{status: 200, body: if(path == "/repos/owner/repo/issues/42", do: %{"labels" => labels(body["labels"])}, else: %{"id" => 9})}}
      end
    end

  defp issue,
    do: %Issue{
      id: "I_42",
      identifier: "GH-42",
      title: "Issue 42",
      state: "symphony:ready",
      dispatchable: true,
      labels: ["symphony:ready", "priority:p1", "component:api"],
      native_ref: %{"repository" => "owner/repo", "repository_id" => "R_repo", "issue_id" => "I_42", "issue_number" => 42}
    }

  defp tool_opts(client), do: [tracker_settings: settings(), github_client: client, issue: issue()]
end

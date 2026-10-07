defmodule SymphonyElixir.SafetyFusesTest do
  use SymphonyElixir.TestSupport

  test "serializes the Codex 0.159.2 granular policy and reviewer exactly" do
    {root, workspace, codex, trace} = fixture_paths("granular")
    File.mkdir_p!(workspace)
    write_fake_codex!(codex, trace, ~s({"method":"turn/completed"}))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      codex_command: "#{codex} app-server",
      codex_approval_policy: %{
        granular: %{
          sandbox_approval: true,
          rules: true,
          mcp_elicitations: true,
          request_permissions: false,
          skill_approval: false
        }
      },
      codex_approvals_reviewer: "auto_review"
    )

    assert {:ok, _} = AppServer.run(workspace, "protocol", issue("granular"))

    expected = %{
      "granular" => %{
        "sandbox_approval" => true,
        "rules" => true,
        "mcp_elicitations" => true,
        "request_permissions" => false,
        "skill_approval" => false
      }
    }

    payloads = trace_payloads(trace)

    for method <- ["thread/start", "turn/start"] do
      payload = Enum.find(payloads, &(&1["method"] == method))
      assert get_in(payload, ["params", "approvalPolicy"]) == expected
      assert get_in(payload, ["params", "approvalsReviewer"]) == "auto_review"
    end

    assert File.ls!(workspace) == []
    File.rm_rf!(root)
  end

  test "rejects malformed granular policy while loading workflow" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: %{granular: %{sandbox_approval: true}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "granular is missing required boolean keys"
  end

  test "stops on the first identical approval-policy rejection" do
    {root, workspace, codex, trace} = fixture_paths("rejection")
    File.mkdir_p!(workspace)

    rejection =
      ~s({"method":"item/completed","params":{"item":{"type":"error","message":"approval required by policy, but AskForApproval is set to Never"}}})

    write_fake_codex!(codex, trace, rejection)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      codex_command: "#{codex} app-server",
      codex_approval_policy: "never"
    )

    on_message = fn message -> send(self(), {:event, message}) end

    assert {:error, {:approval_policy_rejection, _}} =
             AppServer.run(workspace, "rejection", issue("rejection"), on_message: on_message)

    assert_receive {:event, %{event: :run_stopped, stop_reason: {:approval_policy_rejection, _}}}
    assert Enum.count(trace_payloads(trace), &(&1["method"] == "turn/start")) == 1
    assert File.ls!(workspace) == []
    File.rm_rf!(root)
  end

  test "stops when cumulative token ceiling is reached and reports cached input separately" do
    {root, workspace, codex, trace} = fixture_paths("tokens")
    File.mkdir_p!(workspace)

    usage =
      ~s({"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"inputTokens":90,"cachedInputTokens":40,"outputTokens":10,"totalTokens":100},"last":{"inputTokens":90,"cachedInputTokens":40,"outputTokens":10,"totalTokens":100}}}})

    write_fake_codex!(codex, trace, usage)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      codex_command: "#{codex} app-server",
      max_cumulative_tokens: 100
    )

    on_message = fn message -> send(self(), {:event, message}) end

    assert {:error, {:cumulative_token_limit_reached, 100, 100}} =
             AppServer.run(workspace, "tokens", issue("tokens"),
               on_message: on_message,
               max_cumulative_tokens: 100
             )

    assert_receive {:event,
                    %{
                      event: :run_stopped,
                      stop_reason: {:cumulative_token_limit_reached, 100, 100},
                      usage: %{
                        "inputTokens" => 90,
                        "cachedInputTokens" => 40,
                        "outputTokens" => 10,
                        "totalTokens" => 100
                      }
                    }}

    assert File.ls!(workspace) == []
    File.rm_rf!(root)
  end

  test "turn-start protocol errors become terminal zero-token stop reasons" do
    {root, workspace, codex, trace} = fixture_paths("turn-start-error")
    File.mkdir_p!(Path.dirname(workspace))

    File.write!(codex, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\n' "$line" >> "#{trace}"
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-error"}}}' ;;
        4) printf '%s\n' '{"id":3,"error":{"code":-32602,"message":"Invalid request: invalid type: unit variant, expected struct variant"}}' ;;
      esac
    done
    """)

    File.chmod!(codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: "#{codex} app-server",
      hook_after_create: "true"
    )

    assert {:shutdown, {:terminal_run, {:protocol_start_failure, {:response_error, _}}}} =
             catch_exit(AgentRunner.run(issue("turn-start-error"), self()))

    assert_receive {:codex_worker_update, "issue-turn-start-error",
                    %{
                      event: :run_stopped,
                      stop_reason: {:protocol_start_failure, {:response_error, _}}
                    }}

    assert Enum.count(trace_payloads(trace), &(&1["method"] == "turn/start")) == 1
    File.rm_rf!(root)
  end

  defp fixture_paths(label) do
    root = Path.join(System.tmp_dir!(), "symphony-safety-#{label}-#{System.unique_integer([:positive])}")
    workspace = Path.join([root, "workspaces", "ISSUE"])
    {root, workspace, Path.join(root, "fake-codex"), Path.join(root, "trace")}
  end

  defp write_fake_codex!(path, trace, notification) do
    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\n' "$line" >> "#{trace}"
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-safety"}}}' ;;
        4)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-safety"}}}'
          printf '%s\n' '#{notification}'
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp trace_payloads(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp issue(label) do
    %Issue{
      id: "issue-#{label}",
      identifier: "ISSUE",
      title: "Safety fuse",
      state: "In Progress",
      dispatchable: true,
      labels: []
    }
  end
end

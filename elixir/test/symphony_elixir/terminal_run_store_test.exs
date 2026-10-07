defmodule SymphonyElixir.TerminalRunStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, TerminalRunStore}
  alias SymphonyElixir.Tracker.Issue

  test "returns write and read failures without escaping the workspace root" do
    root = Path.join(System.tmp_dir!(), "terminal-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    issue = %Issue{id: "store-error", identifier: "MT-STORE"}

    assert {:error, _reason} = TerminalRunStore.put(issue, %{"pid" => self()})

    marker =
      Path.join([
        Config.local_workspace_root(),
        ".symphony",
        "terminal_runs",
        Base.url_encode64(issue.id, padding: false) <> ".json"
      ])

    File.mkdir_p!(marker)
    assert {:error, _reason} = TerminalRunStore.get(issue)
  end

  test "fails closed when no durable marker root is writable" do
    root = Path.join(System.tmp_dir!(), "terminal-store-fail-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :terminal_run_store_roots)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    blocked_roots = [Path.join(root, "not-a-dir-1"), Path.join(root, "not-a-dir-2")]
    Enum.each(blocked_roots, &File.write!(&1, "file"))
    Application.put_env(:symphony_elixir, :terminal_run_store_roots, blocked_roots)

    issue = %Issue{id: "all-roots-fail", identifier: "MT-FAIL"}
    assert {:error, {:terminal_marker_write_failed, errors}} = TerminalRunStore.put(issue, %{"ok" => true})
    assert length(errors) == 2
    assert {:error, {:terminal_marker_delete_failed, delete_errors}} = TerminalRunStore.delete(issue)
    assert length(delete_errors) == 2
  end

  test "selects the newest valid replica when the primary is stale" do
    root = Path.join(System.tmp_dir!(), "terminal-store-replicas-#{System.unique_integer([:positive])}")
    roots = [Path.join(root, "primary"), Path.join(root, "fallback")]

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :terminal_run_store_roots)
      File.rm_rf(root)
    end)

    Application.put_env(:symphony_elixir, :terminal_run_store_roots, roots)
    Enum.each(roots, &File.mkdir_p!/1)
    issue = %Issue{id: "replica", identifier: "MT-REPLICA"}
    filename = Base.url_encode64(issue.id, padding: false) <> ".json"

    File.write!(Path.join(Enum.at(roots, 0), filename), Jason.encode!(%{"stopped_at" => "2026-10-07T10:00:00Z", "value" => "stale"}))
    File.write!(Path.join(Enum.at(roots, 1), filename), Jason.encode!(%{"stopped_at" => "2026-10-07T11:00:00Z", "value" => "current"}))

    assert {:ok, %{"value" => "current"}} = TerminalRunStore.get(issue)
  end
end

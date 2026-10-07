defmodule SymphonyElixir.TerminalRunStore do
  @moduledoc "Persists terminal dispatch outcomes under the local workspace root."

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @spec put(Issue.t(), map()) :: :ok | {:error, term()}
  def put(%Issue{id: issue_id}, payload) when is_binary(issue_id) and is_map(payload) do
    encoded = Jason.encode(payload)

    case encoded do
      {:ok, json} -> put_encoded(issue_id, json)
      {:error, _reason} = error -> error
    end
  end

  defp put_encoded(issue_id, encoded) do
    paths = marker_paths(issue_id)

    case Enum.reduce(paths, [], &collect_write_error(&1, encoded, &2)) do
      errors when length(errors) == length(paths) -> {:error, {:terminal_marker_write_failed, errors}}
      _errors -> :ok
    end
  end

  defp collect_write_error(path, encoded, errors) do
    case write_marker(path, encoded) do
      :ok -> errors
      {:error, reason} -> [{path, reason} | errors]
    end
  end

  defp write_marker(path, encoded) do
    temporary_path = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary_path, encoded, [:binary]),
         :ok <- File.rename(temporary_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary_path)
        error
    end
  end

  @spec get(Issue.t()) :: {:ok, map()} | :missing | {:error, term()}
  def get(%Issue{id: issue_id}) when is_binary(issue_id) do
    results = Enum.map(marker_paths(issue_id), &read_marker/1)
    valid = for {:ok, marker} <- results, do: marker

    cond do
      valid != [] -> {:ok, Enum.max_by(valid, &Map.get(&1, "stopped_at", ""))}
      Enum.all?(results, &(&1 == :missing)) -> :missing
      true -> {:error, {:terminal_marker_read_failed, results}}
    end
  end

  defp read_marker(path) do
    case File.read(path) do
      {:ok, encoded} -> Jason.decode(encoded)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete(Issue.t()) :: :ok | {:error, term()}
  def delete(%Issue{id: issue_id}) when is_binary(issue_id) do
    errors =
      issue_id
      |> marker_paths()
      |> Enum.flat_map(fn path ->
        case File.rm(path) do
          :ok -> []
          {:error, :enoent} -> []
          {:error, reason} -> [{path, reason}]
        end
      end)

    if errors == [], do: :ok, else: {:error, {:terminal_marker_delete_failed, errors}}
  end

  defp marker_paths(issue_id) do
    filename = Base.url_encode64(issue_id, padding: false) <> ".json"

    :symphony_elixir
    |> Application.get_env(:terminal_run_store_roots, [
      Path.join([Config.local_workspace_root(), ".symphony", "terminal_runs"]),
      fallback_root()
    ])
    |> Enum.map(&Path.join(&1, filename))
  end

  defp fallback_root do
    scope = :crypto.hash(:sha256, Config.local_workspace_root()) |> Base.url_encode64(padding: false)
    Path.join([System.tmp_dir!(), "symphony_terminal_runs", scope])
  end
end

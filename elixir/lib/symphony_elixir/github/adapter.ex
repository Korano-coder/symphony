defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues + Projects v2 tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, :missing_github_active_states),
         :ok <- validate_states(tracker_settings.terminal_states, :missing_github_terminal_states),
         :ok <- validate_state_profile(tracker_settings),
         :ok <- validate_ready_label(tracker_settings) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp validate_states(states, _missing_error) when is_list(states) and states != [] do
    if Enum.all?(states, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_github_states}
    end
  end

  defp validate_states(_states, missing_error), do: {:error, missing_error}

  defp validate_state_profile(%{provider: %{"status_options" => options}} = settings)
       when is_map(options) do
    configured = options |> Map.values() |> MapSet.new(&normalize_state/1)
    active = MapSet.new(settings.active_states, &normalize_state/1)
    terminal = MapSet.new(settings.terminal_states, &normalize_state/1)

    if MapSet.subset?(active, configured) and MapSet.subset?(terminal, configured) and
         MapSet.disjoint?(active, terminal),
       do: :ok,
       else: {:error, :invalid_github_states}
  end

  defp validate_state_profile(_settings), do: {:error, :invalid_github_states}

  defp validate_ready_label(%{
         required_labels: required_labels,
         provider: %{"ready_label" => ready_label}
       })
       when is_list(required_labels) and is_binary(ready_label) do
    if normalize_state(ready_label) in Enum.map(required_labels, &normalize_state/1),
      do: :ok,
      else: {:error, :missing_github_ready_label_gate}
  end

  defp validate_ready_label(_settings), do: {:error, :missing_github_ready_label_gate}

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()
end

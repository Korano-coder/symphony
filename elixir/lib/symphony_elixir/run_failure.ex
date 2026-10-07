defmodule SymphonyElixir.RunFailure do
  @moduledoc """
  Classifies worker failures that must stop the current issue dispatch.

  Terminal failures are retained by the orchestrator instead of entering retry
  backoff. All unclassified failures remain transient and retryable.
  """

  @type terminal_reason ::
          {:cumulative_token_limit_reached, non_neg_integer(), pos_integer()}
          | {:max_turns_reached, pos_integer()}
          | {:approval_policy_rejection, term()}
          | {:approval_required, term()}
          | {:turn_input_required, term()}
          | {:protocol_start_failure, term()}
          | {:max_turns_reached, pos_integer(), term()}

  @doc "Returns the terminal stop reason contained in a worker result, if any."
  @spec terminal_reason(term()) :: terminal_reason() | nil
  def terminal_reason({:terminal_run, reason}), do: terminal_reason(reason)
  def terminal_reason({:shutdown, reason}), do: terminal_reason(reason)

  def terminal_reason({:cumulative_token_limit_reached, total, limit} = reason)
      when is_integer(total) and total >= 0 and is_integer(limit) and limit > 0,
      do: reason

  def terminal_reason({:max_turns_reached, max_turns} = reason)
      when is_integer(max_turns) and max_turns > 0,
      do: reason

  def terminal_reason({:max_turns_reached, max_turns, _details} = reason)
      when is_integer(max_turns) and max_turns > 0,
      do: reason

  def terminal_reason({kind, _details} = reason)
      when kind in [
             :approval_policy_rejection,
             :approval_required,
             :turn_input_required,
             :protocol_start_failure
           ],
      do: reason

  def terminal_reason(_reason), do: nil

  @doc "Returns whether a worker result is terminal for its current dispatch."
  @spec terminal?(term()) :: boolean()
  def terminal?(reason), do: not is_nil(terminal_reason(reason))

  @doc "Converts a terminal reason into a JSON-safe API and persistence payload."
  @spec to_payload(term()) :: map()
  def to_payload({:cumulative_token_limit_reached, total, limit}),
    do: %{kind: "cumulative_token_limit_reached", total_tokens: total, token_limit: limit}

  def to_payload({:max_turns_reached, max_turns}),
    do: %{kind: "max_turns_reached", max_turns: max_turns}

  def to_payload({:max_turns_reached, max_turns, details}),
    do: %{kind: "max_turns_reached", max_turns: max_turns, details: inspect(details)}

  def to_payload({kind, details}) when is_atom(kind),
    do: %{kind: Atom.to_string(kind), details: inspect(details)}

  def to_payload(%{} = payload), do: payload
  def to_payload(reason), do: %{kind: "terminal_run", details: inspect(reason)}
end

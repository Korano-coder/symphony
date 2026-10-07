defmodule SymphonyElixir.RunFailureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunFailure

  test "classifies configured resource limits and policy stops as terminal" do
    terminal_reasons = [
      {:cumulative_token_limit_reached, 110_845, 100_000},
      {:max_turns_reached, 1},
      {:approval_policy_rejection, "approval denied"},
      {:approval_required, %{}},
      {:turn_input_required, %{}},
      {:protocol_start_failure, {:response_error, %{}}}
    ]

    for reason <- terminal_reasons do
      assert RunFailure.terminal?(reason)
      assert RunFailure.terminal_reason({:shutdown, {:terminal_run, reason}}) == reason
    end
  end

  test "leaves genuinely transient failures retryable" do
    for reason <- [:turn_timeout, {:port_exit, 1}, {:startup_failure, :econnrefused}, {:turn_failed, %{}}] do
      refute RunFailure.terminal?(reason)
      assert RunFailure.terminal_reason(reason) == nil
    end
  end

  test "serializes every terminal reason shape for JSON APIs" do
    assert RunFailure.to_payload({:max_turns_reached, 1, :tracker_unavailable}) == %{
             kind: "max_turns_reached",
             max_turns: 1,
             details: ":tracker_unavailable"
           }

    assert RunFailure.to_payload(%{"kind" => "persisted"}) == %{"kind" => "persisted"}
    assert RunFailure.to_payload(:unknown) == %{kind: "terminal_run", details: ":unknown"}
  end
end

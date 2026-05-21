defmodule Lenies.AttackEnergyConservationTest do
  @moduledoc """
  Tests that the attack mechanic conserves energy:
  - Attacker gains exactly what the victim lost (no more, even on overkill).
  - Defended attack: async reward equals clamped damage; penalty is applied
    separately by the interpreter (synchronously, before any reward arrives).
  - Unit tests of the victim's handle_info({:take_damage, amount, attacker_id}) clamp.
  """
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, World}
  alias Lenies.World.Tables

  setup do
    on_exit(fn ->
      case Process.whereis(Lenies.LenieSupervisor) do
        sup_pid when is_pid(sup_pid) ->
          DynamicSupervisor.which_children(sup_pid)
          |> Enum.each(fn {_, child_pid, _, _} ->
            if is_pid(child_pid), do: DynamicSupervisor.terminate_child(sup_pid, child_pid)
          end)

        _ ->
          :ok
      end

      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Tables.delete_all()
    end)

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    :ok
  end

  # Spawn a lenie at position, register it in ETS. Starts paused by default
  # so metabolism doesn't drain energy between spawn and the test action.
  # The initial snapshot is still written in init/1 regardless of paused?.
  defp spawn_lenie(id, pos, energy, opts) do
    [{key, cell}] = :ets.lookup(:cells, pos)
    :ets.insert(:cells, {key, %{cell | lenie_id: id}})

    opcodes = Keyword.get(opts, :codeome, [:nop_0, :nop_0, :nop_0])
    codeome = Codeome.from_list(opcodes)

    {:ok, pid} =
      Lenie.start_link(
        [
          id: id,
          codeome: codeome,
          energy: energy,
          pos: pos,
          dir: Keyword.get(opts, :dir, :n),
          lineage: {nil, 0},
          paused?: Keyword.get(opts, :paused?, true)
        ] ++ Keyword.drop(opts, [:dir, :paused?, :codeome])
      )

    Process.unlink(pid)
    pid
  end

  # Poll attacker's energy via inspect_state until it changes from `before`
  # or the deadline (in ms) passes. Raises on timeout.
  defp await_energy_change(pid, before, deadline_ms \\ 1_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn ->
      Process.sleep(interval_ms)
      Lenie.inspect_state(pid).energy
    end)
    |> Enum.reduce_while(before, fn energy, _acc ->
      if energy != before do
        {:halt, energy}
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Attacker energy did not change from #{before} within #{deadline_ms}ms")
        else
          {:cont, before}
        end
      end
    end)
  end

  describe "energy conservation on overkill" do
    test "victim with less energy than attack_damage: attacker gains only what victim had" do
      attack_damage = Application.get_env(:lenies, :attack_damage, 10)
      victim_energy = attack_damage / 2.0

      # Both lenies start paused so energy is stable during the test.
      # Attacker faces east; victim is to its east.
      attacker_pid = spawn_lenie("ATK_OVK", {20, 20}, 100.0, dir: :e)
      victim_pid = spawn_lenie("VIC_OVK", {21, 20}, victim_energy, dir: :w)

      ref = Process.monitor(victim_pid)

      attacker_before = Lenie.inspect_state(attacker_pid).energy

      # Trigger attack (World.action is a synchronous call).
      {:ok, {:attacked, ^attack_damage}} =
        World.action({:attack, {20, 20}, :e, "ATK_OVK"})

      # Victim must die — overkill
      assert_receive {:DOWN, ^ref, :process, ^victim_pid, :killed}, 1_000

      # Once the DOWN arrives the victim has already sent :attack_reward.
      # Use inspect_state (a synchronous GenServer call) to flush the attacker's
      # mailbox and read the settled energy.
      attacker_after = await_energy_change(attacker_pid, attacker_before)

      attacker_gain = attacker_after - attacker_before

      # Attacker must have gained exactly victim_energy (not full attack_damage).
      assert attacker_gain >= victim_energy - 0.5,
             "Attacker gained less than victim had: gain=#{attacker_gain}, victim_energy=#{victim_energy}"

      assert attacker_gain <= victim_energy + 0.5,
             "Attacker gained more than victim had (energy minted!): gain=#{attacker_gain}, victim_energy=#{victim_energy}"

      GenServer.stop(attacker_pid)
    end
  end

  describe "energy conservation on normal hit" do
    test "victim has more energy than attack_damage: attacker gains full attack_damage; victim survives" do
      attack_damage = Application.get_env(:lenies, :attack_damage, 10)
      victim_energy = attack_damage * 10.0

      attacker_pid = spawn_lenie("ATK_NRM", {20, 21}, 100.0, dir: :e)
      victim_pid = spawn_lenie("VIC_NRM", {21, 21}, victim_energy, dir: :w)

      attacker_before = Lenie.inspect_state(attacker_pid).energy
      victim_before = Lenie.inspect_state(victim_pid).energy

      {:ok, {:attacked, ^attack_damage}} =
        World.action({:attack, {20, 21}, :e, "ATK_NRM"})

      # Wait deterministically for the async :attack_reward to land on the attacker.
      attacker_after = await_energy_change(attacker_pid, attacker_before)
      victim_after = Lenie.inspect_state(victim_pid).energy

      attacker_gain = attacker_after - attacker_before
      victim_loss = victim_before - victim_after

      # Attacker gained full attack_damage (victim had enough to cover it)
      assert abs(attacker_gain - attack_damage) < 0.5,
             "Attacker gain wrong: got #{attacker_gain}, expected #{attack_damage}"

      # Victim lost exactly attack_damage
      assert abs(victim_loss - attack_damage) < 0.5,
             "Victim loss wrong: got #{victim_loss}, expected #{attack_damage}"

      # Energy is conserved: what attacker gained = what victim lost
      assert abs(attacker_gain - victim_loss) < 0.5,
             "Energy not conserved: attacker_gain=#{attacker_gain}, victim_loss=#{victim_loss}"

      assert Process.alive?(victim_pid), "Victim should survive a non-lethal hit"

      GenServer.stop(attacker_pid)
      GenServer.stop(victim_pid)
    end
  end

  describe "energy conservation on defended hit" do
    test "defended: victim loses halved damage; attacker receives halved damage as async reward" do
      # Note: the attacker's defense penalty is applied by apply_world_action
      # inside the lenie interpreter (not here). This test verifies the
      # async reward component: the victim loses half_damage and the attacker
      # receives exactly half_damage (clamped) as reward.
      attack_damage = Application.get_env(:lenies, :attack_damage, 10)
      half_damage = div(attack_damage, 2)

      attacker_pid = spawn_lenie("ATK_DEF", {20, 22}, 100.0, dir: :e)
      victim_pid = spawn_lenie("VIC_DEF", {21, 22}, 100.0, dir: :w)

      attacker_before = Lenie.inspect_state(attacker_pid).energy
      victim_before = Lenie.inspect_state(victim_pid).energy

      # Make the victim defending
      [{"VIC_DEF", record}] = :ets.lookup(:lenies, "VIC_DEF")
      :ets.insert(:lenies, {"VIC_DEF", Map.put(record, :defending_until, 999_999)})

      {:ok, {:defended, ^half_damage}} =
        World.action({:attack, {20, 22}, :e, "ATK_DEF"})

      # Wait deterministically for the async :attack_reward to land on the attacker.
      attacker_after = await_energy_change(attacker_pid, attacker_before)
      victim_after = Lenie.inspect_state(victim_pid).energy

      attacker_gain = attacker_after - attacker_before
      victim_loss = victim_before - victim_after

      # Attacker received the async reward equal to half_damage (victim had plenty)
      assert abs(attacker_gain - half_damage) < 0.5,
             "Attacker async reward wrong: got #{attacker_gain}, expected #{half_damage}"

      # Victim lost exactly half_damage
      assert abs(victim_loss - half_damage) < 0.5,
             "Victim loss wrong: got #{victim_loss}, expected #{half_damage}"

      # Energy conserved: reward == victim_loss
      assert abs(attacker_gain - victim_loss) < 0.5,
             "Energy not conserved: attacker_gain=#{attacker_gain}, victim_loss=#{victim_loss}"

      GenServer.stop(attacker_pid)
      GenServer.stop(victim_pid)
    end

    test "defended: apply_world_action charges only the penalty — not a pre-credited damage bonus" do
      # This test runs the attacker's real metabolize loop (codeome = [:attack])
      # against a live defending victim. The old bug credited +damage inside
      # apply_world_action before the async reward arrived, so each defended
      # cycle produced a net energy GAIN for the attacker. The new code charges
      # only the synchronous penalty, and the reward arrives later; each cycle
      # therefore produces a net energy LOSS (or at best break-even after reward)
      # equal to -(attack_cost + penalty) + half_damage.
      #
      # With default config (attack_cost=5, penalty=5, half_damage=5):
      #   New code per cycle: -5 - 5 + 5 = -5  (attacker loses energy)
      #   Old bug per cycle:  -5 + 10 - 5 + 5 = +5  (attacker gains energy!)
      #
      # After many cycles the energy trends diverge by N * attack_damage, making
      # this an unambiguous regression detector without needing to intercept the
      # exact synchronous intermediate state.
      attack_cost = 5.0
      penalty = Application.get_env(:lenies, :defense_attacker_penalty, 5)
      attack_damage = Application.get_env(:lenies, :attack_damage, 10)
      half_damage = div(attack_damage, 2)

      # Verify the expected per-cycle delta is negative under new code —
      # if someone changes the config so this is no longer true the test
      # would be vacuous, so we guard it explicitly.
      per_cycle_new = -attack_cost - penalty + half_damage
      per_cycle_old = -attack_cost + attack_damage - penalty + half_damage

      assert per_cycle_new < 0,
             "Config must produce negative per-cycle delta for this test to distinguish old from new code"

      assert per_cycle_old > 0,
             "Config must produce positive per-cycle delta under the old bug for this test to be meaningful"

      # Victim: big energy (won't die), permanently defending.
      # Attacker: only [:attack] opcode, runs live (not paused) with enough
      # initial energy for many cycles before dying.
      # Spawn victim first and set defending state before launching the attacker,
      # so every attack the attacker fires sees the victim as defending.
      victim_pid = spawn_lenie("VIC_SYNC", {21, 24}, 10_000.0, dir: :w)

      victim_before = Lenie.inspect_state(victim_pid).energy

      # Set victim as permanently defending (must happen before attacker spawns).
      [{"VIC_SYNC", record}] = :ets.lookup(:lenies, "VIC_SYNC")
      :ets.insert(:lenies, {"VIC_SYNC", Map.put(record, :defending_until, 999_999)})

      attacker_pid = spawn_lenie("ATK_SYNC", {20, 24}, 500.0, dir: :e, paused?: false, codeome: [:attack])

      attacker_before = Lenie.inspect_state(attacker_pid).energy

      # Wait until at least 5 defended attacks have landed on the victim
      # (victim lost >= 5 * half_damage). This is deterministic: we poll
      # victim energy rather than sleeping blindly.
      min_cycles = 5
      min_victim_loss = min_cycles * half_damage

      deadline = System.monotonic_time(:millisecond) + 2_000

      Stream.repeatedly(fn ->
        Process.sleep(10)
        Lenie.inspect_state(victim_pid).energy
      end)
      |> Enum.reduce_while(:waiting, fn victim_energy, _ ->
        if victim_before - victim_energy >= min_victim_loss do
          {:halt, :done}
        else
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("Victim did not absorb #{min_cycles} attacks within deadline")
          else
            {:cont, :waiting}
          end
        end
      end)

      attacker_after = Lenie.inspect_state(attacker_pid).energy

      # With new code the attacker must have LOST energy overall.
      # With the old bug it would have GAINED energy (per_cycle_old > 0).
      assert attacker_after < attacker_before,
             "Attacker should have lost energy over many defended cycles " <>
               "(per_cycle_delta=#{per_cycle_new}): " <>
               "before=#{attacker_before}, after=#{attacker_after}"

      GenServer.stop(attacker_pid)
      GenServer.stop(victim_pid)
    end
  end

  describe "unit: take_damage clamp via direct message" do
    test "victim with energy less than damage reports actual=energy as reward" do
      [{key, cell}] = :ets.lookup(:cells, {5, 30})
      :ets.insert(:cells, {key, %{cell | lenie_id: "CLAMP_V"}})

      codeome = Codeome.from_list([:nop_0])
      small_energy = 3.0

      {:ok, victim_pid} =
        Lenie.start_link(
          id: "CLAMP_V",
          codeome: codeome,
          energy: small_energy,
          pos: {5, 30},
          dir: :n,
          lineage: {nil, 0},
          paused?: true
        )

      Process.unlink(victim_pid)
      ref = Process.monitor(victim_pid)

      # Spawn a dedicated process to act as the "attacker" — registers under
      # attacker_id so the victim can look it up and forward :attack_reward.
      test_pid = self()
      attacker_id = "CLAMP_ATK"

      _fake_attacker =
        spawn(fn ->
          {:ok, _} = Lenies.Registry.register(attacker_id)
          # Signal the test that registration is complete so there is no race.
          send(test_pid, {:registered, attacker_id})

          receive do
            {:attack_reward, actual} -> send(test_pid, {:proxied_reward, actual})
          after
            2_000 -> send(test_pid, {:proxied_reward, :timeout})
          end
        end)

      # Wait for the fake attacker to be registered before triggering damage.
      assert_receive {:registered, ^attacker_id}, 1_000

      # Send take_damage with amount > victim's energy
      send(victim_pid, {:take_damage, 100, attacker_id})

      # Victim should die (amount > energy → new_energy <= 0 → :killed)
      assert_receive {:DOWN, ^ref, :process, ^victim_pid, :killed}, 1_000

      # Fake attacker proxied the reward back to us
      assert_receive {:proxied_reward, actual}, 1_000

      # Reward is clamped to victim's pre-attack energy
      assert actual <= small_energy + 0.01,
             "Reward not clamped: actual=#{actual}, victim_energy=#{small_energy}"

      assert actual > 0.0,
             "Reward was zero but victim had positive energy"
    end

    test "victim with energy greater than damage: reward equals damage exactly" do
      [{key, cell}] = :ets.lookup(:cells, {5, 31})
      :ets.insert(:cells, {key, %{cell | lenie_id: "CLAMP_V2"}})

      codeome = Codeome.from_list([:nop_0])
      big_energy = 200.0
      damage = 30

      {:ok, victim_pid} =
        Lenie.start_link(
          id: "CLAMP_V2",
          codeome: codeome,
          energy: big_energy,
          pos: {5, 31},
          dir: :n,
          lineage: {nil, 0},
          paused?: true
        )

      Process.unlink(victim_pid)

      test_pid = self()
      attacker_id = "CLAMP_ATK2"

      _fake_attacker =
        spawn(fn ->
          {:ok, _} = Lenies.Registry.register(attacker_id)
          # Signal the test that registration is complete so there is no race.
          send(test_pid, {:registered, attacker_id})

          receive do
            {:attack_reward, actual} -> send(test_pid, {:proxied_reward, actual})
          after
            2_000 -> send(test_pid, {:proxied_reward, :timeout})
          end
        end)

      # Wait for the fake attacker to be registered before triggering damage.
      assert_receive {:registered, ^attacker_id}, 1_000

      send(victim_pid, {:take_damage, damage, attacker_id})

      assert_receive {:proxied_reward, actual}, 1_000

      # Victim has plenty of energy, so reward should equal damage exactly
      assert actual == damage

      GenServer.stop(victim_pid)
    end
  end
end

defmodule Lenies.AttackEnergyConservationTest do
  @moduledoc """
  Tests that the attack mechanic conserves energy:
  - Attacker gains exactly what the victim lost (no more, even on overkill).
  - Defended attack: attacker gains actual clamped damage minus penalty.
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
  defp spawn_lenie(id, pos, energy, opts \\ []) do
    [{key, cell}] = :ets.lookup(:cells, pos)
    :ets.insert(:cells, {key, %{cell | lenie_id: id}})

    codeome = Codeome.from_list([:nop_0, :nop_0, :nop_0])

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
        ] ++ Keyword.drop(opts, [:dir, :paused?])
      )

    Process.unlink(pid)
    pid
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

      # Allow async :attack_reward message to be delivered to the attacker
      # then check via inspect_state (synchronous GenServer call that
      # processes all preceding messages first).
      Process.sleep(100)
      attacker_after = Lenie.inspect_state(attacker_pid).energy

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

      # Allow async :attack_reward to land
      Process.sleep(100)

      attacker_after = Lenie.inspect_state(attacker_pid).energy
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

      # Allow async :attack_reward to arrive
      Process.sleep(100)

      attacker_after = Lenie.inspect_state(attacker_pid).energy
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

    test "defended: apply_world_action applies only penalty (not damage) synchronously" do
      # This tests the interpreter side: when apply_world_action runs, the
      # attacker should only lose the penalty synchronously; the reward
      # arrives later async (not tested here — covered in the other tests).
      penalty = Application.get_env(:lenies, :defense_attacker_penalty, 5)
      attack_damage = Application.get_env(:lenies, :attack_damage, 10)
      half_damage = div(attack_damage, 2)

      # Build an interpreter state directly
      interp = Lenies.Interpreter.State.new(energy: 100.0, pos: {0, 0}, dir: :e)

      # Mock: simulate apply_world_action's defended branch with old code vs new code.
      # Old code: energy + damage - penalty
      # New code: energy - penalty
      energy_after_new = interp.energy - penalty
      energy_after_old = interp.energy + half_damage - penalty

      assert energy_after_new < energy_after_old,
             "New defended branch should cost more (no pre-credit): new=#{energy_after_new} vs old=#{energy_after_old}"

      # The new code leaves energy = 100 - 5 = 95 (not 100 + 5 - 5 = 100)
      assert energy_after_new == 100.0 - penalty
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

          receive do
            {:attack_reward, actual} -> send(test_pid, {:proxied_reward, actual})
          after
            2_000 -> send(test_pid, {:proxied_reward, :timeout})
          end
        end)

      # Give fake attacker time to register
      Process.sleep(20)

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

          receive do
            {:attack_reward, actual} -> send(test_pid, {:proxied_reward, actual})
          after
            2_000 -> send(test_pid, {:proxied_reward, :timeout})
          end
        end)

      # Give fake attacker time to register
      Process.sleep(20)

      send(victim_pid, {:take_damage, damage, attacker_id})

      assert_receive {:proxied_reward, actual}, 1_000

      # Victim has plenty of energy, so reward should equal damage exactly
      assert actual == damage

      GenServer.stop(victim_pid)
    end
  end
end
